const std = @import("std");
const tar_header = @import("tar_header.zig");
const buffer = @import("buffer.zig");
const options = @import("options.zig");
const file_utils = @import("file_utils.zig");

const PosixHeader = tar_header.PosixHeader;
const TypeFlag = tar_header.TypeFlag;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;

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

    // Process each file/directory
    for (opts.files.items) |path| {
        try addPath(allocator, &writer, path, opts, stdout);
    }

    // Write end-of-archive markers
    try writer.writeEndOfArchive();
    try writer.finish();
}

/// Add a path (file or directory) to the archive
fn addPath(
    allocator: std.mem.Allocator,
    writer: *buffer.ArchiveWriter,
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
            try addDirectory(allocator, writer, path, opts, stdout);
        },
        .file => {
            try addRegularFile(allocator, writer, path, stat, opts, stdout);
        },
        .sym_link => {
            if (opts.dereference) {
                // Follow symlink
                const real_stat = std.fs.cwd().statFile(path) catch |err| {
                    std.debug.print("tar-zig: {s}: {}\n", .{ path, err });
                    return;
                };
                try addRegularFile(allocator, writer, path, real_stat, opts, stdout);
            } else {
                try addSymlink(allocator, writer, path, opts, stdout);
            }
        },
        else => {
            std.debug.print("tar-zig: {s}: Unsupported file type\n", .{path});
        },
    }
}

/// Add a directory and its contents recursively
fn addDirectory(
    allocator: std.mem.Allocator,
    writer: *buffer.ArchiveWriter,
    path: []const u8,
    opts: options.Options,
    stdout: std.fs.File,
) anyerror!void {
    // Get directory stats for permissions
    const stat = std.fs.cwd().statFile(path) catch |err| {
        std.debug.print("tar-zig: {s}: {}\n", .{ path, err });
        return;
    };

    // Add directory entry itself
    var header = PosixHeader.init();

    // Ensure directory name ends with /
    const dir_name = if (!std.mem.endsWith(u8, path, "/"))
        try std.fmt.allocPrint(allocator, "{s}/", .{path})
    else
        try allocator.dupe(u8, path);
    defer allocator.free(dir_name);

    header.setName(dir_name) catch {
        try writeLongName(writer, dir_name);
        header.setName(dir_name[0..@min(dir_name.len, 100)]) catch {};
    };

    header.setTypeFlag(.directory);
    header.setMode(@intCast(stat.mode & 0o7777));
    header.setSize(0);
    header.setMtime(@intCast(@divFloor(stat.mtime, std.time.ns_per_s)));
    header.setUstarMagic();
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
        try addPath(allocator, writer, child_path, opts, stdout);
    }
}

/// Add a regular file to the archive
fn addRegularFile(
    _: std.mem.Allocator,
    writer: *buffer.ArchiveWriter,
    path: []const u8,
    stat: std.fs.File.Stat,
    opts: options.Options,
    stdout: std.fs.File,
) anyerror!void {
    var header = PosixHeader.init();

    header.setName(path) catch {
        try writeLongName(writer, path);
        header.setName(path[0..@min(path.len, 100)]) catch {};
    };

    header.setTypeFlag(.regular);
    header.setMode(@intCast(stat.mode & 0o7777));
    header.setSize(stat.size);
    header.setMtime(@intCast(@divFloor(stat.mtime, std.time.ns_per_s)));
    header.setUstarMagic();
    header.setChecksum();

    try writer.writeHeader(&header);

    // Write file data
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    try writer.writeData(file, stat.size);

    if (opts.verbosity == .verbose or opts.verbosity == .very_verbose) {
        try stdout.writeAll(path);
        try stdout.writeAll("\n");
    }
}

/// Add a symbolic link to the archive
fn addSymlink(
    _: std.mem.Allocator,
    writer: *buffer.ArchiveWriter,
    path: []const u8,
    opts: options.Options,
    stdout: std.fs.File,
) anyerror!void {
    var header = PosixHeader.init();

    header.setName(path) catch {
        try writeLongName(writer, path);
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

    try writer.writeHeader(&header);

    if (opts.verbosity == .verbose or opts.verbosity == .very_verbose) {
        try stdout.writeAll(path);
        try stdout.writeAll("\n");
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
    header.setUstarMagic();
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

test "create module loads" {
    // Basic test to ensure module compiles
    try std.testing.expect(true);
}
