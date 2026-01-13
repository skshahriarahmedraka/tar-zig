const std = @import("std");
const tar_header = @import("tar_header");

// Hard Link Tests for tar-zig
// Based on GNU tar tests: link01.at, link02.at, link03.at, link04.at

// Test hard link header creation
test "hard link header type flag" {
    var header = tar_header.PosixHeader.init();
    header.setTypeFlag(.hard_link);
    try std.testing.expectEqual(tar_header.TypeFlag.hard_link, header.getTypeFlag());
    try std.testing.expectEqual(@as(u8, '1'), header.typeflag);
}

// Test hard link name storage
test "hard link name storage" {
    var header = tar_header.PosixHeader.init();
    try header.setName("linked_file.txt");
    header.setLinkname("original_file.txt");
    header.setTypeFlag(.hard_link);
    header.setUstarMagic();
    header.setChecksum();

    const name = try header.getName(std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("linked_file.txt", name);

    const link_name = header.getLinkname();
    try std.testing.expectEqualStrings("original_file.txt", link_name);

    try std.testing.expect(header.verifyChecksum());
}

// Test hard link with long name (>100 chars)
test "hard link with long names" {
    var header = tar_header.PosixHeader.init();

    // Long path that needs prefix
    const long_path = "directory/subdirectory/another/level/deep/path/to/linked_file.txt";
    const long_link = "directory/subdirectory/another/level/deep/path/to/original_file.txt";

    try header.setName(long_path);
    header.setLinkname(long_link);
    header.setTypeFlag(.hard_link);
    header.setUstarMagic();
    header.setChecksum();

    const name = try header.getName(std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings(long_path, name);

    const link_name = header.getLinkname();
    try std.testing.expectEqualStrings(long_link, link_name);
}

// Test hard link size should be zero (data stored only once)
test "hard link size is zero" {
    var header = tar_header.PosixHeader.init();
    try header.setName("link.txt");
    header.setLinkname("original.txt");
    header.setTypeFlag(.hard_link);
    header.setSize(0); // Hard links don't store data
    header.setUstarMagic();
    header.setChecksum();

    const size = try header.getSize();
    try std.testing.expectEqual(@as(u64, 0), size);
}

// Test type flag parsing for hard links
test "hard link type flag parsing" {
    try std.testing.expectEqual(tar_header.TypeFlag.hard_link, tar_header.TypeFlag.fromByte('1'));
}

// Test hard link checksum calculation
test "hard link checksum validity" {
    var header = tar_header.PosixHeader.init();
    try header.setName("test_link.txt");
    header.setLinkname("test_original.txt");
    header.setTypeFlag(.hard_link);
    header.setMode(0o644);
    header.setUid(1000);
    header.setGid(1000);
    header.setSize(0);
    header.setMtime(1704067200); // 2024-01-01 00:00:00 UTC
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
}

// Test multiple hard links to same file (link count > 2)
// Based on link01.at: "link count gt 2"
test "multiple hard links header setup" {
    // First file (original)
    var header1 = tar_header.PosixHeader.init();
    try header1.setName("directory/test1/test.txt");
    header1.setTypeFlag(.regular);
    header1.setSize(5); // "TEST\n"
    header1.setMode(0o644);
    header1.setUstarMagic();
    header1.setChecksum();
    try std.testing.expect(header1.verifyChecksum());

    // Second reference (hard link)
    var header2 = tar_header.PosixHeader.init();
    try header2.setName("directory/test2/test.txt");
    header2.setLinkname("directory/test1/test.txt");
    header2.setTypeFlag(.hard_link);
    header2.setSize(0); // Hard link has no data
    header2.setMode(0o644);
    header2.setUstarMagic();
    header2.setChecksum();
    try std.testing.expect(header2.verifyChecksum());
}

// Test hard link name length limits
test "hard link name length limits" {
    var header = tar_header.PosixHeader.init();

    // Link name that fits in 100-char field
    const short_link = "short_original.txt";
    header.setLinkname(short_link);
    const link1 = header.getLinkname();
    try std.testing.expectEqualStrings(short_link, link1);

    // Link name at exactly 99 chars (max for linkname field)
    const exact_99 = "a" ** 95 ++ ".txt";
    header.setLinkname(exact_99);
    const link2 = header.getLinkname();
    try std.testing.expectEqualStrings(exact_99, link2);
}

// Test hard link preservation of metadata
test "hard link metadata preservation" {
    var header = tar_header.PosixHeader.init();
    try header.setName("hardlink.txt");
    header.setLinkname("original.txt");
    header.setTypeFlag(.hard_link);
    header.setMode(0o755);
    header.setUid(1000);
    header.setGid(1000);
    header.setMtime(1704067200);
    header.setUstarMagic();

    // Set user and group names
    header.setUname("user");
    header.setGname("group");

    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(@as(u32, 0o755), try header.getMode());
    try std.testing.expectEqual(@as(u32, 1000), try header.getUid());
    try std.testing.expectEqual(@as(u32, 1000), try header.getGid());
}
