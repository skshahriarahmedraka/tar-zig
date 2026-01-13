const std = @import("std");
const tar_header = @import("tar_header");

// Checksum Tests for tar-zig
// Comprehensive tests for tar header checksum calculation and verification

// Test checksum on empty header
test "checksum empty header" {
    var header = tar_header.PosixHeader.init();
    header.setChecksum();
    try std.testing.expect(header.verifyChecksum());
}

// Test checksum after setting name
test "checksum with name" {
    var header = tar_header.PosixHeader.init();
    try header.setName("test.txt");
    header.setChecksum();
    try std.testing.expect(header.verifyChecksum());
}

// Test checksum after full header setup
test "checksum full header" {
    var header = tar_header.PosixHeader.init();
    try header.setName("path/to/file.txt");
    header.setTypeFlag(.regular);
    header.setMode(0o644);
    header.setUid(1000);
    header.setGid(1000);
    header.setSize(12345);
    header.setMtime(1704067200);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
}

// Test checksum with maximum values
test "checksum max values" {
    var header = tar_header.PosixHeader.init();
    try header.setName("maxtest.dat");
    header.setMode(0o7777);
    header.setUid(2097151); // Max 7 octal digits
    header.setGid(2097151);
    header.setSize(tar_header.MAX_OCTAL_VALUE);
    header.setMtime(8589934591); // Max 11 octal digits
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
}

// Test checksum modification detection
test "checksum detects modification" {
    var header = tar_header.PosixHeader.init();
    try header.setName("detect.txt");
    header.setMode(0o644);
    header.setUstarMagic();
    header.setChecksum();

    // Verify original checksum is valid
    try std.testing.expect(header.verifyChecksum());

    // Modify a field without updating checksum
    header.mode[0] = '7';

    // Checksum should now fail
    try std.testing.expect(!header.verifyChecksum());
}

// Test checksum with link name
test "checksum with linkname" {
    var header = tar_header.PosixHeader.init();
    try header.setName("link.txt");
    header.setLinkname("target.txt");
    header.setTypeFlag(.symbolic_link);
    header.setMode(0o777);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
}

// Test checksum with prefix
test "checksum with prefix path" {
    var header = tar_header.PosixHeader.init();
    // Long path that uses prefix
    try header.setName("this/is/a/long/path/that/requires/the/prefix/field/to/store/the/directory/portion/file.txt");
    header.setTypeFlag(.regular);
    header.setMode(0o644);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
}

// Test checksum with uname/gname
test "checksum with owner names" {
    var header = tar_header.PosixHeader.init();
    try header.setName("owned.txt");
    header.setTypeFlag(.regular);
    header.setMode(0o644);
    header.setUid(1000);
    header.setGid(1000);
    header.setUname("testuser");
    header.setGname("testgroup");
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
}

// Test checksum for directory
test "checksum directory entry" {
    var header = tar_header.PosixHeader.init();
    try header.setName("testdir/");
    header.setTypeFlag(.directory);
    header.setMode(0o755);
    header.setSize(0);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
}

// Test checksum with device numbers
test "checksum with device numbers" {
    var header = tar_header.PosixHeader.init();
    try header.setName("dev/null");
    header.setTypeFlag(.character_device);
    header.setMode(0o666);
    header.setDevMajor(1);
    header.setDevMinor(3);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
}

// Test checksum field format
test "checksum field format" {
    var header = tar_header.PosixHeader.init();
    try header.setName("format.txt");
    header.setMode(0o644);
    header.setUstarMagic();
    header.setChecksum();

    // Checksum should end with null and space
    // Format: 6 octal digits + null + space (or space + null)
    const chksum = header.chksum;
    var has_null = false;
    for (chksum) |c| {
        if (c == 0) has_null = true;
    }
    try std.testing.expect(has_null);
}

// Test multiple checksum recalculations
test "checksum recalculation" {
    var header = tar_header.PosixHeader.init();
    try header.setName("recalc.txt");
    header.setMode(0o644);
    header.setUstarMagic();

    // Calculate checksum multiple times
    header.setChecksum();
    const chk1 = header.chksum;

    header.setChecksum();
    const chk2 = header.chksum;

    // Should produce same result
    try std.testing.expectEqualSlices(u8, &chk1, &chk2);
}

// Test checksum with all type flags
test "checksum various type flags" {
    const type_flags = [_]tar_header.TypeFlag{
        .regular,
        .hard_link,
        .symbolic_link,
        .character_device,
        .block_device,
        .directory,
        .fifo,
    };

    for (type_flags) |tf| {
        var header = tar_header.PosixHeader.init();
        try header.setName("typeflag_test");
        header.setTypeFlag(tf);
        header.setMode(0o644);
        header.setUstarMagic();
        header.setChecksum();

        try std.testing.expect(header.verifyChecksum());
    }
}
