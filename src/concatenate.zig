const std = @import("std");
const tar_header = @import("tar_header.zig");
const buffer = @import("buffer.zig");
const options = @import("options.zig");

const PosixHeader = tar_header.PosixHeader;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;

/// Execute the concatenate (-A) command
/// Appends the contents of tar archives to another archive
pub fn execute(allocator: std.mem.Allocator, opts: options.Options) !void {
    const archive_path = opts.archive_file orelse {
        std.debug.print("tar-zig: No archive file specified\n", .{});
        return error.MissingArchiveFile;
    };

    if (opts.files.items.len == 0) {
        std.debug.print("tar-zig: No archives to concatenate\n", .{});
        return error.NoFilesSpecified;
    }

    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    // Open the target archive for appending
    // First, we need to find the end of the archive (before the zero blocks)
    var target_file = try std.fs.cwd().openFile(archive_path, .{ .mode = .read_write });
    defer target_file.close();

    // Find the position to write (skip to end, back up past zero blocks)
    const file_size = try target_file.getEndPos();
    if (file_size < 2 * BLOCK_SIZE) {
        std.debug.print("tar-zig: Archive too small or corrupted\n", .{});
        return error.InvalidArchive;
    }

    // Read backwards to find the end of actual content
    var write_pos: u64 = file_size;
    var header_buf: [BLOCK_SIZE]u8 = undefined;

    // Check for zero blocks at the end
    while (write_pos >= BLOCK_SIZE) {
        write_pos -= BLOCK_SIZE;
        try target_file.seekTo(write_pos);
        const bytes_read = try target_file.readAll(&header_buf);
        if (bytes_read < BLOCK_SIZE) break;

        // Check if this block is all zeros
        var is_zero = true;
        for (header_buf) |b| {
            if (b != 0) {
                is_zero = false;
                break;
            }
        }

        if (!is_zero) {
            // Found non-zero block, write position is after it
            write_pos += BLOCK_SIZE;
            
            // But we need to skip past the file data too if this is a header
            const header: *const PosixHeader = @ptrCast(&header_buf);
            if (header.verifyChecksum()) {
                const size = header.getSize() catch 0;
                if (size > 0) {
                    const data_blocks = tar_header.blocksNeeded(size);
                    write_pos += data_blocks * BLOCK_SIZE;
                }
            }
            break;
        }
    }

    // Seek to write position
    try target_file.seekTo(write_pos);

    // Process each source archive
    for (opts.files.items) |source_path| {
        if (opts.verbosity == .verbose or opts.verbosity == .very_verbose) {
            try stdout.writeAll("Concatenating: ");
            try stdout.writeAll(source_path);
            try stdout.writeAll("\n");
        }

        try appendArchive(allocator, &target_file, source_path, opts);
    }

    // Write end-of-archive markers (two zero blocks)
    const zero_block = [_]u8{0} ** BLOCK_SIZE;
    try target_file.writeAll(&zero_block);
    try target_file.writeAll(&zero_block);
}

/// Append contents of a source archive to the target file
fn appendArchive(
    allocator: std.mem.Allocator,
    target_file: *std.fs.File,
    source_path: []const u8,
    opts: options.Options,
) !void {
    var reader = try buffer.ArchiveReader.init(allocator, source_path, opts.compression);
    defer reader.deinit();

    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var header_buf: [BLOCK_SIZE]u8 = undefined;

    while (true) {
        const bytes_read = try reader.readBlock(&header_buf);
        if (bytes_read == 0) break;
        if (bytes_read < BLOCK_SIZE) return error.UnexpectedEof;

        const header: *const PosixHeader = @ptrCast(&header_buf);

        // Check for end-of-archive
        if (header.isZeroBlock()) {
            break;
        }

        // Verify checksum
        if (!header.verifyChecksum()) {
            std.debug.print("tar-zig: Warning: checksum mismatch in {s}\n", .{source_path});
        }

        const size = try header.getSize();

        // Write header to target
        try target_file.writeAll(&header_buf);

        // Copy file data
        if (size > 0) {
            const blocks = tar_header.blocksNeeded(size);
            var remaining_blocks = blocks;

            while (remaining_blocks > 0) {
                const read_bytes = try reader.readBlock(&header_buf);
                if (read_bytes < BLOCK_SIZE) return error.UnexpectedEof;
                try target_file.writeAll(&header_buf);
                remaining_blocks -= 1;
            }
        }

        // Verbose output
        if (opts.verbosity == .verbose or opts.verbosity == .very_verbose) {
            const name = try header.getName(allocator);
            defer allocator.free(name);
            try stdout.writeAll(name);
            try stdout.writeAll("\n");
        }
    }
}

test "concatenate module loads" {
    try std.testing.expect(true);
}
