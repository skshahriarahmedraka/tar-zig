const std = @import("std");
const tar_header = @import("tar_header.zig");
const buffer = @import("buffer.zig");
const options = @import("options.zig");

const PosixHeader = tar_header.PosixHeader;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;

/// Execute the delete (--delete) command
/// Deletes specified files from the archive
pub fn execute(allocator: std.mem.Allocator, opts: options.Options) !void {
    const archive_path = opts.archive_file orelse {
        std.debug.print("tar-zig: No archive file specified\n", .{});
        return error.MissingArchiveFile;
    };

    if (opts.files.items.len == 0) {
        std.debug.print("tar-zig: No files specified to delete\n", .{});
        return error.NoFilesSpecified;
    }

    // Compression not supported for delete
    if (opts.compression != .none and opts.compression != .auto) {
        std.debug.print("tar-zig: Cannot delete from compressed archives\n", .{});
        return error.CompressionNotSupported;
    }
    
    if (buffer.detectCompression(archive_path) != .none) {
        std.debug.print("tar-zig: Cannot delete from compressed archives\n", .{});
        return error.CompressionNotSupported;
    }

    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    // Create a temporary file for the new archive
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ archive_path, std.time.milliTimestamp() });
    defer allocator.free(tmp_path);

    // Open source archive
    var src_file = try std.fs.cwd().openFile(archive_path, .{});
    defer src_file.close();

    // Create destination archive
    var dst_file = try std.fs.cwd().createFile(tmp_path, .{});
    errdefer {
        dst_file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    var header_buf: [BLOCK_SIZE]u8 = undefined;
    var long_name: ?[]u8 = null;
    var long_name_header: ?[BLOCK_SIZE]u8 = null;
    var long_name_data: ?[]u8 = null;
    defer if (long_name) |n| allocator.free(n);
    defer if (long_name_data) |d| allocator.free(d);

    var deleted_count: u32 = 0;

    while (true) {
        const bytes_read = try src_file.readAll(&header_buf);
        if (bytes_read == 0) break;
        if (bytes_read < BLOCK_SIZE) break;

        const header: *const PosixHeader = @ptrCast(&header_buf);

        // Check for zero block (end of archive)
        if (header.isZeroBlock()) {
            break;
        }

        const type_flag = header.getTypeFlag();
        const size = header.getSize() catch 0;

        // Handle GNU long name extension
        if (type_flag == .gnu_long_name) {
            // Save the long name header and data
            if (long_name) |n| allocator.free(n);
            if (long_name_data) |d| allocator.free(d);
            
            long_name_header = header_buf;
            long_name = try allocator.alloc(u8, @intCast(size));
            
            // Read long name data (including padding)
            const data_blocks = tar_header.blocksNeeded(size);
            long_name_data = try allocator.alloc(u8, data_blocks * BLOCK_SIZE);
            _ = try src_file.readAll(long_name_data.?);
            
            // Extract actual name (trim nulls)
            @memcpy(long_name.?, long_name_data.?[0..@intCast(size)]);
            while (long_name.?.len > 0 and long_name.?[long_name.?.len - 1] == 0) {
                long_name = long_name.?[0 .. long_name.?.len - 1];
            }
            continue;
        }

        // Get filename
        const name = if (long_name) |n|
            n
        else
            tar_header.extractString(&header.name);

        // Check if this file should be deleted
        var should_delete = false;
        for (opts.files.items) |pattern| {
            if (matchesPattern(name, pattern)) {
                should_delete = true;
                break;
            }
        }

        if (should_delete) {
            // Skip this entry
            if (opts.verbosity == .verbose or opts.verbosity == .very_verbose) {
                try stdout.writeAll("Removing ");
                try stdout.writeAll(name);
                try stdout.writeAll("\n");
            }
            deleted_count += 1;

            // Skip file data
            if (size > 0) {
                const data_blocks = tar_header.blocksNeeded(size);
                try src_file.seekBy(@intCast(data_blocks * BLOCK_SIZE));
            }

            // Clear long name state
            if (long_name) |n| {
                allocator.free(n);
                long_name = null;
            }
            if (long_name_data) |d| {
                allocator.free(d);
                long_name_data = null;
            }
            long_name_header = null;
        } else {
            // Copy this entry to the new archive
            
            // Write long name header and data if present
            if (long_name_header) |lnh| {
                try dst_file.writeAll(&lnh);
                if (long_name_data) |lnd| {
                    try dst_file.writeAll(lnd);
                }
            }
            
            // Write the entry header
            try dst_file.writeAll(&header_buf);

            // Copy file data
            if (size > 0) {
                const data_blocks = tar_header.blocksNeeded(size);
                const data_size = data_blocks * BLOCK_SIZE;
                
                var remaining: u64 = data_size;
                var copy_buf: [buffer.BUFFER_SIZE]u8 = undefined;
                
                while (remaining > 0) {
                    const to_read: usize = @intCast(@min(remaining, buffer.BUFFER_SIZE));
                    const read_bytes = try src_file.readAll(copy_buf[0..to_read]);
                    if (read_bytes == 0) break;
                    try dst_file.writeAll(copy_buf[0..read_bytes]);
                    remaining -= read_bytes;
                }
            }

            // Clear long name state
            if (long_name) |n| {
                allocator.free(n);
                long_name = null;
            }
            if (long_name_data) |d| {
                allocator.free(d);
                long_name_data = null;
            }
            long_name_header = null;
        }
    }

    // Write end-of-archive markers
    const zeros: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
    try dst_file.writeAll(&zeros);
    try dst_file.writeAll(&zeros);

    dst_file.close();

    // Replace original with new archive
    try std.fs.cwd().deleteFile(archive_path);
    try std.fs.cwd().rename(tmp_path, archive_path);

    if (opts.verbosity != .quiet) {
        const msg = try std.fmt.allocPrint(allocator, "tar-zig: Deleted {d} file(s)\n", .{deleted_count});
        defer allocator.free(msg);
        try stdout.writeAll(msg);
    }
}

/// Check if a filename matches a pattern
fn matchesPattern(name: []const u8, pattern: []const u8) bool {
    // Exact match
    if (std.mem.eql(u8, name, pattern)) return true;
    
    // Pattern with trailing slash matches directory and contents
    if (std.mem.endsWith(u8, pattern, "/")) {
        if (std.mem.startsWith(u8, name, pattern)) return true;
        // Also match the directory itself without trailing slash
        if (std.mem.eql(u8, name, pattern[0..pattern.len-1])) return true;
    }
    
    // Pattern matches if it's a prefix followed by /
    if (std.mem.startsWith(u8, name, pattern)) {
        if (pattern.len < name.len and name[pattern.len] == '/') {
            return true;
        }
    }
    
    return false;
}

test "delete module loads" {
    try std.testing.expect(true);
}

test "matchesPattern" {
    // Exact match
    try std.testing.expect(matchesPattern("foo.txt", "foo.txt"));
    
    // Directory prefix
    try std.testing.expect(matchesPattern("dir/file.txt", "dir"));
    try std.testing.expect(matchesPattern("dir/subdir/file.txt", "dir"));
    
    // With trailing slash
    try std.testing.expect(matchesPattern("dir/file.txt", "dir/"));
    try std.testing.expect(matchesPattern("dir", "dir/"));
    
    // Non-matches
    try std.testing.expect(!matchesPattern("foo.txt", "bar.txt"));
    try std.testing.expect(!matchesPattern("foobar.txt", "foo"));
}
