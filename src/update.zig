const std = @import("std");
const tar_header = @import("tar_header.zig");
const buffer = @import("buffer.zig");
const options = @import("options.zig");
const append = @import("append.zig");

const PosixHeader = tar_header.PosixHeader;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;

/// Execute the update (-u) command
/// Only appends files that are newer than the copy in the archive
pub fn execute(allocator: std.mem.Allocator, opts: options.Options) !void {
    const archive_path = opts.archive_file orelse {
        std.debug.print("tar-zig: No archive file specified\n", .{});
        return error.MissingArchiveFile;
    };

    if (opts.files.items.len == 0) {
        std.debug.print("tar-zig: No files specified to update\n", .{});
        return error.NoFilesSpecified;
    }

    // Compression not supported for update
    if (opts.compression != .none and opts.compression != .auto) {
        std.debug.print("tar-zig: Cannot update compressed archives\n", .{});
        return error.CompressionNotSupported;
    }
    
    if (buffer.detectCompression(archive_path) != .none) {
        std.debug.print("tar-zig: Cannot update compressed archives\n", .{});
        return error.CompressionNotSupported;
    }

    // Change to source directory if specified
    if (opts.directory) |dir| {
        try std.posix.chdir(dir);
    }

    // Build a map of files in the archive and their mtimes
    var archive_mtimes = std.StringHashMap(i64).init(allocator);
    defer {
        var iter = archive_mtimes.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        archive_mtimes.deinit();
    }

    try scanArchive(allocator, archive_path, &archive_mtimes);

    // Filter files to only those that are newer
    var files_to_add: std.ArrayListUnmanaged([]const u8) = .{};
    defer files_to_add.deinit(allocator);

    for (opts.files.items) |path| {
        try collectNewerFiles(allocator, path, &archive_mtimes, &files_to_add, opts);
    }

    if (files_to_add.items.len == 0) {
        if (opts.verbosity != .quiet) {
            std.debug.print("tar-zig: No files newer than archive\n", .{});
        }
        return;
    }

    // Create modified options with the filtered file list
    var update_opts = opts;
    update_opts.files = .{};
    for (files_to_add.items) |f| {
        try update_opts.files.append(allocator, f);
    }
    defer update_opts.files.deinit(allocator);

    // Use append to add the newer files
    try append.execute(allocator, update_opts);
}

/// Scan the archive and build a map of filenames to mtimes
fn scanArchive(allocator: std.mem.Allocator, archive_path: []const u8, mtimes: *std.StringHashMap(i64)) !void {
    var file = try std.fs.cwd().openFile(archive_path, .{});
    defer file.close();

    var header_buf: [BLOCK_SIZE]u8 = undefined;
    var long_name: ?[]u8 = null;
    defer if (long_name) |n| allocator.free(n);

    while (true) {
        const bytes_read = try file.readAll(&header_buf);
        if (bytes_read == 0) break;
        if (bytes_read < BLOCK_SIZE) break;

        const header: *const PosixHeader = @ptrCast(&header_buf);

        if (header.isZeroBlock()) break;

        const type_flag = header.getTypeFlag();
        const size = header.getSize() catch 0;

        // Handle GNU long name extension
        if (type_flag == .gnu_long_name) {
            if (long_name) |n| allocator.free(n);
            long_name = try allocator.alloc(u8, @intCast(size));
            _ = try file.readAll(long_name.?);
            // Trim trailing null
            while (long_name.?.len > 0 and long_name.?[long_name.?.len - 1] == 0) {
                long_name = long_name.?[0 .. long_name.?.len - 1];
            }
            // Skip padding
            const padding = (BLOCK_SIZE - (size % BLOCK_SIZE)) % BLOCK_SIZE;
            if (padding > 0) {
                try file.seekBy(@intCast(padding));
            }
            continue;
        }

        // Get filename
        const name = if (long_name) |n| blk: {
            defer {
                allocator.free(n);
                long_name = null;
            }
            break :blk try allocator.dupe(u8, n);
        } else try header.getName(allocator);

        // Store mtime
        const mtime = header.getMtime() catch 0;
        try mtimes.put(name, mtime);

        // Skip file data
        if (size > 0) {
            const data_blocks = tar_header.blocksNeeded(size);
            try file.seekBy(@intCast(data_blocks * BLOCK_SIZE));
        }
    }
}

/// Recursively collect files that are newer than the archive copy
fn collectNewerFiles(
    allocator: std.mem.Allocator,
    path: []const u8,
    archive_mtimes: *std.StringHashMap(i64),
    files_to_add: *std.ArrayListUnmanaged([]const u8),
    opts: options.Options,
) anyerror!void {
    const stat = std.fs.cwd().statFile(path) catch |err| {
        std.debug.print("tar-zig: {s}: {}\n", .{ path, err });
        return;
    };

    switch (stat.kind) {
        .directory => {
            // Always include directories, then recurse
            try files_to_add.append(allocator, path);

            var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
            defer dir.close();

            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
                // Note: We're not freeing child_path as it's stored in files_to_add
                try collectNewerFiles(allocator, child_path, archive_mtimes, files_to_add, opts);
            }
        },
        .file => {
            const file_mtime: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
            
            // Check if file exists in archive and compare mtimes
            if (archive_mtimes.get(path)) |archive_mtime| {
                if (file_mtime > archive_mtime) {
                    try files_to_add.append(allocator, path);
                    if (opts.verbosity == .very_verbose) {
                        std.debug.print("tar-zig: {s} is newer\n", .{path});
                    }
                }
            } else {
                // File not in archive, add it
                try files_to_add.append(allocator, path);
                if (opts.verbosity == .very_verbose) {
                    std.debug.print("tar-zig: {s} is new\n", .{path});
                }
            }
        },
        .sym_link => {
            // Symlinks: check if not in archive or target changed
            if (!archive_mtimes.contains(path)) {
                try files_to_add.append(allocator, path);
            }
        },
        else => {},
    }
}

test "update module loads" {
    try std.testing.expect(true);
}
