const std = @import("std");
const tar_header = @import("tar_header");

// Large Files Tests for tar-zig
// Tests for files > 8GB that require base-256 encoding

// Test maximum octal value boundary
test "max octal value constant" {
    // Maximum value that fits in 11 octal digits (size field)
    // 8^11 - 1 = 8589934591 (about 8 GB)
    try std.testing.expectEqual(@as(u64, 8589934591), tar_header.MAX_OCTAL_VALUE);
}

// Test large file size encoding (base-256)
test "large file base256 encoding" {
    const large_sizes = [_]u64{
        tar_header.MAX_OCTAL_VALUE + 1, // Just over 8 GB
        10 * 1024 * 1024 * 1024, // 10 GB
        100 * 1024 * 1024 * 1024, // 100 GB
        1024 * 1024 * 1024 * 1024, // 1 TB
    };

    for (large_sizes) |size| {
        var buf: [12]u8 = undefined;
        tar_header.formatOctal(&buf, size);

        // Verify base-256 encoding (high bit set)
        try std.testing.expect((buf[0] & 0x80) != 0);

        // Verify roundtrip
        const parsed = try tar_header.parseOctal(u64, &buf);
        try std.testing.expectEqual(size, parsed);
    }
}

// Test regular octal encoding for small files
test "small file octal encoding" {
    const small_sizes = [_]u64{
        0,
        1,
        512,
        1024,
        1024 * 1024, // 1 MB
        1024 * 1024 * 1024, // 1 GB
        tar_header.MAX_OCTAL_VALUE, // Max octal
    };

    for (small_sizes) |size| {
        var buf: [12]u8 = undefined;
        tar_header.formatOctal(&buf, size);

        // Should NOT use base-256 for small values
        try std.testing.expect((buf[0] & 0x80) == 0);

        const parsed = try tar_header.parseOctal(u64, &buf);
        try std.testing.expectEqual(size, parsed);
    }
}

// Test large file header creation
test "large file header" {
    var header = tar_header.PosixHeader.init();
    try header.setName("large_file.bin");
    header.setTypeFlag(.regular);
    header.setMode(0o644);

    // Set a 10 GB file size
    const size_10gb: u64 = 10 * 1024 * 1024 * 1024;
    header.setSize(size_10gb);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(size_10gb, try header.getSize());
}

// Test blocks needed for large files
test "large file block calculation" {
    // 10 GB file
    const size_10gb: u64 = 10 * 1024 * 1024 * 1024;
    const blocks_10gb = tar_header.blocksNeeded(size_10gb);

    // 10 GB / 512 bytes = 20971520 blocks
    try std.testing.expectEqual(@as(u64, 20971520), blocks_10gb);

    // 1 TB file
    const size_1tb: u64 = 1024 * 1024 * 1024 * 1024;
    const blocks_1tb = tar_header.blocksNeeded(size_1tb);

    // 1 TB / 512 bytes = 2147483648 blocks
    try std.testing.expectEqual(@as(u64, 2147483648), blocks_1tb);
}

// Test base-256 boundary case
test "base256 boundary" {
    // Test value just at the boundary
    var buf: [12]u8 = undefined;

    // MAX_OCTAL_VALUE should use octal
    tar_header.formatOctal(&buf, tar_header.MAX_OCTAL_VALUE);
    try std.testing.expect((buf[0] & 0x80) == 0);

    // MAX_OCTAL_VALUE + 1 should use base-256
    tar_header.formatOctal(&buf, tar_header.MAX_OCTAL_VALUE + 1);
    try std.testing.expect((buf[0] & 0x80) != 0);
}

// Test various large file sizes
test "various large file sizes" {
    const test_sizes = [_]u64{
        8 * 1024 * 1024 * 1024 + 1, // 8 GB + 1 byte
        9 * 1024 * 1024 * 1024, // 9 GB
        16 * 1024 * 1024 * 1024, // 16 GB
        32 * 1024 * 1024 * 1024, // 32 GB
        64 * 1024 * 1024 * 1024, // 64 GB
        128 * 1024 * 1024 * 1024, // 128 GB
        256 * 1024 * 1024 * 1024, // 256 GB
        512 * 1024 * 1024 * 1024, // 512 GB
    };

    for (test_sizes) |size| {
        var header = tar_header.PosixHeader.init();
        header.setSize(size);

        const retrieved = try header.getSize();
        try std.testing.expectEqual(size, retrieved);
    }
}

// Test mtime for large timestamps
test "large mtime values" {
    var header = tar_header.PosixHeader.init();

    // Current time (2024)
    header.setMtime(1704067200);
    try std.testing.expectEqual(@as(i64, 1704067200), try header.getMtime());

    // Year 2100 timestamp
    header.setMtime(4102444800);
    try std.testing.expectEqual(@as(i64, 4102444800), try header.getMtime());

    // Year 2200 timestamp (might need base-256)
    header.setMtime(7258118400);
    try std.testing.expectEqual(@as(i64, 7258118400), try header.getMtime());
}

// Test UID/GID large values
test "large uid gid values" {
    var header = tar_header.PosixHeader.init();

    // Normal UID/GID
    header.setUid(1000);
    header.setGid(1000);
    try std.testing.expectEqual(@as(u32, 1000), try header.getUid());
    try std.testing.expectEqual(@as(u32, 1000), try header.getGid());

    // Large UID/GID (some systems use large values)
    header.setUid(65534); // nobody
    header.setGid(65534); // nogroup
    try std.testing.expectEqual(@as(u32, 65534), try header.getUid());
    try std.testing.expectEqual(@as(u32, 65534), try header.getGid());

    // Maximum UID/GID that fits in 8-byte octal field (7 octal digits)
    // 8^7 - 1 = 2097151
    header.setUid(2097151);
    header.setGid(2097151);
    try std.testing.expectEqual(@as(u32, 2097151), try header.getUid());
    try std.testing.expectEqual(@as(u32, 2097151), try header.getGid());
}

// Test header with all large values
test "header with all large values" {
    var header = tar_header.PosixHeader.init();
    try header.setName("very_large_file.dat");
    header.setTypeFlag(.regular);
    header.setMode(0o644);
    header.setUid(100000);
    header.setGid(100000);
    header.setSize(50 * 1024 * 1024 * 1024); // 50 GB
    header.setMtime(4102444800); // Year 2100
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
}

// Test 64-bit size limit
test "maximum 64bit file size" {
    // Test near maximum u64 value
    const max_practical: u64 = (1 << 63) - 1; // Max positive i64

    var buf: [12]u8 = undefined;
    tar_header.formatOctal(&buf, max_practical);

    const parsed = try tar_header.parseOctal(u64, &buf);
    try std.testing.expectEqual(max_practical, parsed);
}
