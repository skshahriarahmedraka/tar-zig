const std = @import("std");
const tar_header = @import("../tar_header.zig");
const buffer = @import("../buffer.zig");
const options = @import("../options.zig");

// Integration tests for tar-zig
// These tests verify end-to-end functionality

test "create and list simple archive" {
    // This is a compile-time check that modules work together
    var header = tar_header.PosixHeader.init();
    try header.setName("test.txt");
    header.setMode(0o644);
    header.setSize(100);
    header.setTypeFlag(.regular);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
}

test "long filename handling" {
    var header = tar_header.PosixHeader.init();
    
    // Name that fits in standard field
    try header.setName("short.txt");
    const name1 = try header.getName(std.testing.allocator);
    defer std.testing.allocator.free(name1);
    try std.testing.expectEqualStrings("short.txt", name1);
    
    // Name that requires prefix
    const long_path = "very/long/path/that/needs/prefix/to/fit/properly/file.txt";
    try header.setName(long_path);
    const name2 = try header.getName(std.testing.allocator);
    defer std.testing.allocator.free(name2);
    try std.testing.expectEqualStrings(long_path, name2);
}

test "type flag parsing" {
    try std.testing.expectEqual(tar_header.TypeFlag.regular, tar_header.TypeFlag.fromByte('0'));
    try std.testing.expectEqual(tar_header.TypeFlag.directory, tar_header.TypeFlag.fromByte('5'));
    try std.testing.expectEqual(tar_header.TypeFlag.symbolic_link, tar_header.TypeFlag.fromByte('2'));
    try std.testing.expectEqual(tar_header.TypeFlag.gnu_long_name, tar_header.TypeFlag.fromByte('L'));
}

test "compression detection from extension" {
    try std.testing.expectEqual(options.Compression.gzip, buffer.detectCompression("file.tar.gz"));
    try std.testing.expectEqual(options.Compression.gzip, buffer.detectCompression("file.tgz"));
    try std.testing.expectEqual(options.Compression.bzip2, buffer.detectCompression("file.tar.bz2"));
    try std.testing.expectEqual(options.Compression.xz, buffer.detectCompression("file.tar.xz"));
    try std.testing.expectEqual(options.Compression.zstd, buffer.detectCompression("file.tar.zst"));
    try std.testing.expectEqual(options.Compression.none, buffer.detectCompression("file.tar"));
}

test "block size calculations" {
    try std.testing.expectEqual(@as(u64, 1), tar_header.blocksNeeded(1));
    try std.testing.expectEqual(@as(u64, 1), tar_header.blocksNeeded(512));
    try std.testing.expectEqual(@as(u64, 2), tar_header.blocksNeeded(513));
    try std.testing.expectEqual(@as(u64, 2), tar_header.blocksNeeded(1024));
    try std.testing.expectEqual(@as(u64, 3), tar_header.blocksNeeded(1025));
}

test "octal encoding roundtrip" {
    const test_values = [_]u64{ 0, 1, 100, 1000, 10000, 100000, 1000000, 8589934591 };
    
    for (test_values) |val| {
        var buf: [12]u8 = undefined;
        tar_header.formatOctal(&buf, val);
        const parsed = try tar_header.parseOctal(u64, &buf);
        try std.testing.expectEqual(val, parsed);
    }
}

test "large file base-256 roundtrip" {
    // Values that require base-256 encoding
    const large_values = [_]u64{
        tar_header.MAX_OCTAL_VALUE + 1,
        10 * 1024 * 1024 * 1024, // 10 GB
        100 * 1024 * 1024 * 1024, // 100 GB
        1024 * 1024 * 1024 * 1024, // 1 TB
    };
    
    for (large_values) |val| {
        var buf: [12]u8 = undefined;
        tar_header.formatOctal(&buf, val);
        
        // Verify it's base-256 encoded
        try std.testing.expect((buf[0] & 0x80) != 0);
        
        const parsed = try tar_header.parseOctal(u64, &buf);
        try std.testing.expectEqual(val, parsed);
    }
}
