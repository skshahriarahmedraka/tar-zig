const std = @import("std");
const tar_header = @import("tar_header.zig");
const buffer = @import("buffer.zig");
const options = @import("options.zig");
const file_utils = @import("file_utils.zig");

const PosixHeader = tar_header.PosixHeader;
const TypeFlag = tar_header.TypeFlag;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;

/// Execute the extract (-x) command
pub fn execute(allocator: std.mem.Allocator, opts: options.Options) !void {
    const archive_path = opts.archive_file orelse {
        std.debug.print("tar-zig: No archive file specified\n", .{});
        return error.MissingArchiveFile;
    };

    // Open archive before changing directory
    var reader = try buffer.ArchiveReader.init(allocator, archive_path, opts.compression);
    defer reader.deinit();

    // Change to target directory if specified
    if (opts.directory) |dir| {
        try std.posix.chdir(dir);
    }

    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var header_buf: [BLOCK_SIZE]u8 = undefined;
    var long_name: ?[]u8 = null;
    var long_link: ?[]u8 = null;
    defer if (long_name) |n| allocator.free(n);
    defer if (long_link) |l| allocator.free(l);

    while (true) {
        const bytes_read = try reader.readBlock(&header_buf);
        if (bytes_read == 0) break;
        if (bytes_read < BLOCK_SIZE) return error.UnexpectedEof;

        const header: *const PosixHeader = @ptrCast(&header_buf);

        // Check for end-of-archive
        if (header.isZeroBlock()) {
            _ = try reader.readBlock(&header_buf);
            break;
        }

        // Verify checksum
        if (!header.verifyChecksum()) {
            std.debug.print("tar-zig: Warning: checksum mismatch\n", .{});
        }

        const type_flag = header.getTypeFlag();
        const size = try header.getSize();

        // Handle GNU long name extension
        if (type_flag == .gnu_long_name) {
            if (long_name) |n| allocator.free(n);
            const raw_name = try allocator.alloc(u8, @intCast(size));
            try reader.readDataToBuffer(size, raw_name);
            // Find actual string length (trim trailing nulls)
            var actual_len: usize = raw_name.len;
            while (actual_len > 0 and raw_name[actual_len - 1] == 0) {
                actual_len -= 1;
            }
            long_name = try allocator.alloc(u8, actual_len);
            @memcpy(long_name.?, raw_name[0..actual_len]);
            allocator.free(raw_name);
            continue;
        }

        // Handle GNU long link extension
        if (type_flag == .gnu_long_link) {
            if (long_link) |l| allocator.free(l);
            const raw_link = try allocator.alloc(u8, @intCast(size));
            try reader.readDataToBuffer(size, raw_link);
            var actual_len: usize = raw_link.len;
            while (actual_len > 0 and raw_link[actual_len - 1] == 0) {
                actual_len -= 1;
            }
            long_link = try allocator.alloc(u8, actual_len);
            @memcpy(long_link.?, raw_link[0..actual_len]);
            allocator.free(raw_link);
            continue;
        }

        // Get filename
        const raw_name = if (long_name) |n| blk: {
            defer {
                allocator.free(n);
                long_name = null;
            }
            break :blk try allocator.dupe(u8, n);
        } else try header.getName(allocator);
        defer allocator.free(raw_name);

        // Strip leading slashes to make paths relative (standard tar behavior)
        const relative_name = stripLeadingSlashes(raw_name);

        // Apply strip-components
        const name = stripComponents(relative_name, opts.strip_components) orelse {
            // Skip this entry if all components are stripped
            if (size > 0) {
                const blocks = tar_header.blocksNeeded(size);
                try reader.skipBlocks(blocks);
            }
            continue;
        };

        // Check if this file matches the filter (if any)
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

        // Verbose output
        if (opts.verbosity == .verbose or opts.verbosity == .very_verbose) {
            try stdout.writeAll(name);
            try stdout.writeAll("\n");
        }

        // Get link name
        const linkname = if (long_link) |l| blk: {
            defer {
                allocator.free(l);
                long_link = null;
            }
            break :blk l;
        } else header.getLinkname();

        // Extract based on type
        switch (type_flag) {
            .directory => {
                try file_utils.createDirectoryRecursive(name);
            },
            .symbolic_link => {
                try file_utils.createSymlink(linkname, name);
            },
            .hard_link => {
                try file_utils.createHardlink(linkname, name);
            },
            .regular, .regular_alt => {
                // Check if file exists and keep_old_files is set
                if (opts.keep_old_files) {
                    if (std.fs.cwd().access(name, .{})) |_| {
                        if (size > 0) {
                            const blocks = tar_header.blocksNeeded(size);
                            try reader.skipBlocks(blocks);
                        }
                        continue;
                    } else |_| {}
                }

                try extractRegularFile(allocator, &reader, name, size, header, opts);
            },
            else => {
                // Skip unsupported types
                if (size > 0) {
                    const blocks = tar_header.blocksNeeded(size);
                    try reader.skipBlocks(blocks);
                }
            },
        }
    }
}

/// Extract a regular file from the archive
fn extractRegularFile(
    allocator: std.mem.Allocator,
    reader: *buffer.ArchiveReader,
    name: []const u8,
    size: u64,
    header: *const PosixHeader,
    opts: options.Options,
) !void {
    _ = allocator;

    // Create parent directories if needed
    if (std.fs.path.dirname(name)) |dir| {
        try file_utils.createDirectoryRecursive(dir);
    }

    // Create the file
    var file = try std.fs.cwd().createFile(name, .{});
    defer file.close();

    // Write file data
    try reader.readData(size, file);

    // Set permissions
    if (opts.preserve_permissions) {
        const mode = header.getMode() catch 0o644;
        file_utils.setPermissions(name, mode) catch {};
    }

    // Set modification time
    const mtime = header.getMtime() catch return;
    file_utils.setModificationTime(name, mtime) catch {};
}

/// Strip leading slashes from path (makes absolute paths relative)
fn stripLeadingSlashes(path: []const u8) []const u8 {
    var result = path;
    while (result.len > 0 and result[0] == '/') {
        result = result[1..];
    }
    return result;
}

/// Strip leading path components
fn stripComponents(path: []const u8, n: u32) ?[]const u8 {
    if (n == 0) return path;

    var remaining = path;
    var count: u32 = 0;

    while (count < n) {
        if (std.mem.indexOf(u8, remaining, "/")) |idx| {
            remaining = remaining[idx + 1 ..];
            count += 1;
        } else {
            return null; // Not enough components
        }
    }

    if (remaining.len == 0) return null;
    return remaining;
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

test "stripLeadingSlashes" {
    try std.testing.expectEqualStrings("tmp/test", stripLeadingSlashes("/tmp/test"));
    try std.testing.expectEqualStrings("tmp/test", stripLeadingSlashes("///tmp/test"));
    try std.testing.expectEqualStrings("test.txt", stripLeadingSlashes("test.txt"));
    try std.testing.expectEqualStrings("", stripLeadingSlashes(""));
    try std.testing.expectEqualStrings("", stripLeadingSlashes("/"));
}

test "stripComponents" {
    try std.testing.expectEqualStrings("c/d.txt", stripComponents("a/b/c/d.txt", 2).?);
    try std.testing.expectEqualStrings("b/c.txt", stripComponents("a/b/c.txt", 1).?);
    try std.testing.expectEqualStrings("a/b/c.txt", stripComponents("a/b/c.txt", 0).?);
    try std.testing.expectEqual(@as(?[]const u8, null), stripComponents("a/b", 3));
}
