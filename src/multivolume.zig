// Multi-volume archive support for tar-zig
// Implements -M, --multi-volume options
// Based on GNU tar multi-volume format

const std = @import("std");
const tar_header = @import("tar_header.zig");
const buffer = @import("buffer.zig");

const PosixHeader = tar_header.PosixHeader;
const TypeFlag = tar_header.TypeFlag;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;

/// Multi-volume header type flag
pub const MULTIVOLUME_FLAG = 'M';
/// Continuation header type flag  
pub const CONTINUATION_FLAG = 'V';

/// Volume label information
pub const VolumeInfo = struct {
    /// Volume label/name
    label: []const u8,
    /// Volume number (1-based)
    volume_number: u32,
    /// Total expected volumes (0 if unknown)
    total_volumes: u32,
    /// Creation timestamp
    timestamp: i64,
};

/// State for multi-volume archive operations
pub const MultiVolumeState = struct {
    allocator: std.mem.Allocator,
    /// Maximum size per volume (bytes)
    volume_size: u64,
    /// Current volume number
    current_volume: u32,
    /// Bytes written to current volume
    bytes_written: u64,
    /// Base archive name (for generating volume names)
    base_name: []const u8,
    /// Current file being written (for continuation)
    current_file_name: ?[]const u8,
    /// Offset into current file (for continuation)
    current_file_offset: u64,
    /// Total size of current file
    current_file_size: u64,
    /// Volume label
    label: ?[]const u8,
    /// Interactive mode - prompt user for volume changes
    interactive: bool,
    /// Callback for volume change notification
    volume_change_callback: ?*const fn (u32, []const u8) void,

    pub fn init(allocator: std.mem.Allocator, base_name: []const u8, volume_size: u64) !MultiVolumeState {
        return .{
            .allocator = allocator,
            .volume_size = volume_size,
            .current_volume = 1,
            .bytes_written = 0,
            .base_name = try allocator.dupe(u8, base_name),
            .current_file_name = null,
            .current_file_offset = 0,
            .current_file_size = 0,
            .label = null,
            .interactive = false,
            .volume_change_callback = null,
        };
    }

    pub fn deinit(self: *MultiVolumeState) void {
        self.allocator.free(self.base_name);
        if (self.current_file_name) |name| {
            self.allocator.free(name);
        }
        if (self.label) |l| {
            self.allocator.free(l);
        }
    }

    /// Get the file name for a specific volume
    pub fn getVolumeName(self: *const MultiVolumeState, volume: u32) ![]u8 {
        // Generate name like: archive.tar-01, archive.tar-02, etc.
        return std.fmt.allocPrint(self.allocator, "{s}-{d:0>2}", .{ self.base_name, volume });
    }

    /// Check if we need to switch volumes before writing n bytes
    pub fn needsVolumeSwitch(self: *const MultiVolumeState, bytes_to_write: u64) bool {
        return self.bytes_written + bytes_to_write > self.volume_size;
    }

    /// Get remaining space in current volume
    pub fn remainingSpace(self: *const MultiVolumeState) u64 {
        if (self.bytes_written >= self.volume_size) return 0;
        return self.volume_size - self.bytes_written;
    }

    /// Start writing a new file
    pub fn startFile(self: *MultiVolumeState, name: []const u8, size: u64) !void {
        if (self.current_file_name) |old| {
            self.allocator.free(old);
        }
        self.current_file_name = try self.allocator.dupe(u8, name);
        self.current_file_size = size;
        self.current_file_offset = 0;
    }

    /// Update file progress
    pub fn updateFileProgress(self: *MultiVolumeState, bytes_written: u64) void {
        self.current_file_offset += bytes_written;
    }

    /// Finish current file
    pub fn finishFile(self: *MultiVolumeState) void {
        if (self.current_file_name) |name| {
            self.allocator.free(name);
        }
        self.current_file_name = null;
        self.current_file_offset = 0;
        self.current_file_size = 0;
    }

    /// Switch to next volume
    pub fn switchVolume(self: *MultiVolumeState) !void {
        self.current_volume += 1;
        self.bytes_written = 0;

        if (self.volume_change_callback) |callback| {
            const name = try self.getVolumeName(self.current_volume);
            defer self.allocator.free(name);
            callback(self.current_volume, name);
        }
    }

    /// Record bytes written
    pub fn recordWrite(self: *MultiVolumeState, bytes: u64) void {
        self.bytes_written += bytes;
    }
};

/// Create a volume header for a multi-volume archive
pub fn createVolumeHeader(volume_info: VolumeInfo) PosixHeader {
    var header = PosixHeader.init();

    // Set volume label as name
    const label_len = @min(volume_info.label.len, 100);
    @memcpy(header.name[0..label_len], volume_info.label[0..label_len]);

    // Volume header type
    header.typeflag = @intCast(CONTINUATION_FLAG);

    header.setSize(0);
    header.setMtime(volume_info.timestamp);
    header.setMode(0);
    header.setGnuMagic();
    header.setChecksum();

    return header;
}

/// Create a continuation header for a file split across volumes
pub fn createContinuationHeader(
    file_name: []const u8,
    remaining_size: u64,
    offset: u64,
    original_header: *const PosixHeader,
) PosixHeader {
    var header = PosixHeader.init();

    // Copy name from original
    const name_len = @min(file_name.len, 100);
    @memcpy(header.name[0..name_len], file_name[0..name_len]);

    // Multi-volume continuation type
    header.typeflag = @intCast(MULTIVOLUME_FLAG);

    // Set the remaining size
    header.setSize(remaining_size);

    // Copy other fields from original
    header.mode = original_header.mode;
    header.uid = original_header.uid;
    header.gid = original_header.gid;
    header.mtime = original_header.mtime;

    // Store offset in the 'offset' field (GNU extension)
    // GNU tar uses the atime field for this in continuation headers
    var offset_buf: [12]u8 = undefined;
    _ = std.fmt.bufPrint(&offset_buf, "{o:0>11}", .{offset}) catch {};
    // Store in padding area or use PAX header for large offsets

    header.setGnuMagic();
    header.setChecksum();

    return header;
}

/// Parse a multi-volume/continuation header
pub fn parseMultiVolumeHeader(header: *const PosixHeader) ?struct {
    is_continuation: bool,
    offset: u64,
} {
    const typeflag = header.typeflag;

    if (typeflag == MULTIVOLUME_FLAG) {
        // This is a continuation header
        // Try to extract offset (GNU extension)
        return .{
            .is_continuation = true,
            .offset = 0, // Would need to parse from extended area
        };
    }

    if (typeflag == CONTINUATION_FLAG) {
        // This is a volume label header
        return .{
            .is_continuation = false,
            .offset = 0,
        };
    }

    return null;
}

/// Multi-volume archive writer
pub const MultiVolumeWriter = struct {
    allocator: std.mem.Allocator,
    state: MultiVolumeState,
    current_writer: ?buffer.ArchiveWriter,

    pub fn init(allocator: std.mem.Allocator, base_name: []const u8, volume_size: u64) !MultiVolumeWriter {
        var writer = MultiVolumeWriter{
            .allocator = allocator,
            .state = try MultiVolumeState.init(allocator, base_name, volume_size),
            .current_writer = null,
        };

        // Open first volume
        try writer.openCurrentVolume();

        return writer;
    }

    pub fn deinit(self: *MultiVolumeWriter) void {
        if (self.current_writer) |*w| {
            w.deinit();
        }
        self.state.deinit();
    }

    /// Open the current volume file for writing
    fn openCurrentVolume(self: *MultiVolumeWriter) !void {
        if (self.current_writer) |*w| {
            try w.finish();
            w.deinit();
        }

        const volume_name = try self.state.getVolumeName(self.state.current_volume);
        defer self.allocator.free(volume_name);

        self.current_writer = try buffer.ArchiveWriter.init(self.allocator, volume_name, .none);

        // Write volume header if we have a label
        if (self.state.label) |label| {
            const vol_header = createVolumeHeader(.{
                .label = label,
                .volume_number = self.state.current_volume,
                .total_volumes = 0,
                .timestamp = std.time.timestamp(),
            });
            try self.current_writer.?.writeHeader(&vol_header);
            self.state.recordWrite(BLOCK_SIZE);
        }
    }

    /// Write a header, switching volumes if needed
    pub fn writeHeader(self: *MultiVolumeWriter, header: *const PosixHeader) !void {
        if (self.state.needsVolumeSwitch(BLOCK_SIZE)) {
            try self.switchToNextVolume();
        }

        try self.current_writer.?.writeHeader(header);
        self.state.recordWrite(BLOCK_SIZE);
    }

    /// Write file data, splitting across volumes if needed
    pub fn writeData(self: *MultiVolumeWriter, file: std.fs.File, size: u64, original_header: *const PosixHeader) !void {
        var remaining = size;
        var offset: u64 = 0;

        // Get file name from header for continuation
        const name = std.mem.sliceTo(&original_header.name, 0);
        try self.state.startFile(name, size);

        while (remaining > 0) {
            const space = self.state.remainingSpace();

            if (space == 0) {
                // Need to switch volumes
                try self.switchToNextVolume();

                // Write continuation header
                const cont_header = createContinuationHeader(
                    name,
                    remaining,
                    offset,
                    original_header,
                );
                try self.current_writer.?.writeHeader(&cont_header);
                self.state.recordWrite(BLOCK_SIZE);
                continue;
            }

            // Write as much as we can to current volume
            const to_write = @min(remaining, space);
            const blocks = (to_write + BLOCK_SIZE - 1) / BLOCK_SIZE;
            const padded_size = blocks * BLOCK_SIZE;

            // Read and write data
            var buf: [BLOCK_SIZE]u8 = undefined;
            var written: u64 = 0;

            while (written < to_write) {
                const chunk = @min(BLOCK_SIZE, to_write - written);
                const bytes_read = try file.read(buf[0..chunk]);
                if (bytes_read == 0) break;

                // Pad last block if needed
                if (bytes_read < BLOCK_SIZE) {
                    @memset(buf[bytes_read..], 0);
                }

                try self.current_writer.?.writeBytes(&buf);
                written += bytes_read;
            }

            self.state.recordWrite(padded_size);
            self.state.updateFileProgress(to_write);
            remaining -= to_write;
            offset += to_write;
        }

        self.state.finishFile();
    }

    /// Switch to the next volume
    fn switchToNextVolume(self: *MultiVolumeWriter) !void {
        // Close current volume properly
        if (self.current_writer) |*w| {
            try w.writeEndOfArchive();
            try w.finish();
            w.deinit();
            self.current_writer = null;
        }

        try self.state.switchVolume();
        try self.openCurrentVolume();
    }

    /// Write end of archive markers
    pub fn writeEndOfArchive(self: *MultiVolumeWriter) !void {
        if (self.current_writer) |*w| {
            try w.writeEndOfArchive();
        }
    }

    /// Finish and close all volumes
    pub fn finish(self: *MultiVolumeWriter) !void {
        if (self.current_writer) |*w| {
            try w.finish();
        }
    }
};

/// Multi-volume archive reader
pub const MultiVolumeReader = struct {
    allocator: std.mem.Allocator,
    state: MultiVolumeState,
    /// File being continued from previous volume
    continuation_file: ?[]const u8,
    /// Remaining bytes in continuation
    continuation_remaining: u64,

    pub fn init(allocator: std.mem.Allocator, base_name: []const u8) !MultiVolumeReader {
        return .{
            .allocator = allocator,
            .state = try MultiVolumeState.init(allocator, base_name, 0),
            .continuation_file = null,
            .continuation_remaining = 0,
        };
    }

    pub fn deinit(self: *MultiVolumeReader) void {
        if (self.continuation_file) |f| {
            self.allocator.free(f);
        }
        self.state.deinit();
    }

    /// Check if a header is a continuation of a previous file
    pub fn isContinuation(self: *const MultiVolumeReader, header: *const PosixHeader) bool {
        _ = self;
        return header.typeflag == MULTIVOLUME_FLAG;
    }

    /// Check if a header is a volume label
    pub fn isVolumeLabel(self: *const MultiVolumeReader, header: *const PosixHeader) bool {
        _ = self;
        return header.typeflag == CONTINUATION_FLAG;
    }
};

test "MultiVolumeState volume naming" {
    var state = try MultiVolumeState.init(std.testing.allocator, "archive.tar", 1024 * 1024);
    defer state.deinit();

    const name1 = try state.getVolumeName(1);
    defer std.testing.allocator.free(name1);
    try std.testing.expectEqualStrings("archive.tar-01", name1);

    const name2 = try state.getVolumeName(99);
    defer std.testing.allocator.free(name2);
    try std.testing.expectEqualStrings("archive.tar-99", name2);
}

test "MultiVolumeState space tracking" {
    var state = try MultiVolumeState.init(std.testing.allocator, "archive.tar", 10000);
    defer state.deinit();

    try std.testing.expect(!state.needsVolumeSwitch(5000));
    state.recordWrite(5000);
    try std.testing.expect(!state.needsVolumeSwitch(5000));
    try std.testing.expect(state.needsVolumeSwitch(5001));
    try std.testing.expectEqual(@as(u64, 5000), state.remainingSpace());
}

test "volume header creation" {
    const header = createVolumeHeader(.{
        .label = "TestVolume",
        .volume_number = 1,
        .total_volumes = 3,
        .timestamp = 1000000,
    });

    try std.testing.expectEqual(@as(u8, CONTINUATION_FLAG), header.typeflag);
    try std.testing.expectEqualStrings("TestVolume", std.mem.sliceTo(&header.name, 0));
}

test "continuation header creation" {
    var original = PosixHeader.init();
    original.setName("testfile.txt") catch unreachable;
    original.setSize(10000);
    original.setMode(0o644);

    const cont = createContinuationHeader("testfile.txt", 5000, 5000, &original);

    try std.testing.expectEqual(@as(u8, MULTIVOLUME_FLAG), cont.typeflag);
    try std.testing.expectEqual(@as(u64, 5000), cont.getSize());
}
