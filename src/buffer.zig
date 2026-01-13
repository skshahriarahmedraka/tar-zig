const std = @import("std");
const tar_header = @import("tar_header.zig");
const compression_mod = @import("compression.zig");

const BLOCK_SIZE = tar_header.BLOCK_SIZE;
const PosixHeader = tar_header.PosixHeader;

/// Buffer size for reading archives (multiple of block size)
pub const BUFFER_SIZE: usize = BLOCK_SIZE * 20; // 10KB buffer

/// Archive reader that handles block-aligned reading
/// Supports both compressed and uncompressed archives
pub const ArchiveReader = struct {
    allocator: std.mem.Allocator,
    compression: @import("options.zig").Compression,
    
    // Either direct file or compressed reader
    file: ?std.fs.File = null,
    compressed_reader: ?compression_mod.CompressedReader = null,
    
    // For compressed streams, we need to buffer since we can't seek
    is_compressed: bool = false,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, compression: @import("options.zig").Compression) !ArchiveReader {
        var actual_compression = if (compression == .auto)
            detectCompression(path)
        else
            compression;

        // If auto-detection from extension failed, try magic bytes
        if (actual_compression == .none and compression == .auto) {
            const file = try std.fs.cwd().openFile(path, .{});
            actual_compression = compression_mod.detectCompressionFromMagic(file) catch .none;
            file.close();
        }

        if (actual_compression != .none) {
            // Use compressed reader
            const compressed_reader = compression_mod.CompressedReader.init(allocator, path, actual_compression) catch |err| {
                std.debug.print("tar-zig: Failed to start decompressor: {}\n", .{err});
                std.debug.print("tar-zig: Make sure the compression program is installed\n", .{});
                return error.CompressionNotSupported;
            };
            
            return ArchiveReader{
                .allocator = allocator,
                .compression = actual_compression,
                .compressed_reader = compressed_reader,
                .is_compressed = true,
            };
        } else {
            // Direct file access
            const file = try std.fs.cwd().openFile(path, .{});
            errdefer file.close();

            return ArchiveReader{
                .allocator = allocator,
                .compression = actual_compression,
                .file = file,
                .is_compressed = false,
            };
        }
    }

    pub fn deinit(self: *ArchiveReader) void {
        if (self.compressed_reader) |*cr| {
            cr.deinit();
        }
        if (self.file) |f| {
            f.close();
        }
    }

    /// Read exactly one block (512 bytes)
    pub fn readBlock(self: *ArchiveReader, buffer: *[BLOCK_SIZE]u8) !usize {
        if (self.compressed_reader) |*cr| {
            return cr.readAll(buffer);
        } else if (self.file) |f| {
            return f.readAll(buffer);
        }
        return error.InvalidState;
    }

    /// Read a header block
    pub fn readHeader(self: *ArchiveReader) !?*const PosixHeader {
        var buffer: [BLOCK_SIZE]u8 = undefined;
        const bytes_read = try self.readBlock(&buffer);

        if (bytes_read == 0) return null;
        if (bytes_read < BLOCK_SIZE) return error.UnexpectedEof;

        const header: *const PosixHeader = @ptrCast(&buffer);

        // Check for end-of-archive (zero block)
        if (header.isZeroBlock()) {
            return null;
        }

        return header;
    }

    /// Skip n blocks
    pub fn skipBlocks(self: *ArchiveReader, n: u64) !void {
        if (self.is_compressed) {
            // For compressed streams, we must read through the data
            var buf: [BLOCK_SIZE]u8 = undefined;
            var remaining = n;
            while (remaining > 0) : (remaining -= 1) {
                _ = try self.readBlock(&buf);
            }
        } else if (self.file) |f| {
            try f.seekBy(@intCast(n * BLOCK_SIZE));
        }
    }

    /// Read file data into a file
    pub fn readData(self: *ArchiveReader, size: u64, out_file: std.fs.File) !void {
        var remaining = size;
        var buf: [BUFFER_SIZE]u8 = undefined;

        while (remaining > 0) {
            const to_read = @min(remaining, BUFFER_SIZE);
            const to_read_usize: usize = @intCast(to_read);

            const bytes_read = if (self.compressed_reader) |*cr|
                try cr.readAll(buf[0..to_read_usize])
            else if (self.file) |f|
                try f.readAll(buf[0..to_read_usize])
            else
                return error.InvalidState;

            if (bytes_read == 0) return error.UnexpectedEof;

            try out_file.writeAll(buf[0..bytes_read]);
            remaining -= bytes_read;
        }

        // Skip padding to next block boundary
        const padding = (BLOCK_SIZE - (size % BLOCK_SIZE)) % BLOCK_SIZE;
        if (padding > 0) {
            if (self.is_compressed) {
                var pad_buf: [BLOCK_SIZE]u8 = undefined;
                if (self.compressed_reader) |*cr| {
                    _ = try cr.readAll(pad_buf[0..@intCast(padding)]);
                }
            } else if (self.file) |f| {
                try f.seekBy(@intCast(padding));
            }
        }
    }

    /// Read file data into a buffer (for small data like long names)
    pub fn readDataToBuffer(self: *ArchiveReader, size: u64, out_buf: []u8) !void {
        const size_usize: usize = @intCast(size);
        if (out_buf.len < size_usize) return error.BufferTooSmall;

        const bytes_read = if (self.compressed_reader) |*cr|
            try cr.readAll(out_buf[0..size_usize])
        else if (self.file) |f|
            try f.readAll(out_buf[0..size_usize])
        else
            return error.InvalidState;

        if (bytes_read < size_usize) return error.UnexpectedEof;

        // Skip padding to next block boundary
        const padding = (BLOCK_SIZE - (size % BLOCK_SIZE)) % BLOCK_SIZE;
        if (padding > 0) {
            if (self.is_compressed) {
                var pad_buf: [BLOCK_SIZE]u8 = undefined;
                if (self.compressed_reader) |*cr| {
                    _ = try cr.readAll(pad_buf[0..@intCast(padding)]);
                }
            } else if (self.file) |f| {
                try f.seekBy(@intCast(padding));
            }
        }
    }
};

/// Archive writer that handles block-aligned writing
/// Supports both compressed and uncompressed archives
pub const ArchiveWriter = struct {
    allocator: std.mem.Allocator,
    bytes_written: u64 = 0,
    is_compressed: bool = false,
    
    // Either direct file or compressed writer
    file: ?std.fs.File = null,
    compressed_writer: ?compression_mod.CompressedWriter = null,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, compression: @import("options.zig").Compression) !ArchiveWriter {
        const actual_compression = if (compression == .auto)
            detectCompression(path)
        else
            compression;

        if (actual_compression != .none) {
            // Use compressed writer
            const compressed_writer = compression_mod.CompressedWriter.init(allocator, path, actual_compression) catch |err| {
                std.debug.print("tar-zig: Failed to start compressor: {}\n", .{err});
                std.debug.print("tar-zig: Make sure the compression program is installed\n", .{});
                return error.CompressionNotSupported;
            };
            
            return ArchiveWriter{
                .allocator = allocator,
                .compressed_writer = compressed_writer,
                .is_compressed = true,
            };
        } else {
            const file = try std.fs.cwd().createFile(path, .{});
            errdefer file.close();

            return ArchiveWriter{
                .allocator = allocator,
                .file = file,
                .is_compressed = false,
            };
        }
    }

    pub fn deinit(self: *ArchiveWriter) void {
        if (self.compressed_writer) |*cw| {
            cw.deinit();
        }
        if (self.file) |f| {
            f.close();
        }
    }

    /// Write a header block
    pub fn writeHeader(self: *ArchiveWriter, header: *const PosixHeader) !void {
        const bytes = std.mem.asBytes(header);
        try self.writeBytes(bytes);
    }

    /// Write raw bytes
    pub fn writeBytes(self: *ArchiveWriter, data: []const u8) !void {
        if (self.compressed_writer) |*cw| {
            try cw.writeAll(data);
        } else if (self.file) |f| {
            try f.writeAll(data);
        } else {
            return error.InvalidState;
        }
        self.bytes_written += data.len;
    }

    /// Write data with padding to block boundary
    pub fn writeData(self: *ArchiveWriter, in_file: std.fs.File, size: u64) !void {
        var remaining = size;
        var buf: [BUFFER_SIZE]u8 = undefined;

        while (remaining > 0) {
            const to_read: usize = @intCast(@min(remaining, BUFFER_SIZE));
            const bytes_read = try in_file.readAll(buf[0..to_read]);
            if (bytes_read == 0) break;

            try self.writeBytes(buf[0..bytes_read]);
            remaining -= bytes_read;
        }

        // Write padding
        const padding = (BLOCK_SIZE - (size % BLOCK_SIZE)) % BLOCK_SIZE;
        if (padding > 0) {
            const zeros: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
            try self.writeBytes(zeros[0..@intCast(padding)]);
        }
    }

    /// Write end-of-archive markers (two zero blocks)
    pub fn writeEndOfArchive(self: *ArchiveWriter) !void {
        const zeros: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
        try self.writeBytes(&zeros);
        try self.writeBytes(&zeros);
    }

    /// Finish writing - closes compression stream
    pub fn finish(self: *ArchiveWriter) !void {
        if (self.compressed_writer) |*cw| {
            try cw.finish();
        }
    }
};

/// Detect compression type from file extension
pub fn detectCompression(path: []const u8) @import("options.zig").Compression {
    if (std.mem.endsWith(u8, path, ".gz") or std.mem.endsWith(u8, path, ".tgz")) {
        return .gzip;
    } else if (std.mem.endsWith(u8, path, ".bz2") or std.mem.endsWith(u8, path, ".tbz")) {
        return .bzip2;
    } else if (std.mem.endsWith(u8, path, ".xz") or std.mem.endsWith(u8, path, ".txz")) {
        return .xz;
    } else if (std.mem.endsWith(u8, path, ".zst") or std.mem.endsWith(u8, path, ".tzst")) {
        return .zstd;
    }
    return .none;
}

test "detectCompression" {
    try std.testing.expectEqual(@import("options.zig").Compression.gzip, detectCompression("file.tar.gz"));
    try std.testing.expectEqual(@import("options.zig").Compression.gzip, detectCompression("file.tgz"));
    try std.testing.expectEqual(@import("options.zig").Compression.bzip2, detectCompression("file.tar.bz2"));
    try std.testing.expectEqual(@import("options.zig").Compression.xz, detectCompression("file.tar.xz"));
    try std.testing.expectEqual(@import("options.zig").Compression.zstd, detectCompression("file.tar.zst"));
    try std.testing.expectEqual(@import("options.zig").Compression.none, detectCompression("file.tar"));
}
