const std = @import("std");
const tar_header = @import("tar_header");

// Special Files Tests for tar-zig
// Tests for device files (character/block), FIFOs, and other special file types

// Test character device header
test "character device type flag" {
    var header = tar_header.PosixHeader.init();
    header.setTypeFlag(.character_device);
    try std.testing.expectEqual(tar_header.TypeFlag.character_device, header.getTypeFlag());
    try std.testing.expectEqual(@as(u8, '3'), header.typeflag);
}

// Test block device header
test "block device type flag" {
    var header = tar_header.PosixHeader.init();
    header.setTypeFlag(.block_device);
    try std.testing.expectEqual(tar_header.TypeFlag.block_device, header.getTypeFlag());
    try std.testing.expectEqual(@as(u8, '4'), header.typeflag);
}

// Test FIFO (named pipe) header
test "fifo type flag" {
    var header = tar_header.PosixHeader.init();
    header.setTypeFlag(.fifo);
    try std.testing.expectEqual(tar_header.TypeFlag.fifo, header.getTypeFlag());
    try std.testing.expectEqual(@as(u8, '6'), header.typeflag);
}

// Test character device with major/minor numbers
test "character device major minor numbers" {
    var header = tar_header.PosixHeader.init();
    try header.setName("dev/null");
    header.setTypeFlag(.character_device);
    header.setMode(0o666);
    header.setSize(0); // Device files have no data
    header.setDevMajor(1); // /dev/null major number
    header.setDevMinor(3); // /dev/null minor number
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(@as(u32, 1), try header.getDevMajor());
    try std.testing.expectEqual(@as(u32, 3), try header.getDevMinor());
}

// Test block device with major/minor numbers
test "block device major minor numbers" {
    var header = tar_header.PosixHeader.init();
    try header.setName("dev/sda");
    header.setTypeFlag(.block_device);
    header.setMode(0o660);
    header.setSize(0);
    header.setDevMajor(8); // SCSI disk major
    header.setDevMinor(0); // First SCSI disk
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(@as(u32, 8), try header.getDevMajor());
    try std.testing.expectEqual(@as(u32, 0), try header.getDevMinor());
}

// Test FIFO creation
test "fifo header creation" {
    var header = tar_header.PosixHeader.init();
    try header.setName("tmp/myfifo");
    header.setTypeFlag(.fifo);
    header.setMode(0o644);
    header.setSize(0); // FIFOs have no data in archive
    header.setUid(1000);
    header.setGid(1000);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(tar_header.TypeFlag.fifo, header.getTypeFlag());
}

// Test all special file type flags parsing
test "special file type flag parsing" {
    // Character device
    try std.testing.expectEqual(tar_header.TypeFlag.character_device, tar_header.TypeFlag.fromByte('3'));
    // Block device
    try std.testing.expectEqual(tar_header.TypeFlag.block_device, tar_header.TypeFlag.fromByte('4'));
    // FIFO
    try std.testing.expectEqual(tar_header.TypeFlag.fifo, tar_header.TypeFlag.fromByte('6'));
}

// Test symbolic link header
test "symbolic link header" {
    var header = tar_header.PosixHeader.init();
    try header.setName("link_to_file");
    header.setLinkname("target_file.txt");
    header.setTypeFlag(.symbolic_link);
    header.setMode(0o777); // Symlinks typically have 777
    header.setSize(0); // Symlinks don't store data
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(tar_header.TypeFlag.symbolic_link, header.getTypeFlag());

    const link_name = header.getLinkname();
    try std.testing.expectEqualStrings("target_file.txt", link_name);
}

// Test symbolic link type flag
test "symbolic link type flag" {
    try std.testing.expectEqual(tar_header.TypeFlag.symbolic_link, tar_header.TypeFlag.fromByte('2'));
    try std.testing.expectEqual(@as(u8, '2'), tar_header.TypeFlag.symbolic_link.toByte());
}

// Test directory type flag
test "directory type flag" {
    var header = tar_header.PosixHeader.init();
    try header.setName("mydir/");
    header.setTypeFlag(.directory);
    header.setMode(0o755);
    header.setSize(0);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(tar_header.TypeFlag.directory, header.getTypeFlag());
    try std.testing.expectEqual(@as(u8, '5'), header.typeflag);
}

// Test regular file type as contiguous placeholder
test "type flag byte 7 parsing" {
    // Type '7' is contiguous file - check it parses correctly
    const flag = tar_header.TypeFlag.fromByte('7');
    try std.testing.expectEqual(@as(u8, '7'), flag.toByte());
}

// Test GNU long name type flag
test "gnu long name type flag" {
    try std.testing.expectEqual(tar_header.TypeFlag.gnu_long_name, tar_header.TypeFlag.fromByte('L'));
}

// Test GNU long link type flag
test "gnu long link type flag" {
    try std.testing.expectEqual(tar_header.TypeFlag.gnu_long_link, tar_header.TypeFlag.fromByte('K'));
}

// Test PAX extended header type flags
test "pax header type flags" {
    try std.testing.expectEqual(tar_header.TypeFlag.pax_extended, tar_header.TypeFlag.fromByte('x'));
    try std.testing.expectEqual(tar_header.TypeFlag.pax_global, tar_header.TypeFlag.fromByte('g'));
}

// Test device major/minor number encoding
test "device number octal encoding" {
    var header = tar_header.PosixHeader.init();

    // Test various major/minor combinations
    const test_cases = [_]struct { major: u32, minor: u32 }{
        .{ .major = 0, .minor = 0 },
        .{ .major = 1, .minor = 3 }, // /dev/null
        .{ .major = 1, .minor = 5 }, // /dev/zero
        .{ .major = 8, .minor = 0 }, // /dev/sda
        .{ .major = 8, .minor = 1 }, // /dev/sda1
        .{ .major = 136, .minor = 0 }, // pts/0
        .{ .major = 255, .minor = 255 }, // max common values
    };

    for (test_cases) |tc| {
        header.setDevMajor(tc.major);
        header.setDevMinor(tc.minor);

        const major = try header.getDevMajor();
        const minor = try header.getDevMinor();

        try std.testing.expectEqual(tc.major, major);
        try std.testing.expectEqual(tc.minor, minor);
    }
}

// Test special file size is always zero
test "special files have zero size" {
    var header = tar_header.PosixHeader.init();

    // Character device
    header.setTypeFlag(.character_device);
    header.setSize(0);
    try std.testing.expectEqual(@as(u64, 0), try header.getSize());

    // Block device
    header.setTypeFlag(.block_device);
    header.setSize(0);
    try std.testing.expectEqual(@as(u64, 0), try header.getSize());

    // FIFO
    header.setTypeFlag(.fifo);
    header.setSize(0);
    try std.testing.expectEqual(@as(u64, 0), try header.getSize());

    // Symbolic link
    header.setTypeFlag(.symbolic_link);
    header.setSize(0);
    try std.testing.expectEqual(@as(u64, 0), try header.getSize());

    // Directory
    header.setTypeFlag(.directory);
    header.setSize(0);
    try std.testing.expectEqual(@as(u64, 0), try header.getSize());
}

// Test special file permissions
test "special file permissions" {
    var header = tar_header.PosixHeader.init();

    // /dev/null style permissions (rw-rw-rw-)
    header.setMode(0o666);
    try std.testing.expectEqual(@as(u32, 0o666), try header.getMode());

    // /dev/sda style permissions (rw-rw----)
    header.setMode(0o660);
    try std.testing.expectEqual(@as(u32, 0o660), try header.getMode());

    // FIFO permissions
    header.setMode(0o644);
    try std.testing.expectEqual(@as(u32, 0o644), try header.getMode());

    // Directory permissions with execute
    header.setMode(0o755);
    try std.testing.expectEqual(@as(u32, 0o755), try header.getMode());

    // Setuid/setgid bits
    header.setMode(0o4755);
    try std.testing.expectEqual(@as(u32, 0o4755), try header.getMode());
}

// Test unknown type flag handling
test "unknown type flag" {
    // Unknown type flags should be handled gracefully (falls back to regular_alt)
    const unknown = tar_header.TypeFlag.fromByte('?');
    try std.testing.expectEqual(tar_header.TypeFlag.regular_alt, unknown);
}
