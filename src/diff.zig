const std = @import("std");
const tar_header = @import("tar_header.zig");
const buffer = @import("buffer.zig");
const options = @import("options.zig");

const PosixHeader = tar_header.PosixHeader;
const TypeFlag = tar_header.TypeFlag;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;

/// Execute the diff (-d) command
/// Compares archive contents with the filesystem
pub fn execute(allocator: std.mem.Allocator, opts: options.Options) !void {
    const archive_path = opts.archive_file orelse {
        std.debug.print("tar-zig: No archive file specified\n", .{});
        return error.MissingArchiveFile;
    };

    // Change to target directory if specified
    if (opts.directory) |dir| {
        try std.posix.chdir(dir);
    }

    var reader = try buffer.ArchiveReader.init(allocator, archive_path, opts.compression);
    defer reader.deinit();

    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var header_buf: [BLOCK_SIZE]u8 = undefined;
    var long_name: ?[]u8 = null;
    defer if (long_name) |n| allocator.free(n);

    var differences_found: u32 = 0;

    while (true) {
        const bytes_read = try reader.readBlock(&header_buf);
        if (bytes_read == 0) break;
        if (bytes_read < BLOCK_SIZE) return error.UnexpectedEof;

        const header: *const PosixHeader = @ptrCast(&header_buf);

        if (header.isZeroBlock()) {
            _ = try reader.readBlock(&header_buf);
            break;
        }

        if (!header.verifyChecksum()) {
            std.debug.print("tar-zig: Warning: checksum mismatch\n", .{});
        }

        const type_flag = header.getTypeFlag();
        const size = try header.getSize();

        // Handle GNU long name extension
        if (type_flag == .gnu_long_name) {
            if (long_name) |n| allocator.free(n);
            long_name = try allocator.alloc(u8, @intCast(size));
            try reader.readDataToBuffer(size, long_name.?);
            while (long_name.?.len > 0 and long_name.?[long_name.?.len - 1] == 0) {
                long_name = long_name.?[0 .. long_name.?.len - 1];
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
        defer allocator.free(name);

        // Check if file matches the filter (if any)
        if (opts.files.items.len > 0) {
            var matches = false;
            for (opts.files.items) |pattern| {
                if (matchesPattern(name, pattern)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) {
                if (size > 0) {
                    const blocks = tar_header.blocksNeeded(size);
                    try reader.skipBlocks(blocks);
                }
                continue;
            }
        }

        // Compare with filesystem
        const diff_result = try compareEntry(allocator, &reader, header, name, type_flag, size, opts);
        
        if (diff_result) |diff_msg| {
            defer allocator.free(diff_msg);
            try stdout.writeAll(name);
            try stdout.writeAll(": ");
            try stdout.writeAll(diff_msg);
            try stdout.writeAll("\n");
            differences_found += 1;
        } else {
            // No difference - verbose output
            if (opts.verbosity == .very_verbose) {
                try stdout.writeAll(name);
                try stdout.writeAll(": OK\n");
            }
        }
    }

    if (differences_found > 0) {
        const msg = try std.fmt.allocPrint(allocator, "tar-zig: {d} difference(s) found\n", .{differences_found});
        defer allocator.free(msg);
        try stdout.writeAll(msg);
    } else if (opts.verbosity != .quiet) {
        try stdout.writeAll("tar-zig: No differences found\n");
    }
}

/// Compare an archive entry with the filesystem
/// Returns null if no difference, or a message describing the difference
fn compareEntry(
    allocator: std.mem.Allocator,
    reader: *buffer.ArchiveReader,
    header: *const PosixHeader,
    name: []const u8,
    type_flag: TypeFlag,
    size: u64,
    opts: options.Options,
) !?[]u8 {
    _ = opts;
    
    // Check if file exists
    const stat = std.fs.cwd().statFile(name) catch |err| {
        if (size > 0) {
            const blocks = tar_header.blocksNeeded(size);
            try reader.skipBlocks(blocks);
        }
        return try std.fmt.allocPrint(allocator, "Cannot stat: {}", .{err});
    };

    // Check type
    const expected_kind: std.fs.File.Kind = switch (type_flag) {
        .regular, .regular_alt => .file,
        .directory => .directory,
        .symbolic_link => .sym_link,
        else => .file,
    };

    if (stat.kind != expected_kind) {
        if (size > 0) {
            const blocks = tar_header.blocksNeeded(size);
            try reader.skipBlocks(blocks);
        }
        return try std.fmt.allocPrint(allocator, "File type differs (archive: {}, filesystem: {})", .{ type_flag, stat.kind });
    }

    // Check size for regular files
    if (type_flag.isRegularFile()) {
        if (stat.size != size) {
            if (size > 0) {
                const blocks = tar_header.blocksNeeded(size);
                try reader.skipBlocks(blocks);
            }
            return try std.fmt.allocPrint(allocator, "Size differs (archive: {d}, filesystem: {d})", .{ size, stat.size });
        }

        // Compare contents
        if (size > 0) {
            const content_differs = try compareFileContents(allocator, reader, name, size);
            if (content_differs) {
                return try allocator.dupe(u8, "Contents differ");
            }
        }
    } else {
        // Skip data for non-regular files
        if (size > 0) {
            const blocks = tar_header.blocksNeeded(size);
            try reader.skipBlocks(blocks);
        }
    }

    // Check mode/permissions
    const archive_mode = header.getMode() catch 0;
    const fs_mode: u32 = @intCast(stat.mode & 0o7777);
    if (archive_mode != fs_mode and type_flag != .symbolic_link) {
        return try std.fmt.allocPrint(allocator, "Mode differs (archive: {o:0>4}, filesystem: {o:0>4})", .{ archive_mode, fs_mode });
    }

    // Check mtime
    const archive_mtime = header.getMtime() catch 0;
    const fs_mtime: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
    if (archive_mtime != fs_mtime) {
        return try std.fmt.allocPrint(allocator, "Mod time differs (archive: {d}, filesystem: {d})", .{ archive_mtime, fs_mtime });
    }

    // Check symlink target
    if (type_flag == .symbolic_link) {
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const fs_target = std.fs.cwd().readLink(name, &target_buf) catch {
            return try allocator.dupe(u8, "Cannot read symlink target");
        };
        const archive_target = header.getLinkname();
        if (!std.mem.eql(u8, fs_target, archive_target)) {
            return try std.fmt.allocPrint(allocator, "Symlink target differs (archive: {s}, filesystem: {s})", .{ archive_target, fs_target });
        }
    }

    return null;
}

/// Compare file contents between archive and filesystem
fn compareFileContents(
    allocator: std.mem.Allocator,
    reader: *buffer.ArchiveReader,
    name: []const u8,
    size: u64,
) !bool {
    _ = allocator;
    
    var fs_file = std.fs.cwd().openFile(name, .{}) catch {
        // Skip archive data
        const blocks = tar_header.blocksNeeded(size);
        try reader.skipBlocks(blocks);
        return true;
    };
    defer fs_file.close();

    var archive_buf: [buffer.BUFFER_SIZE]u8 = undefined;
    var fs_buf: [buffer.BUFFER_SIZE]u8 = undefined;
    var remaining = size;

    while (remaining > 0) {
        const to_read: usize = @intCast(@min(remaining, buffer.BUFFER_SIZE));
        
        // Read from archive
        var block_buf: [BLOCK_SIZE]u8 = undefined;
        var archive_pos: usize = 0;
        while (archive_pos < to_read) {
            const block_to_read = @min(BLOCK_SIZE, to_read - archive_pos);
            const archive_read = try reader.readBlock(&block_buf);
            if (archive_read == 0) return true;
            @memcpy(archive_buf[archive_pos..][0..block_to_read], block_buf[0..block_to_read]);
            archive_pos += block_to_read;
            if (block_to_read < BLOCK_SIZE) {
                // We read a full block but only needed part of it
                // The rest is padding, skip handled by readBlock
            }
        }

        // Read from filesystem
        const fs_read = try fs_file.readAll(fs_buf[0..to_read]);
        if (fs_read != to_read) return true;

        // Compare
        if (!std.mem.eql(u8, archive_buf[0..to_read], fs_buf[0..to_read])) {
            // Skip remaining archive data
            const blocks_remaining = tar_header.blocksNeeded(remaining - to_read);
            if (blocks_remaining > 0) {
                try reader.skipBlocks(blocks_remaining);
            }
            return true;
        }

        remaining -= to_read;
    }

    // Handle padding
    const padding = (BLOCK_SIZE - (size % BLOCK_SIZE)) % BLOCK_SIZE;
    if (padding > 0) {
        // Padding was already skipped in the last readBlock call
    }

    return false;
}

/// Check if a filename matches a pattern
fn matchesPattern(name: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, name, pattern)) return true;
    if (std.mem.startsWith(u8, name, pattern)) {
        if (pattern.len < name.len and name[pattern.len] == '/') {
            return true;
        }
    }
    if (std.mem.startsWith(u8, name, pattern)) {
        return true;
    }
    return false;
}

test "diff module loads" {
    try std.testing.expect(true);
}
