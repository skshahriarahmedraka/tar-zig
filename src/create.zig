const std = @import("std");
const tar_header = @import("tar_header.zig");
const buffer = @import("buffer.zig");
const options = @import("options.zig");
const file_utils = @import("file_utils.zig");
const sparse = @import("sparse.zig");
const transform = @import("transform.zig");
const list = @import("list.zig");

const PosixHeader = tar_header.PosixHeader;
const TypeFlag = tar_header.TypeFlag;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;
const ArchiveFormat = options.ArchiveFormat;

/// Context for tracking state during archive creation
const CreateContext = struct {
    root_dev: ?u64 = null,          // Device ID of starting filesystem (for --one-file-system)
    files_added: std.ArrayListUnmanaged([]const u8) = .{}, // Track files for --remove-files
    record_count: u64 = 0,          // Track records written for --checkpoint
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) CreateContext {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *CreateContext) void {
        for (self.files_added.items) |path| {
            self.allocator.free(path);
        }
        self.files_added.deinit(self.allocator);
    }

    fn trackFile(self: *CreateContext, path: []const u8) !void {
        const duped = try self.allocator.dupe(u8, path);
        try self.files_added.append(self.allocator, duped);
    }
};

/// Set the appropriate magic for the archive format
fn setFormatMagic(header: *PosixHeader, format: ArchiveFormat) void {
    switch (format) {
        .gnu, .oldgnu => header.setGnuMagic(),
        .pax, .ustar => header.setUstarMagic(),
        .v7 => {
            // V7 format has no magic field
            @memset(&header.magic, 0);
            @memset(&header.version, 0);
        },
    }
}

/// Get uid and gid for a file path using POSIX stat
fn getOwnerIds(path: []const u8) struct { uid: u32, gid: u32 } {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = @min(path.len, path_buf.len - 1);
    @memcpy(path_buf[0..path_len], path[0..path_len]);
    path_buf[path_len] = 0;
    
    const stat_result = std.posix.fstatat(std.fs.cwd().fd, path_buf[0..path_len :0], 0);
    if (stat_result) |st| {
        return .{ .uid = st.uid, .gid = st.gid };
    } else |_| {
        return .{ .uid = 0, .gid = 0 };
    }
}

/// Set owner information (uid, gid, uname, gname) in the header
fn setOwnerInfoFromPath(header: *PosixHeader, path: []const u8, opts: options.Options) void {
    const owner = getOwnerIds(path);
    
    // Always set numeric uid/gid
    header.setUid(owner.uid);
    header.setGid(owner.gid);
    
    // Set user/group names based on --numeric-owner option
    if (opts.numeric_owner) {
        // With --numeric-owner, leave uname/gname empty (already zeroed from init)
        // This makes tar always use numeric values when extracting
    } else {
        // Try to look up user and group names
        // For now, we don't have name lookup implemented, so leave empty
        // The numeric uid/gid will be used by extracting tools
        // TODO: Implement getpwuid/getgrgid lookup for user/group names
    }
}

/// Check if we need to use PAX extended headers for this name
fn needsPaxHeader(name: []const u8, format: ArchiveFormat) bool {
    return format == .pax and name.len > 100;
}

/// Check if we should use GNU long name extension
fn shouldUseGnuLongName(name: []const u8, format: ArchiveFormat) bool {
    if (name.len <= 100) return false;
    return format == .gnu or format == .oldgnu;
}

/// Apply transforms to a path if configured
fn transformPath(allocator: std.mem.Allocator, path: []const u8, opts: options.Options) ![]u8 {
    if (opts.transforms.items.len == 0) {
        return allocator.dupe(u8, path);
    }
    return transform.applyTransforms(allocator, path, opts.transforms.items);
}

/// Execute the create (-c) command
pub fn execute(allocator: std.mem.Allocator, opts: options.Options) !void {
    const archive_path = opts.archive_file orelse {
        std.debug.print("tar-zig: No archive file specified\n", .{});
        return error.MissingArchiveFile;
    };

    if (opts.files.items.len == 0) {
        std.debug.print("tar-zig: No files specified\n", .{});
        return error.NoFilesSpecified;
    }

    // Resolve archive path to absolute BEFORE changing directory
    const abs_archive_path = if (opts.directory != null and !std.fs.path.isAbsolute(archive_path))
        try std.fs.cwd().realpathAlloc(allocator, ".") 
    else
        null;
    defer if (abs_archive_path) |p| allocator.free(p);
    
    const final_archive_path = if (abs_archive_path) |base| blk: {
        const full_path = try std.fs.path.join(allocator, &.{ base, archive_path });
        break :blk full_path;
    } else archive_path;
    defer if (abs_archive_path != null) allocator.free(final_archive_path);

    // Change to source directory if specified
    if (opts.directory) |dir| {
        try std.posix.chdir(dir);
    }

    var writer = try buffer.ArchiveWriter.init(allocator, final_archive_path, opts.compression);
    defer writer.deinit();

    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };

    // Initialize context for tracking state
    var ctx = CreateContext.init(allocator);
    defer ctx.deinit();

    // Process each file/directory
    for (opts.files.items) |path| {
        try addPath(allocator, &writer, path, opts, stdout, &ctx);
    }

    // Write end-of-archive markers
    try writer.writeEndOfArchive();
    try writer.finish();

    // Handle --verify option
    if (opts.verify) {
        try stderr.writeAll("tar-zig: Verifying archive...\n");
        try verifyArchive(allocator, final_archive_path, opts);
        try stderr.writeAll("tar-zig: Archive verified successfully\n");
    }

    // Handle --remove-files option
    if (opts.remove_files) {
        try removeAddedFiles(&ctx, stderr);
    }
}

/// Add a path (file or directory) to the archive
fn addPath(
    allocator: std.mem.Allocator,
    writer: *buffer.ArchiveWriter,
    path: []const u8,
    opts: options.Options,
    stdout: std.fs.File,
    ctx: *CreateContext,
) anyerror!void {
    // Check if path matches any exclude pattern
    if (opts.isExcluded(path)) {
        return;
    }

    // Get file stat using lstat to not follow symlinks initially
    const stat = getFileStat(path) catch |err| {
        std.debug.print("tar-zig: {s}: {}\n", .{ path, err });
        return;
    };

    // Check --one-file-system option
    if (opts.one_file_system) {
        if (ctx.root_dev == null) {
            // First file - record its device
            ctx.root_dev = stat.dev;
        } else if (stat.dev != ctx.root_dev.?) {
            // Different filesystem - skip
            if (opts.verbosity == .verbose or opts.verbosity == .very_verbose) {
                std.debug.print("tar-zig: {s}: file is on a different filesystem; not dumped\n", .{path});
            }
            return;
        }
    }

    // Check --newer option
    if (opts.newer_mtime) |newer_time| {
        const file_mtime = @divFloor(stat.mtime, std.time.ns_per_s);
        if (file_mtime <= newer_time) {
            // File is not newer - skip
            return;
        }
    }

    // Handle checkpoint display
    if (opts.checkpoint) |checkpoint_interval| {
        ctx.record_count += 1;
        if (ctx.record_count % checkpoint_interval == 0) {
            handleCheckpoint(opts, ctx.record_count);
        }
    }

    switch (stat.kind) {
        .directory => {
            try addDirectory(allocator, writer, path, opts, stdout, ctx);
        },
        .file => {
            try addRegularFile(allocator, writer, path, stat, opts, stdout, ctx);
        },
        .sym_link => {
            if (opts.dereference) {
                // Follow symlink
                const real_stat = std.fs.cwd().statFile(path) catch |err| {
                    std.debug.print("tar-zig: {s}: {}\n", .{ path, err });
                    return;
                };
                try addRegularFile(allocator, writer, path, real_stat, opts, stdout, ctx);
            } else {
                try addSymlink(allocator, writer, path, opts, stdout, ctx);
            }
        },
        else => {
            std.debug.print("tar-zig: {s}: Unsupported file type\n", .{path});
        },
    }
}

/// Extended stat info including device ID
const ExtendedStat = struct {
    inode: u64,
    size: u64,
    mode: u32,
    mtime: i128,
    atime: i128,
    ctime: i128,
    kind: std.fs.File.Kind,
    dev: u64,
};

/// Get file stat including device ID (using fstatat for proper device info)
fn getFileStat(path: []const u8) !ExtendedStat {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = @min(path.len, path_buf.len - 1);
    @memcpy(path_buf[0..path_len], path[0..path_len]);
    path_buf[path_len] = 0;

    const stat_result = std.posix.fstatat(std.fs.cwd().fd, path_buf[0..path_len :0], std.posix.AT.SYMLINK_NOFOLLOW);
    if (stat_result) |st| {
        return .{
            .inode = st.ino,
            .size = @intCast(st.size),
            .mode = st.mode,
            .mtime = @as(i128, st.mtim.sec) * std.time.ns_per_s + st.mtim.nsec,
            .atime = @as(i128, st.atim.sec) * std.time.ns_per_s + st.atim.nsec,
            .ctime = @as(i128, st.ctim.sec) * std.time.ns_per_s + st.ctim.nsec,
            .kind = modeToKind(st.mode),
            .dev = st.dev,
        };
    } else |err| {
        return err;
    }
}

/// Convert mode to file kind
fn modeToKind(mode: u32) std.fs.File.Kind {
    const S = std.posix.S;
    const m = mode & S.IFMT;
    return switch (m) {
        S.IFBLK => .block_device,
        S.IFCHR => .character_device,
        S.IFDIR => .directory,
        S.IFIFO => .named_pipe,
        S.IFLNK => .sym_link,
        S.IFREG => .file,
        S.IFSOCK => .unix_domain_socket,
        else => .unknown,
    };
}

/// Handle checkpoint action
fn handleCheckpoint(opts: options.Options, record_count: u64) void {
    const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };
    
    if (opts.checkpoint_action) |action| {
        if (std.mem.eql(u8, action, "dot")) {
            stderr.writeAll(".") catch {};
        } else if (std.mem.eql(u8, action, "echo")) {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "tar-zig: Record {d}\n", .{record_count}) catch return;
            stderr.writeAll(msg) catch {};
        } else {
            // Default: print record number
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "tar-zig: Record {d}\n", .{record_count}) catch return;
            stderr.writeAll(msg) catch {};
        }
    } else {
        // Default checkpoint message
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "tar-zig: Record {d}\n", .{record_count}) catch return;
        stderr.writeAll(msg) catch {};
    }
}

/// Verify an archive by reading through it
fn verifyArchive(allocator: std.mem.Allocator, archive_path: []const u8, opts: options.Options) !void {
    // Create a modified options for listing (silent mode)
    var verify_opts = opts;
    verify_opts.operation = .list;
    verify_opts.verbosity = .quiet;
    verify_opts.archive_file = archive_path;
    
    // Use list module to verify by reading all entries
    try list.execute(allocator, verify_opts);
}

/// Remove files that were added to the archive
fn removeAddedFiles(ctx: *CreateContext, stderr: std.fs.File) !void {
    // Remove files in reverse order (so directories are removed after their contents)
    var i = ctx.files_added.items.len;
    while (i > 0) {
        i -= 1;
        const path = ctx.files_added.items[i];
        
        // Try to determine if it's a directory or file
        const stat = std.fs.cwd().statFile(path) catch continue;
        
        if (stat.kind == .directory) {
            std.fs.cwd().deleteDir(path) catch |err| {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "tar-zig: Cannot remove '{s}': {}\n", .{ path, err }) catch continue;
                stderr.writeAll(msg) catch {};
            };
        } else {
            std.fs.cwd().deleteFile(path) catch |err| {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "tar-zig: Cannot remove '{s}': {}\n", .{ path, err }) catch continue;
                stderr.writeAll(msg) catch {};
            };
        }
    }
}

/// Add a directory and its contents recursively
fn addDirectory(
    allocator: std.mem.Allocator,
    writer: *buffer.ArchiveWriter,
    path: []const u8,
    opts: options.Options,
    stdout: std.fs.File,
    ctx: *CreateContext,
) anyerror!void {
    // Get directory stats for permissions
    const stat = std.fs.cwd().statFile(path) catch |err| {
        std.debug.print("tar-zig: {s}: {}\n", .{ path, err });
        return;
    };

    // Add directory entry itself
    var header = PosixHeader.init();

    // Apply transforms and ensure directory name ends with /
    const transformed = try transformPath(allocator, path, opts);
    defer allocator.free(transformed);
    
    const dir_name = if (!std.mem.endsWith(u8, transformed, "/"))
        try std.fmt.allocPrint(allocator, "{s}/", .{transformed})
    else
        try allocator.dupe(u8, transformed);
    defer allocator.free(dir_name);

    // Handle long names based on format
    if (shouldUseGnuLongName(dir_name, opts.format)) {
        try writeLongName(writer, dir_name);
        header.setName(dir_name[0..@min(dir_name.len, 100)]) catch {};
    } else if (needsPaxHeader(dir_name, opts.format)) {
        try writePaxHeader(allocator, writer, dir_name, null, stat.size);
        header.setName(dir_name[0..@min(dir_name.len, 100)]) catch {};
    } else {
        header.setName(dir_name) catch {
            // Fallback to GNU long name if name doesn't fit
            try writeLongName(writer, dir_name);
            header.setName(dir_name[0..@min(dir_name.len, 100)]) catch {};
        };
    }

    header.setTypeFlag(.directory);
    header.setMode(@intCast(stat.mode & 0o7777));
    header.setSize(0);
    header.setMtime(@intCast(@divFloor(stat.mtime, std.time.ns_per_s)));
    
    // Set owner information
    setOwnerInfoFromPath(&header, path, opts);
    
    setFormatMagic(&header, opts.format);
    header.setChecksum();

    try writer.writeHeader(&header);

    if (opts.verbosity == .verbose or opts.verbosity == .very_verbose) {
        try stdout.writeAll(dir_name);
        try stdout.writeAll("\n");
    }

    // Recursively add directory contents
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
        defer allocator.free(child_path);
        try addPath(allocator, writer, child_path, opts, stdout, ctx);
    }

    // Track directory for removal (after contents are processed)
    if (opts.remove_files) {
        try ctx.trackFile(path);
    }
}

/// Add a regular file to the archive (with ExtendedStat for --one-file-system support)
fn addRegularFile(
    allocator: std.mem.Allocator,
    writer: *buffer.ArchiveWriter,
    path: []const u8,
    stat: anytype,  // Accepts both std.fs.File.Stat and ExtendedStat
    opts: options.Options,
    stdout: std.fs.File,
    ctx: *CreateContext,
) anyerror!void {
    // Open file first to detect sparse regions if needed
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Check for sparse file handling
    var sparse_regions: ?sparse.SparseRegions = null;
    defer if (sparse_regions) |*regions| regions.deinit();

    var is_sparse = false;
    var physical_size = stat.size;

    if (opts.sparse and stat.size > 0) {
        // Detect sparse regions
        sparse_regions = sparse.detectSparseRegions(allocator, file, stat.size) catch null;
        
        if (sparse_regions) |regions| {
            if (sparse.isSparseWorthy(regions.entries.items, stat.size)) {
                is_sparse = true;
                physical_size = sparse.calculatePhysicalSize(regions.entries.items);
            }
        }
    }

    // Apply transforms to the archive path name
    const archive_name = try transformPath(allocator, path, opts);
    defer allocator.free(archive_name);

    var header = PosixHeader.init();

    // Handle sparse files with PAX format (preferred) or GNU sparse
    if (is_sparse) {
        if (opts.format == .pax) {
            // Use PAX extended headers for sparse info
            try writePaxSparseHeader(allocator, writer, archive_name, stat.size, physical_size, sparse_regions.?.entries.items);
            header.setName(archive_name[0..@min(archive_name.len, 100)]) catch {};
        } else if (opts.format == .gnu or opts.format == .oldgnu) {
            // Use GNU sparse format
            try writeGnuSparseHeaders(allocator, writer, archive_name, stat.size, sparse_regions.?.entries.items);
            header.setName(archive_name[0..@min(archive_name.len, 100)]) catch {};
            header.setTypeFlag(.gnu_sparse);
        } else {
            // Format doesn't support sparse, fall back to regular
            is_sparse = false;
            physical_size = stat.size;
        }
    }

    // Handle long names if not already handled by sparse headers
    if (!is_sparse) {
        if (shouldUseGnuLongName(archive_name, opts.format)) {
            try writeLongName(writer, archive_name);
            header.setName(archive_name[0..@min(archive_name.len, 100)]) catch {};
        } else if (needsPaxHeader(archive_name, opts.format)) {
            try writePaxHeader(allocator, writer, archive_name, null, stat.size);
            header.setName(archive_name[0..@min(archive_name.len, 100)]) catch {};
        } else {
            header.setName(archive_name) catch {
                // Fallback to GNU long name if name doesn't fit
                try writeLongName(writer, archive_name);
                header.setName(archive_name[0..@min(archive_name.len, 100)]) catch {};
            };
        }
    }

    if (!is_sparse or (opts.format != .gnu and opts.format != .oldgnu)) {
        header.setTypeFlag(.regular);
    }
    
    header.setMode(@intCast(stat.mode & 0o7777));
    header.setSize(if (is_sparse) physical_size else stat.size);
    header.setMtime(@intCast(@divFloor(stat.mtime, std.time.ns_per_s)));
    
    // Set owner information
    setOwnerInfoFromPath(&header, path, opts);
    
    setFormatMagic(&header, opts.format);
    header.setChecksum();

    try writer.writeHeader(&header);

    // Write file data
    if (is_sparse and sparse_regions != null) {
        try sparse.writeSparseData(writer, file, sparse_regions.?.entries.items);
    } else {
        try writer.writeData(file, stat.size);
    }

    if (opts.verbosity == .verbose or opts.verbosity == .very_verbose) {
        try stdout.writeAll(path);
        if (is_sparse) {
            const msg = try std.fmt.allocPrint(allocator, " (sparse: {d} -> {d} bytes)", .{ stat.size, physical_size });
            defer allocator.free(msg);
            try stdout.writeAll(msg);
        }
        try stdout.writeAll("\n");
    }

    // Track file for removal
    if (opts.remove_files) {
        try ctx.trackFile(path);
    }
}

/// Add a symbolic link to the archive
fn addSymlink(
    allocator: std.mem.Allocator,
    writer: *buffer.ArchiveWriter,
    path: []const u8,
    opts: options.Options,
    stdout: std.fs.File,
    ctx: *CreateContext,
) anyerror!void {
    var header = PosixHeader.init();

    // Read symlink target
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fs.cwd().readLink(path, &target_buf) catch |err| {
        std.debug.print("tar-zig: {s}: {}\n", .{ path, err });
        return;
    };

    // Apply transforms to the archive path name
    const archive_name = try transformPath(allocator, path, opts);
    defer allocator.free(archive_name);

    // Handle long names based on format
    if (shouldUseGnuLongName(archive_name, opts.format)) {
        try writeLongName(writer, archive_name);
        header.setName(archive_name[0..@min(archive_name.len, 100)]) catch {};
    } else if (needsPaxHeader(archive_name, opts.format)) {
        try writePaxHeader(allocator, writer, archive_name, target, 0);
        header.setName(archive_name[0..@min(archive_name.len, 100)]) catch {};
    } else {
        header.setName(archive_name) catch {
            // Fallback to GNU long name if name doesn't fit
            try writeLongName(writer, archive_name);
            header.setName(archive_name[0..@min(archive_name.len, 100)]) catch {};
        };
    }

    header.setLinkname(target);
    header.setTypeFlag(.symbolic_link);
    header.setMode(0o777);
    header.setSize(0);
    header.setMtime(std.time.timestamp());
    
    // Set owner information
    setOwnerInfoFromPath(&header, path, opts);
    
    setFormatMagic(&header, opts.format);
    header.setChecksum();

    try writer.writeHeader(&header);

    if (opts.verbosity == .verbose or opts.verbosity == .very_verbose) {
        try stdout.writeAll(path);
        try stdout.writeAll("\n");
    }

    // Track symlink for removal
    if (opts.remove_files) {
        try ctx.trackFile(path);
    }
}

/// Write a GNU long name header for names > 100 characters
fn writeLongName(writer: *buffer.ArchiveWriter, name: []const u8) !void {
    var header = PosixHeader.init();

    @memcpy(header.name[0..13], "././@LongLink");
    header.setTypeFlag(.gnu_long_name);
    header.setMode(0);
    header.setSize(name.len + 1); // Include null terminator
    header.setMtime(0);
    header.setGnuMagic();
    header.setChecksum();

    try writer.writeHeader(&header);

    // Write name data with null terminator
    try writer.writeBytes(name);
    try writer.writeBytes(&[_]u8{0});

    // Pad to block boundary
    const padding = BLOCK_SIZE - ((name.len + 1) % BLOCK_SIZE);
    if (padding < BLOCK_SIZE) {
        var zeros: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
        try writer.writeBytes(zeros[0..padding]);
    }
}

/// Write a PAX extended header for sparse files
fn writePaxSparseHeader(
    allocator: std.mem.Allocator,
    writer: *buffer.ArchiveWriter,
    path: []const u8,
    logical_size: u64,
    _: u64, // physical_size - not needed for PAX header
    regions: []const sparse.SparseEntry,
) !void {
    // Build PAX extended header content
    var content = std.ArrayListUnmanaged(u8){};
    defer content.deinit(allocator);

    // Add path if needed
    if (path.len > 100) {
        try addPaxEntry(allocator, &content, "path", path);
    }

    // Add GNU sparse attributes
    try addPaxEntry(allocator, &content, "GNU.sparse.major", "1");
    try addPaxEntry(allocator, &content, "GNU.sparse.minor", "0");
    try addPaxEntry(allocator, &content, "GNU.sparse.name", path);
    
    const size_str = try std.fmt.allocPrint(allocator, "{d}", .{logical_size});
    defer allocator.free(size_str);
    try addPaxEntry(allocator, &content, "GNU.sparse.realsize", size_str);

    // Build sparse map
    const sparse_map = try sparse.buildPaxSparseMap(allocator, regions);
    defer allocator.free(sparse_map);
    try addPaxEntry(allocator, &content, "GNU.sparse.map", sparse_map);

    if (content.items.len == 0) return;

    // Create PAX header
    var header = PosixHeader.init();
    @memcpy(header.name[0..18], "PaxHeader/sparse00");
    header.setTypeFlag(.pax_extended);
    header.setMode(0o644);
    header.setSize(content.items.len);
    header.setMtime(std.time.timestamp());
    header.setUstarMagic();
    header.setChecksum();

    try writer.writeHeader(&header);

    // Write PAX content
    try writer.writeBytes(content.items);

    // Pad to block boundary
    const remainder = content.items.len % BLOCK_SIZE;
    if (remainder > 0) {
        const padding = BLOCK_SIZE - remainder;
        var zeros: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
        try writer.writeBytes(zeros[0..padding]);
    }
}

/// Add a PAX entry to the content buffer
fn addPaxEntry(allocator: std.mem.Allocator, content: *std.ArrayListUnmanaged(u8), key: []const u8, value: []const u8) !void {
    // PAX format: "length key=value\n" where length includes itself
    // We need to calculate the length iteratively since it's part of itself
    const base_len: usize = 3 + key.len + value.len; // " key=value\n" plus at least 1 digit
    var digits: usize = 1;
    while (true) {
        const total = base_len + digits;
        const actual_digits = if (total < 10) @as(usize, 1) else if (total < 100) @as(usize, 2) else if (total < 1000) @as(usize, 3) else @as(usize, 4);
        if (actual_digits == digits) break;
        digits = actual_digits;
    }
    
    const entry = try std.fmt.allocPrint(allocator, "{d} {s}={s}\n", .{ base_len + digits, key, value });
    defer allocator.free(entry);
    try content.appendSlice(allocator, entry);
}

/// Write GNU sparse headers for a sparse file
fn writeGnuSparseHeaders(
    allocator: std.mem.Allocator,
    writer: *buffer.ArchiveWriter,
    path: []const u8,
    logical_size: u64,
    regions: []const sparse.SparseEntry,
) !void {
    _ = allocator;
    _ = logical_size;
    
    // For GNU sparse format, we write a long name header if needed
    if (path.len > 100) {
        try writeLongName(writer, path);
    }
    
    // The sparse map will be written in extended headers following the main header
    // For now, we'll just prepare - the actual sparse entries go in the header padding area
    // or in extended sparse headers (for more than 4 entries)
    _ = regions;
    
    // GNU sparse format version 0.0/0.1 is complex - for simplicity, we rely on PAX format
    // when possible. The main header with type 'S' indicates sparse.
}

/// Write a PAX extended header for long names or large files
fn writePaxHeader(
    allocator: std.mem.Allocator,
    writer: *buffer.ArchiveWriter,
    path: []const u8,
    linkpath: ?[]const u8,
    size: u64,
) !void {
    // Build PAX extended header content
    var content = std.ArrayListUnmanaged(u8){};
    defer content.deinit(allocator);

    // Add path if it's too long
    if (path.len > 100) {
        const path_entry = try std.fmt.allocPrint(allocator, "{d} path={s}\n", .{ 7 + path.len + 1, path });
        defer allocator.free(path_entry);
        // Recalculate with correct length
        const actual_len = path_entry.len;
        const corrected = try std.fmt.allocPrint(allocator, "{d} path={s}\n", .{ actual_len, path });
        defer allocator.free(corrected);
        try content.appendSlice(allocator, corrected);
    }

    // Add linkpath if present and too long
    if (linkpath) |lp| {
        if (lp.len > 100) {
            const link_entry = try std.fmt.allocPrint(allocator, "{d} linkpath={s}\n", .{ 11 + lp.len + 1, lp });
            defer allocator.free(link_entry);
            const actual_len = link_entry.len;
            const corrected = try std.fmt.allocPrint(allocator, "{d} linkpath={s}\n", .{ actual_len, lp });
            defer allocator.free(corrected);
            try content.appendSlice(allocator, corrected);
        }
    }

    // Add size if it exceeds octal limit
    if (size > tar_header.MAX_OCTAL_VALUE) {
        const size_entry = try std.fmt.allocPrint(allocator, "{d} size={d}\n", .{ 20, size });
        defer allocator.free(size_entry);
        try content.appendSlice(allocator, size_entry);
    }

    if (content.items.len == 0) return;

    // Create PAX header
    var header = PosixHeader.init();
    @memcpy(header.name[0..16], "PaxHeader/file00");
    header.setTypeFlag(.pax_extended);
    header.setMode(0o644);
    header.setSize(content.items.len);
    header.setMtime(std.time.timestamp());
    header.setUstarMagic();
    header.setChecksum();

    try writer.writeHeader(&header);

    // Write PAX content
    try writer.writeBytes(content.items);

    // Pad to block boundary
    const remainder = content.items.len % BLOCK_SIZE;
    if (remainder > 0) {
        const padding = BLOCK_SIZE - remainder;
        var zeros: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
        try writer.writeBytes(zeros[0..padding]);
    }
}

test "create module loads" {
    // Basic test to ensure module compiles
    try std.testing.expect(true);
}
