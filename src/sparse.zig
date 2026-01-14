const std = @import("std");
const tar_header = @import("tar_header.zig");
const buffer = @import("buffer.zig");

const BLOCK_SIZE = tar_header.BLOCK_SIZE;

/// A sparse map entry representing a data region in a sparse file
pub const SparseEntry = struct {
    offset: u64,    // Offset in the logical file
    numbytes: u64,  // Number of bytes of data at this offset
};

/// GNU sparse header extension (follows main header for sparse files)
/// This is the format used in GNU tar's oldgnu sparse format
pub const GnuSparseHeader = extern struct {
    /// Array of sparse entries (4 entries per extension block)
    sp: [21]GnuSparseEntry,
    /// Flag indicating if more sparse headers follow
    isextended: u8,
    /// Padding to make it 512 bytes
    padding: [7]u8,

    comptime {
        if (@sizeOf(GnuSparseHeader) != BLOCK_SIZE) {
            @compileError("GnuSparseHeader must be exactly 512 bytes");
        }
    }

    pub fn init() GnuSparseHeader {
        return std.mem.zeroes(GnuSparseHeader);
    }
};

/// A single GNU sparse entry (offset + numbytes as octal strings)
pub const GnuSparseEntry = extern struct {
    offset: [12]u8,
    numbytes: [12]u8,

    pub fn getOffset(self: *const GnuSparseEntry) u64 {
        return tar_header.parseOctal(u64, &self.offset) catch 0;
    }

    pub fn getNumbytes(self: *const GnuSparseEntry) u64 {
        return tar_header.parseOctal(u64, &self.numbytes) catch 0;
    }

    pub fn setOffset(self: *GnuSparseEntry, offset: u64) void {
        tar_header.formatOctal(&self.offset, offset);
    }

    pub fn setNumbytes(self: *GnuSparseEntry, numbytes: u64) void {
        tar_header.formatOctal(&self.numbytes, numbytes);
    }

    pub fn isEmpty(self: *const GnuSparseEntry) bool {
        // Check if both offset and numbytes are zero/empty
        for (self.offset) |c| {
            if (c != 0 and c != '0' and c != ' ') return false;
        }
        for (self.numbytes) |c| {
            if (c != 0 and c != '0' and c != ' ') return false;
        }
        return true;
    }
};

/// Result type for sparse region detection
pub const SparseRegions = struct {
    entries: std.ArrayListUnmanaged(SparseEntry) = .{},
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *SparseRegions) void {
        self.entries.deinit(self.allocator);
    }
};

/// Detect sparse regions in a file by looking for holes (sequences of zeros)
/// Returns a list of data regions (non-hole areas)
pub fn detectSparseRegions(allocator: std.mem.Allocator, file: std.fs.File, file_size: u64) !SparseRegions {
    var result = SparseRegions{ .allocator = allocator };
    errdefer result.deinit();

    if (file_size == 0) {
        return result;
    }

    // Detect sparse regions by reading the file and looking for zero blocks
    try detectSparseRegionsByReading(allocator, &result.entries, file, file_size);
    return result;
}

/// Fallback: detect sparse regions by reading the file and looking for zero blocks
fn detectSparseRegionsByReading(allocator: std.mem.Allocator, regions: *std.ArrayListUnmanaged(SparseEntry), file: std.fs.File, file_size: u64) !void {
    const CHUNK_SIZE: usize = 64 * 1024; // 64KB chunks
    var read_buf: [CHUNK_SIZE]u8 = undefined;

    var pos: u64 = 0;
    var in_data = false;
    var data_start: u64 = 0;

    // Reset to start
    try file.seekTo(0);

    while (pos < file_size) {
        const to_read = @min(CHUNK_SIZE, file_size - pos);
        const bytes_read = try file.read(read_buf[0..to_read]);
        if (bytes_read == 0) break;

        // Check if this chunk is all zeros
        const is_zero = isZeroBlock(read_buf[0..bytes_read]);

        if (is_zero) {
            if (in_data) {
                // End of data region
                try regions.append(allocator, .{
                    .offset = data_start,
                    .numbytes = pos - data_start,
                });
                in_data = false;
            }
        } else {
            if (!in_data) {
                // Start of data region
                data_start = pos;
                in_data = true;
            }
        }

        pos += bytes_read;
    }

    // Handle final data region
    if (in_data) {
        try regions.append(allocator, .{
            .offset = data_start,
            .numbytes = pos - data_start,
        });
    }

    // Reset file position
    try file.seekTo(0);
}

/// Check if a buffer is all zeros
fn isZeroBlock(buf: []const u8) bool {
    // Use SIMD-friendly loop
    for (buf) |b| {
        if (b != 0) return false;
    }
    return true;
}

/// Calculate the physical size needed for sparse data
pub fn calculatePhysicalSize(regions: []const SparseEntry) u64 {
    var total: u64 = 0;
    for (regions) |entry| {
        total += entry.numbytes;
    }
    return total;
}

/// Check if a file would benefit from sparse storage
/// Returns true if physical size is significantly smaller than logical size
pub fn isSparseWorthy(regions: []const SparseEntry, logical_size: u64) bool {
    if (logical_size == 0) return false;
    
    const physical_size = calculatePhysicalSize(regions);
    
    // Consider it sparse if physical size is less than 90% of logical size
    // or if there are multiple regions (indicating holes in the middle)
    return physical_size < (logical_size * 9 / 10) or regions.len > 1;
}

/// Write sparse file data to archive, only writing non-hole regions
pub fn writeSparseData(
    writer: *buffer.ArchiveWriter,
    file: std.fs.File,
    regions: []const SparseEntry,
) !void {
    var buf: [BLOCK_SIZE]u8 = undefined;

    for (regions) |entry| {
        // Seek to the data region
        try file.seekTo(entry.offset);

        // Write the data
        var remaining = entry.numbytes;
        while (remaining > 0) {
            const to_read = @min(BLOCK_SIZE, remaining);
            const bytes_read = try file.read(buf[0..to_read]);
            if (bytes_read == 0) break;

            try writer.writeBytes(buf[0..bytes_read]);
            remaining -= bytes_read;
        }
    }

    // Pad to block boundary
    const physical_size = calculatePhysicalSize(regions);
    const remainder = physical_size % BLOCK_SIZE;
    if (remainder > 0) {
        const padding = BLOCK_SIZE - remainder;
        @memset(buf[0..padding], 0);
        try writer.writeBytes(buf[0..padding]);
    }
}

/// Build PAX sparse map string from regions
/// Format: "offset,size,offset,size,..."
pub fn buildPaxSparseMap(allocator: std.mem.Allocator, regions: []const SparseEntry) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    for (regions, 0..) |entry, i| {
        if (i > 0) {
            try result.append(allocator, ',');
        }
        const entry_str = try std.fmt.allocPrint(allocator, "{d},{d}", .{ entry.offset, entry.numbytes });
        defer allocator.free(entry_str);
        try result.appendSlice(allocator, entry_str);
    }

    return result.toOwnedSlice(allocator);
}

/// Parse PAX sparse map string into regions
pub fn parsePaxSparseMap(allocator: std.mem.Allocator, map_str: []const u8) !SparseRegions {
    var result = SparseRegions{ .allocator = allocator };
    errdefer result.deinit();

    var iter = std.mem.splitScalar(u8, map_str, ',');
    while (iter.next()) |offset_str| {
        const numbytes_str = iter.next() orelse break;
        
        const offset = std.fmt.parseInt(u64, offset_str, 10) catch continue;
        const numbytes = std.fmt.parseInt(u64, numbytes_str, 10) catch continue;
        
        try result.entries.append(allocator, .{
            .offset = offset,
            .numbytes = numbytes,
        });
    }

    return result;
}

/// Extract sparse file, creating holes where needed
pub fn extractSparseFile(
    file: std.fs.File,
    reader: anytype,
    regions: []const SparseEntry,
    logical_size: u64,
) !void {
    var buf: [BLOCK_SIZE]u8 = undefined;

    // First, set the file size to create a sparse file
    try file.setEndPos(logical_size);

    // Write each data region
    for (regions) |entry| {
        // Seek to the correct position
        try file.seekTo(entry.offset);

        // Read and write the data
        var remaining = entry.numbytes;
        while (remaining > 0) {
            const to_read = @min(BLOCK_SIZE, remaining);
            const bytes_read = try reader.read(buf[0..to_read]);
            if (bytes_read == 0) break;

            _ = try file.write(buf[0..bytes_read]);
            remaining -= bytes_read;
        }
    }
}

// Tests
test "sparse entry structure size" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(GnuSparseEntry));
}

test "gnu sparse header size" {
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(GnuSparseHeader));
}

test "zero block detection" {
    var zeros: [1024]u8 = [_]u8{0} ** 1024;
    try std.testing.expect(isZeroBlock(&zeros));

    zeros[512] = 1;
    try std.testing.expect(!isZeroBlock(&zeros));
}

test "physical size calculation" {
    const regions = [_]SparseEntry{
        .{ .offset = 0, .numbytes = 4096 },
        .{ .offset = 8192, .numbytes = 4096 },
        .{ .offset = 16384, .numbytes = 2048 },
    };

    try std.testing.expectEqual(@as(u64, 10240), calculatePhysicalSize(&regions));
}

test "sparse worthy detection" {
    const regions = [_]SparseEntry{
        .{ .offset = 0, .numbytes = 4096 },
        .{ .offset = 1048576, .numbytes = 4096 },
    };

    // 8KB data in 1MB+ file - definitely sparse worthy
    try std.testing.expect(isSparseWorthy(&regions, 1052672));

    // Full file - not sparse worthy
    const full = [_]SparseEntry{
        .{ .offset = 0, .numbytes = 10000 },
    };
    try std.testing.expect(!isSparseWorthy(&full, 10000));
}

test "pax sparse map building" {
    const regions = [_]SparseEntry{
        .{ .offset = 0, .numbytes = 4096 },
        .{ .offset = 8192, .numbytes = 4096 },
    };

    const map = try buildPaxSparseMap(std.testing.allocator, &regions);
    defer std.testing.allocator.free(map);

    try std.testing.expectEqualStrings("0,4096,8192,4096", map);
}

test "pax sparse map parsing" {
    var regions = try parsePaxSparseMap(std.testing.allocator, "0,4096,8192,4096");
    defer regions.deinit();

    try std.testing.expectEqual(@as(usize, 2), regions.items.len);
    try std.testing.expectEqual(@as(u64, 0), regions.items[0].offset);
    try std.testing.expectEqual(@as(u64, 4096), regions.items[0].numbytes);
    try std.testing.expectEqual(@as(u64, 8192), regions.items[1].offset);
    try std.testing.expectEqual(@as(u64, 4096), regions.items[1].numbytes);
}
