const std = @import("std");

/// TAR block size - all data is aligned to 512-byte blocks
pub const BLOCK_SIZE: usize = 512;

/// POSIX ustar magic string
pub const USTAR_MAGIC = "ustar";
pub const USTAR_VERSION = "00";

/// GNU tar magic string  
pub const GNU_MAGIC = "ustar ";

/// Type flags for tar entries
pub const TypeFlag = enum(u8) {
    regular = '0',
    regular_alt = 0, // Old tar format uses null byte
    hard_link = '1',
    symbolic_link = '2',
    character_device = '3',
    block_device = '4',
    directory = '5',
    fifo = '6',
    contiguous = '7',
    // GNU extensions
    gnu_long_name = 'L',
    gnu_long_link = 'K',
    gnu_sparse = 'S',
    // PAX extensions
    pax_extended = 'x',
    pax_global = 'g',
    // Vendor extensions
    vendor_A = 'A',
    vendor_D = 'D',
    vendor_I = 'I',
    vendor_M = 'M',
    vendor_N = 'N',
    vendor_V = 'V',
    vendor_X = 'X',

    pub fn fromByte(byte: u8) TypeFlag {
        return std.meta.intToEnum(TypeFlag, byte) catch .regular_alt;
    }

    pub fn toByte(self: TypeFlag) u8 {
        return @intFromEnum(self);
    }

    pub fn isRegularFile(self: TypeFlag) bool {
        return self == .regular or self == .regular_alt;
    }
};

/// POSIX tar header structure (512 bytes)
/// Based on IEEE Std 1003.1-2017 and GNU tar extensions
pub const PosixHeader = extern struct {
    name: [100]u8,      // offset 0: File name
    mode: [8]u8,        // offset 100: File mode (octal)
    uid: [8]u8,         // offset 108: Owner user ID (octal)
    gid: [8]u8,         // offset 116: Owner group ID (octal)
    size: [12]u8,       // offset 124: File size in bytes (octal)
    mtime: [12]u8,      // offset 136: Modification time (octal)
    chksum: [8]u8,      // offset 148: Header checksum
    typeflag: u8,       // offset 156: Type flag
    linkname: [100]u8,  // offset 157: Name of linked file
    magic: [6]u8,       // offset 257: "ustar\0" or "ustar "
    version: [2]u8,     // offset 263: "00"
    uname: [32]u8,      // offset 265: Owner user name
    gname: [32]u8,      // offset 297: Owner group name
    devmajor: [8]u8,    // offset 329: Device major number
    devminor: [8]u8,    // offset 337: Device minor number
    prefix: [155]u8,    // offset 345: Prefix for file name
    padding: [12]u8,    // offset 500: Padding to 512 bytes

    comptime {
        if (@sizeOf(PosixHeader) != BLOCK_SIZE) {
            @compileError("PosixHeader must be exactly 512 bytes");
        }
    }

    /// Create a zeroed header
    pub fn init() PosixHeader {
        return std.mem.zeroes(PosixHeader);
    }

    /// Check if this is a zero block (end of archive marker)
    pub fn isZeroBlock(self: *const PosixHeader) bool {
        const bytes = std.mem.asBytes(self);
        for (bytes) |b| {
            if (b != 0) return false;
        }
        return true;
    }

    /// Check if this header has valid ustar magic
    pub fn isUstar(self: *const PosixHeader) bool {
        // Check for POSIX ustar format
        if (std.mem.eql(u8, self.magic[0..5], USTAR_MAGIC)) {
            return true;
        }
        // Check for GNU tar format
        if (std.mem.eql(u8, self.magic[0..6], GNU_MAGIC)) {
            return true;
        }
        return false;
    }

    /// Get the type flag
    pub fn getTypeFlag(self: *const PosixHeader) TypeFlag {
        return TypeFlag.fromByte(self.typeflag);
    }

    /// Get the file name, combining prefix and name if needed
    pub fn getName(self: *const PosixHeader, allocator: std.mem.Allocator) ![]u8 {
        const name = extractString(&self.name);
        const prefix = extractString(&self.prefix);

        if (prefix.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
        } else {
            return allocator.dupe(u8, name);
        }
    }

    /// Get file size
    pub fn getSize(self: *const PosixHeader) !u64 {
        return parseOctal(u64, &self.size);
    }

    /// Get file mode/permissions
    pub fn getMode(self: *const PosixHeader) !u32 {
        return parseOctal(u32, &self.mode);
    }

    /// Get modification time
    pub fn getMtime(self: *const PosixHeader) !i64 {
        return parseOctal(i64, &self.mtime);
    }

    /// Get user ID
    pub fn getUid(self: *const PosixHeader) !u32 {
        return parseOctal(u32, &self.uid);
    }

    /// Get group ID
    pub fn getGid(self: *const PosixHeader) !u32 {
        return parseOctal(u32, &self.gid);
    }

    /// Get user name
    pub fn getUname(self: *const PosixHeader) []const u8 {
        return extractString(&self.uname);
    }

    /// Get group name
    pub fn getGname(self: *const PosixHeader) []const u8 {
        return extractString(&self.gname);
    }

    /// Get link name for symlinks/hardlinks
    pub fn getLinkname(self: *const PosixHeader) []const u8 {
        return extractString(&self.linkname);
    }

    /// Calculate the checksum for this header
    pub fn calculateChecksum(self: *const PosixHeader) u32 {
        const bytes = std.mem.asBytes(self);
        var sum: u32 = 0;

        // Sum all bytes, treating checksum field as spaces
        for (bytes, 0..) |b, i| {
            if (i >= 148 and i < 156) {
                sum += ' '; // Checksum field treated as spaces
            } else {
                sum += b;
            }
        }
        return sum;
    }

    /// Verify the header checksum
    pub fn verifyChecksum(self: *const PosixHeader) bool {
        const stored = parseOctal(u32, &self.chksum) catch return false;
        const calculated = self.calculateChecksum();
        return stored == calculated;
    }

    /// Set the checksum field
    pub fn setChecksum(self: *PosixHeader) void {
        // First, fill checksum field with spaces
        @memset(&self.chksum, ' ');

        // Calculate checksum
        const sum = self.calculateChecksum();

        // Write checksum as octal with null terminator
        _ = std.fmt.bufPrint(&self.chksum, "{o:0>6}\x00 ", .{sum}) catch {};
    }

    /// Set file name, handling prefix for long names
    pub fn setName(self: *PosixHeader, name: []const u8) !void {
        if (name.len <= 100) {
            @memset(&self.name, 0);
            @memcpy(self.name[0..name.len], name);
        } else if (name.len <= 255) {
            // Try to split at a path separator
            var split_pos: ?usize = null;
            var i: usize = name.len;
            while (i > 0) {
                i -= 1;
                if (name[i] == '/') {
                    if (i <= 155 and name.len - i - 1 <= 100) {
                        split_pos = i;
                        break;
                    }
                }
            }

            if (split_pos) |pos| {
                @memset(&self.prefix, 0);
                @memset(&self.name, 0);
                @memcpy(self.prefix[0..pos], name[0..pos]);
                @memcpy(self.name[0..(name.len - pos - 1)], name[pos + 1 ..]);
            } else {
                return error.FileNameTooLong;
            }
        } else {
            return error.FileNameTooLong;
        }
    }

    /// Set file size
    pub fn setSize(self: *PosixHeader, size: u64) void {
        formatOctal(&self.size, size);
    }

    /// Set file mode
    pub fn setMode(self: *PosixHeader, mode: u32) void {
        formatOctal(&self.mode, mode);
    }

    /// Set modification time
    pub fn setMtime(self: *PosixHeader, mtime: i64) void {
        formatOctal(&self.mtime, @as(u64, @intCast(mtime)));
    }

    /// Set user ID
    pub fn setUid(self: *PosixHeader, uid: u32) void {
        formatOctal(&self.uid, uid);
    }

    /// Set group ID
    pub fn setGid(self: *PosixHeader, gid: u32) void {
        formatOctal(&self.gid, gid);
    }

    /// Set type flag
    pub fn setTypeFlag(self: *PosixHeader, flag: TypeFlag) void {
        self.typeflag = @intFromEnum(flag);
    }

    /// Set ustar magic and version
    pub fn setUstarMagic(self: *PosixHeader) void {
        @memcpy(self.magic[0..5], USTAR_MAGIC);
        self.magic[5] = 0;
        @memcpy(&self.version, USTAR_VERSION);
    }

    /// Set user name
    pub fn setUname(self: *PosixHeader, name: []const u8) void {
        @memset(&self.uname, 0);
        const len = @min(name.len, 31);
        @memcpy(self.uname[0..len], name[0..len]);
    }

    /// Set group name
    pub fn setGname(self: *PosixHeader, name: []const u8) void {
        @memset(&self.gname, 0);
        const len = @min(name.len, 31);
        @memcpy(self.gname[0..len], name[0..len]);
    }

    /// Set link name
    pub fn setLinkname(self: *PosixHeader, name: []const u8) void {
        @memset(&self.linkname, 0);
        const len = @min(name.len, 99);
        @memcpy(self.linkname[0..len], name[0..len]);
    }

    /// Set device major number
    pub fn setDevMajor(self: *PosixHeader, major: u32) void {
        formatOctal(&self.devmajor, major);
    }

    /// Set device minor number
    pub fn setDevMinor(self: *PosixHeader, minor: u32) void {
        formatOctal(&self.devminor, minor);
    }

    /// Get device major number
    pub fn getDevMajor(self: *const PosixHeader) !u32 {
        return parseOctal(u32, &self.devmajor);
    }

    /// Get device minor number
    pub fn getDevMinor(self: *const PosixHeader) !u32 {
        return parseOctal(u32, &self.devminor);
    }
};

/// Extract a null-terminated or space-padded string from a fixed-size buffer
pub fn extractString(buf: []const u8) []const u8 {
    var len: usize = 0;
    for (buf, 0..) |c, i| {
        if (c == 0) break;
        len = i + 1;
    }
    // Trim trailing spaces
    while (len > 0 and buf[len - 1] == ' ') {
        len -= 1;
    }
    return buf[0..len];
}

/// Parse an octal number from a tar header field
/// Handles both traditional octal and base-256 encoding for large values
pub fn parseOctal(comptime T: type, buf: []const u8) !T {
    // Check for base-256 encoding (high bit set)
    if (buf.len > 0 and (buf[0] & 0x80) != 0) {
        // Base-256 encoding for large values
        var value: u64 = 0;
        const is_negative = (buf[0] & 0x40) != 0;
        
        // First byte: mask off high bit (and sign bit for negative)
        value = buf[0] & 0x3F;
        
        // Remaining bytes: full 8 bits each
        for (buf[1..]) |b| {
            value = (value << 8) | @as(u64, b);
        }
        
        if (is_negative) {
            // Handle negative values (rarely used in tar)
            return @as(T, @intCast(value));
        }
        return @as(T, @intCast(value));
    }

    // Traditional octal encoding
    var value: T = 0;
    for (buf) |c| {
        if (c == ' ' or c == 0) continue;
        if (c < '0' or c > '7') break;
        value = value * 8 + @as(T, c - '0');
    }
    return value;
}

/// Maximum value that can be stored in octal in a 12-byte field (11 octal digits)
/// 8^11 - 1 = 8589934591 (about 8GB)
pub const MAX_OCTAL_VALUE: u64 = 0o77777777777;

/// Format a number as octal for tar header field
/// For values > MAX_OCTAL_VALUE, uses GNU base-256 encoding
pub fn formatOctal(buf: []u8, value: u64) void {
    const len = buf.len;
    
    // Check if value fits in octal representation
    // For a 12-byte field, max octal is 11 digits (77777777777 = ~8GB)
    if (value <= MAX_OCTAL_VALUE) {
        @memset(buf, '0');
        if (len > 1) {
            buf[len - 1] = 0; // Null terminator
        }

        var v = value;
        var i: usize = len - 2;
        while (v > 0) : (i -= 1) {
            buf[i] = @as(u8, @intCast(v & 7)) + '0';
            v >>= 3;
            if (i == 0) break;
        }
    } else {
        // Use GNU base-256 encoding for large values
        formatBase256(buf, value);
    }
}

/// Format a number using GNU base-256 encoding
/// First byte has high bit set to indicate base-256
pub fn formatBase256(buf: []u8, value: u64) void {
    const len = buf.len;
    @memset(buf, 0);
    
    // Set high bit of first byte to indicate base-256
    buf[0] = 0x80;
    
    // Write value in big-endian format
    var v = value;
    var i: usize = len - 1;
    while (i > 0) : (i -= 1) {
        buf[i] = @as(u8, @intCast(v & 0xFF));
        v >>= 8;
    }
}

/// Calculate how many blocks are needed for a given size
pub fn blocksNeeded(size: u64) u64 {
    return (size + BLOCK_SIZE - 1) / BLOCK_SIZE;
}

// Tests
test "PosixHeader size" {
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(PosixHeader));
}

test "parseOctal" {
    const buf = "0000644\x00".*;
    try std.testing.expectEqual(@as(u32, 420), try parseOctal(u32, &buf));
}

test "parseOctal with spaces" {
    const buf = " 644 \x00\x00\x00".*;
    try std.testing.expectEqual(@as(u32, 420), try parseOctal(u32, &buf));
}

test "extractString" {
    const buf = "hello\x00\x00\x00\x00\x00".*;
    try std.testing.expectEqualStrings("hello", extractString(&buf));
}

test "extractString with trailing spaces" {
    const buf = "hello   \x00\x00".*;
    try std.testing.expectEqualStrings("hello", extractString(&buf));
}

test "checksum calculation" {
    var header = PosixHeader.init();
    try header.setName("test.txt");
    header.setMode(0o644);
    header.setSize(100);
    header.setTypeFlag(.regular);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
}

test "zero block detection" {
    var header = PosixHeader.init();
    try std.testing.expect(header.isZeroBlock());

    try header.setName("test");
    try std.testing.expect(!header.isZeroBlock());
}

test "large file size base-256 encoding" {
    // Test a value larger than 8GB (which requires base-256)
    const large_size: u64 = 10 * 1024 * 1024 * 1024; // 10 GB
    var buf: [12]u8 = undefined;
    formatOctal(&buf, large_size);
    
    // Should be base-256 encoded (high bit set)
    try std.testing.expect((buf[0] & 0x80) != 0);
    
    // Parse it back
    const parsed = try parseOctal(u64, &buf);
    try std.testing.expectEqual(large_size, parsed);
}

test "small file size octal encoding" {
    // Test a small value that fits in octal
    const small_size: u64 = 1024 * 1024; // 1 MB
    var buf: [12]u8 = undefined;
    formatOctal(&buf, small_size);
    
    // Should be octal encoded (high bit NOT set)
    try std.testing.expect((buf[0] & 0x80) == 0);
    
    // Parse it back
    const parsed = try parseOctal(u64, &buf);
    try std.testing.expectEqual(small_size, parsed);
}

test "base-256 boundary value" {
    // Test value at the boundary (just over 8GB)
    const boundary_size: u64 = MAX_OCTAL_VALUE + 1;
    var buf: [12]u8 = undefined;
    formatOctal(&buf, boundary_size);
    
    // Should be base-256 encoded
    try std.testing.expect((buf[0] & 0x80) != 0);
    
    // Parse it back
    const parsed = try parseOctal(u64, &buf);
    try std.testing.expectEqual(boundary_size, parsed);
}
