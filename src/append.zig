const std = @import("std");
const tar_header = @import("tar_header.zig");
const buffer = @import("buffer.zig");
const options = @import("options.zig");
const create = @import("create.zig");

const PosixHeader = tar_header.PosixHeader;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;

/// Execute the append (-r) command
/// Appends files to the end of an existing archive
pub fn execute(allocator: std.mem.Allocator, opts: options.Options) !void {
    const archive_path = opts.archive_file orelse {
        std.debug.print("tar-zig: No archive file specified\n", .{});
        return error.MissingArchiveFile;
    };

    if (opts.files.items.len == 0) {
        std.debug.print("tar-zig: No files specified to append\n", .{});
        return error.NoFilesSpecified;
    }

    // Compression not supported for append (would need to decompress, modify, recompress)
    if (opts.compression != .none and opts.compression != .auto) {
        std.debug.print("tar-zig: Cannot append to compressed archives\n", .{});
        return error.CompressionNotSupported;
    }
    
    // Check if file extension suggests compression
    if (buffer.detectCompression(archive_path) != .none) {
        std.debug.print("tar-zig: Cannot append to compressed archives\n", .{});
        return error.CompressionNotSupported;
    }

    // Open the archive for reading and writing
    var file = try std.fs.cwd().openFile(archive_path, .{ .mode = .read_write });
    defer file.close();

    // Find the end-of-archive marker (two zero blocks)
    // We need to seek to just before it
    const append_pos = try findEndOfArchive(&file);
    
    // Seek to the append position
    try file.seekTo(append_pos);

    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    // Change to source directory if specified
    if (opts.directory) |dir| {
        try std.posix.chdir(dir);
    }

    // Append each file
    for (opts.files.items) |path| {
        try appendPath(allocator, &file, path, opts, stdout);
    }

    // Write new end-of-archive markers
    const zeros: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
    try file.writeAll(&zeros);
    try file.writeAll(&zeros);
}

/// Find the position just before the end-of-archive markers
fn findEndOfArchive(file: *std.fs.File) !u64 {
    var header_buf: [BLOCK_SIZE]u8 = undefined;
    var position: u64 = 0;
    var last_data_end: u64 = 0;

    try file.seekTo(0);

    while (true) {
        const bytes_read = try file.readAll(&header_buf);
        if (bytes_read == 0) break;
        if (bytes_read < BLOCK_SIZE) {
            // Truncated archive, append at current position
            return position;
        }

        const header: *const PosixHeader = @ptrCast(&header_buf);

        // Check for zero block (end of archive)
        if (header.isZeroBlock()) {
            return last_data_end;
        }

        position += BLOCK_SIZE;

        // Skip file data
        const size = header.getSize() catch 0;
        if (size > 0) {
            const data_blocks = tar_header.blocksNeeded(size);
            const skip_bytes = data_blocks * BLOCK_SIZE;
            try file.seekBy(@intCast(skip_bytes));
            position += skip_bytes;
        }

        last_data_end = position;
    }

    return last_data_end;
}

/// Append a path (file or directory) to the archive
fn appendPath(
    allocator: std.mem.Allocator,
    file: *std.fs.File,
    path: []const u8,
    opts: options.Options,
    stdout: std.fs.File,
) anyerror!void {
    const stat = std.fs.cwd().statFile(path) catch |err| {
        std.debug.print("tar-zig: {s}: {}\n", .{ path, err });
        return;
    };

    switch (stat.kind) {
        .directory => {
            try appendDirectory(allocator, file, path, opts, stdout);
        },
        .file => {
            try appendRegularFile(allocator, file, path, stat, opts, stdout);
        },
        .sym_link => {
            if (opts.dereference) {
                const real_stat = std.fs.cwd().statFile(path) catch |err| {
                    std.debug.print("tar-zig: {s}: {}\n", .{ path, err });
                    return;
                };
                try appendRegularFile(allocator, file, path, real_stat, opts, stdout);
            } else {
                try appendSymlink(file, path, opts, stdout);
            }
        },
        else => {
            std.debug.print("tar-zig: {s}: Unsupported file type\n", .{path});
        },
    }
}

/// Append a directory and its contents recursively
fn appendDirectory(
    allocator: std.mem.Allocator,
    file: *std.fs.File,
    path: []const u8,
    opts: options.Options,
    stdout: std.fs.File,
) anyerror!void {
    var header = PosixHeader.init();

    // Ensure directory name ends with /
    const dir_name = if (!std.mem.endsWith(u8, path, "/"))
        try std.fmt.allocPrint(allocator, "{s}/", .{path})
    else
        try allocator.dupe(u8, path);
    defer allocator.free(dir_name);

    header.setName(dir_name) catch {
        try writeLongName(file, dir_name);
        header.setName(dir_name[0..@min(dir_name.len, 100)]) catch {};
    };

    header.setTypeFlag(.directory);
    header.setMode(0o755);
    header.setSize(0);
    header.setMtime(std.time.timestamp());
    header.setUstarMagic();
    header.setChecksum();

    try file.writeAll(std.mem.asBytes(&header));

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
        try appendPath(allocator, file, child_path, opts, stdout);
    }
}

/// Append a regular file to the archive
fn appendRegularFile(
    _: std.mem.Allocator,
    archive_file: *std.fs.File,
    path: []const u8,
    stat: std.fs.File.Stat,
    opts: options.Options,
    stdout: std.fs.File,
) anyerror!void {
    var header = PosixHeader.init();

    header.setName(path) catch {
        try writeLongName(archive_file, path);
        header.setName(path[0..@min(path.len, 100)]) catch {};
    };

    header.setTypeFlag(.regular);
    header.setMode(@intCast(stat.mode & 0o7777));
    header.setSize(stat.size);
    header.setMtime(@intCast(@divFloor(stat.mtime, std.time.ns_per_s)));
    header.setUstarMagic();
    header.setChecksum();

    try archive_file.writeAll(std.mem.asBytes(&header));

    // Write file data
    var source_file = try std.fs.cwd().openFile(path, .{});
    defer source_file.close();

    var remaining: u64 = stat.size;
    var buf: [buffer.BUFFER_SIZE]u8 = undefined;

    while (remaining > 0) {
        const to_read: usize = @intCast(@min(remaining, buffer.BUFFER_SIZE));
        const bytes_read = try source_file.readAll(buf[0..to_read]);
        if (bytes_read == 0) break;
        try archive_file.writeAll(buf[0..bytes_read]);
        remaining -= bytes_read;
    }

    // Write padding
    const padding = (BLOCK_SIZE - (stat.size % BLOCK_SIZE)) % BLOCK_SIZE;
    if (padding > 0) {
        const zeros: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
        try archive_file.writeAll(zeros[0..@intCast(padding)]);
    }

    if (opts.verbosity == .verbose or opts.verbosity == .very_verbose) {
        try stdout.writeAll(path);
        try stdout.writeAll("\n");
    }
}

/// Append a symbolic link to the archive
fn appendSymlink(
    file: *std.fs.File,
    path: []const u8,
    opts: options.Options,
    stdout: std.fs.File,
) anyerror!void {
    var header = PosixHeader.init();

    header.setName(path) catch {
        try writeLongName(file, path);
        header.setName(path[0..@min(path.len, 100)]) catch {};
    };

    // Read symlink target
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fs.cwd().readLink(path, &target_buf) catch |err| {
        std.debug.print("tar-zig: {s}: {}\n", .{ path, err });
        return;
    };

    header.setLinkname(target);
    header.setTypeFlag(.symbolic_link);
    header.setMode(0o777);
    header.setSize(0);
    header.setMtime(std.time.timestamp());
    header.setUstarMagic();
    header.setChecksum();

    try file.writeAll(std.mem.asBytes(&header));

    if (opts.verbosity == .verbose or opts.verbosity == .very_verbose) {
        try stdout.writeAll(path);
        try stdout.writeAll("\n");
    }
}

/// Write a GNU long name header
fn writeLongName(file: *std.fs.File, name: []const u8) !void {
    var header = PosixHeader.init();

    @memcpy(header.name[0..13], "././@LongLink");
    header.setTypeFlag(.gnu_long_name);
    header.setMode(0);
    header.setSize(name.len + 1);
    header.setMtime(0);
    header.setUstarMagic();
    header.setChecksum();

    try file.writeAll(std.mem.asBytes(&header));

    // Write name data with null terminator
    try file.writeAll(name);
    try file.writeAll(&[_]u8{0});

    // Pad to block boundary
    const padding = BLOCK_SIZE - ((name.len + 1) % BLOCK_SIZE);
    if (padding < BLOCK_SIZE) {
        const zeros: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
        try file.writeAll(zeros[0..padding]);
    }
}

test "append module loads" {
    try std.testing.expect(true);
}
