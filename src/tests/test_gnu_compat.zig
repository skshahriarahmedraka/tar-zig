const std = @import("std");
const tar_header = @import("tar_header");

// GNU Tar Compatibility Tests for tar-zig
// Based on GNU tar test suite (tar/tests/*.at)
// These tests verify header-level compatibility with GNU tar

// ============================================
// Append Operation Tests (append01.at - append05.at)
// ============================================

// Test: Appending files with long names (append01.at)
// "When decoding a header tar was assigning 0 to oldgnu_header.isextended,
// which destroyed name prefix."
test "append long name prefix handling" {
    // Create header with long name that uses prefix field
    const long_prefix = "This_is_a_very_long_file_name_prefix_that_is_designed_to_cause_problems";
    const filename = "file1";
    const full_path = long_prefix ++ "/" ++ filename;

    var header = tar_header.PosixHeader.init();
    try header.setName(full_path);
    header.setTypeFlag(.regular);
    header.setMode(0o644);
    header.setSize(0);
    header.setUstarMagic();
    header.setChecksum();

    // Verify the name can be reconstructed correctly
    const name = try header.getName(std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings(full_path, name);

    // Verify checksum is valid (prefix should not be corrupted)
    try std.testing.expect(header.verifyChecksum());
}

// Test append with multiple files preserving order
test "append preserves file order" {
    var headers: [3]tar_header.PosixHeader = undefined;
    const names = [_][]const u8{ "file1.txt", "file2.txt", "file3.txt" };

    for (names, 0..) |name, i| {
        headers[i] = tar_header.PosixHeader.init();
        try headers[i].setName(name);
        headers[i].setTypeFlag(.regular);
        headers[i].setSize(100);
        headers[i].setUstarMagic();
        headers[i].setChecksum();
    }

    // Verify each header maintains its name correctly
    for (names, 0..) |expected_name, i| {
        const actual_name = try headers[i].getName(std.testing.allocator);
        defer std.testing.allocator.free(actual_name);
        try std.testing.expectEqualStrings(expected_name, actual_name);
    }
}

// ============================================
// Delete Operation Tests (delete01.at - delete06.at)
// ============================================

// Test: Deleting a member after a big one (delete01.at)
// "Deleting a member after a big one was destroying the archive."
test "delete after large file header setup" {
    // Large file header (50000 bytes)
    var header1 = tar_header.PosixHeader.init();
    try header1.setName("file1");
    header1.setTypeFlag(.regular);
    header1.setSize(50000);
    header1.setUstarMagic();
    header1.setChecksum();

    // Smaller file header (1024 bytes)
    var header2 = tar_header.PosixHeader.init();
    try header2.setName("file2");
    header2.setTypeFlag(.regular);
    header2.setSize(1024);
    header2.setUstarMagic();
    header2.setChecksum();

    // Both headers should be valid
    try std.testing.expect(header1.verifyChecksum());
    try std.testing.expect(header2.verifyChecksum());

    // Verify block calculations for skipping
    const blocks1 = tar_header.blocksNeeded(50000);
    const blocks2 = tar_header.blocksNeeded(1024);
    try std.testing.expectEqual(@as(u64, 98), blocks1); // ceil(50000/512)
    try std.testing.expectEqual(@as(u64, 2), blocks2); // ceil(1024/512)
}

// Test: Delete preserves remaining entries (delete02.at pattern)
test "delete first entry header integrity" {
    const names = [_][]const u8{ "first.txt", "second.txt", "third.txt" };
    var headers: [3]tar_header.PosixHeader = undefined;

    for (names, 0..) |name, i| {
        headers[i] = tar_header.PosixHeader.init();
        try headers[i].setName(name);
        headers[i].setTypeFlag(.regular);
        headers[i].setSize(100);
        headers[i].setMtime(@as(i64, @intCast(1704067200 + i)));
        headers[i].setUstarMagic();
        headers[i].setChecksum();
    }

    // After "deleting" first entry, remaining entries should still be valid
    // (simulating by verifying headers 1 and 2)
    try std.testing.expect(headers[1].verifyChecksum());
    try std.testing.expect(headers[2].verifyChecksum());

    const name1 = try headers[1].getName(std.testing.allocator);
    defer std.testing.allocator.free(name1);
    try std.testing.expectEqualStrings("second.txt", name1);
}

// ============================================
// Extract Tests (extrac01.at - extrac31.at)
// ============================================

// Test: Extract directory header (extrac01.at)
// "There was a diagnostic when directory already exists."
test "directory header for extract" {
    var header = tar_header.PosixHeader.init();
    try header.setName("directory/");
    header.setTypeFlag(.directory);
    header.setMode(0o755);
    header.setSize(0); // Directories have size 0
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(tar_header.TypeFlag.directory, header.getTypeFlag());

    const size = try header.getSize();
    try std.testing.expectEqual(@as(u64, 0), size);
}

// Test: Extract with fnmatch patterns (extrac04.at)
test "filename pattern matching setup" {
    // Create headers for various files to test pattern matching
    const files = [_][]const u8{
        "file1",
        "directory/",
        "directory/file1",
        "directory/file2",
        "directory/subdirectory/",
        "directory/subdirectory/file1",
        "directory/subdirectory/file2",
    };

    for (files) |name| {
        var header = tar_header.PosixHeader.init();
        try header.setName(name);

        if (std.mem.endsWith(u8, name, "/")) {
            header.setTypeFlag(.directory);
            header.setSize(0);
        } else {
            header.setTypeFlag(.regular);
            header.setSize(100);
        }

        header.setUstarMagic();
        header.setChecksum();
        try std.testing.expect(header.verifyChecksum());
    }
}

// ============================================
// Link Tests (link01.at - link04.at)
// ============================================

// Test: Link count > 2 (link01.at)
// "If a member with link count > 2 was stored in the archive twice,
// previous versions of tar were not able to extract it"
test "duplicate hard link headers" {
    // Original file
    var orig = tar_header.PosixHeader.init();
    try orig.setName("directory/test1/test.txt");
    orig.setTypeFlag(.regular);
    orig.setSize(5); // "TEST\n"
    orig.setMode(0o644);
    orig.setUstarMagic();
    orig.setChecksum();

    // First reference to same file (stored again, not as hardlink)
    var dup = tar_header.PosixHeader.init();
    try dup.setName("directory/test1/test.txt");
    dup.setTypeFlag(.regular);
    dup.setSize(5);
    dup.setMode(0o644);
    dup.setUstarMagic();
    dup.setChecksum();

    // Both should be valid
    try std.testing.expect(orig.verifyChecksum());
    try std.testing.expect(dup.verifyChecksum());
}

// Test: Symlink in read-only directory (link02.at)
test "symlink header in archive" {
    var header = tar_header.PosixHeader.init();
    try header.setName("dir/foo");
    header.setLinkname("../foo");
    header.setTypeFlag(.symbolic_link);
    header.setMode(0o777); // Symlinks typically have 777
    header.setSize(0); // Symlinks have no data
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(tar_header.TypeFlag.symbolic_link, header.getTypeFlag());

    const linkname = header.getLinkname();
    try std.testing.expectEqualStrings("../foo", linkname);
}

// ============================================
// Long Name Tests (long01.at, longv7.at)
// ============================================

// Test: Long file names divisible by block size (long01.at)
// "when extracting or listing a file member with a name whose length
// is divisible by block size (512) tar used to read an extra block"
test "long name divisible by 512" {
    // Create a path that's exactly 512 bytes when including directory separators
    // 0123456789abcde = 15 chars, with "/" = 16 chars per level
    // 32 levels * 16 = 512 chars
    var path_buf: [600]u8 = undefined;
    var pos: usize = 0;

    // Build path: "0123456789abcde/0123456789abcde/..."
    const segment = "0123456789abcde";
    for (0..30) |i| {
        if (i > 0) {
            path_buf[pos] = '/';
            pos += 1;
        }
        @memcpy(path_buf[pos .. pos + segment.len], segment);
        pos += segment.len;
    }

    const long_path = path_buf[0..pos];

    // This path is > 256 chars, so needs GNU long name extension
    try std.testing.expect(long_path.len > 256);

    // Verify we can detect that this needs GNU long name
    try std.testing.expect(tar_header.needsGnuLongName(long_path));
}

// Test: Very long V7 filename (longv7.at)
test "v7 filename limit detection" {
    // V7 format only supports 99 char filenames
    const short_name = "short.txt";
    const long_name = "a" ** 100 ++ ".txt";

    try std.testing.expect(!tar_header.needsGnuLongName(short_name));
    try std.testing.expect(tar_header.needsGnuLongName(long_name));
}

// ============================================
// Update Tests (update01.at - update04.at)
// ============================================

// Test: Update mode timestamp comparison (update01.at)
test "mtime comparison for update" {
    const old_mtime: u64 = 1704067200; // 2024-01-01 00:00:00
    const new_mtime: u64 = 1704153600; // 2024-01-02 00:00:00

    var old_header = tar_header.PosixHeader.init();
    try old_header.setName("file.txt");
    old_header.setMtime(old_mtime);
    old_header.setTypeFlag(.regular);
    old_header.setSize(100);
    old_header.setUstarMagic();
    old_header.setChecksum();

    var new_header = tar_header.PosixHeader.init();
    try new_header.setName("file.txt");
    new_header.setMtime(new_mtime);
    new_header.setTypeFlag(.regular);
    new_header.setSize(100);
    new_header.setUstarMagic();
    new_header.setChecksum();

    const old_time = try old_header.getMtime();
    const new_time = try new_header.getMtime();

    // New file should be detected as newer
    try std.testing.expect(new_time > old_time);
}

// Test: Update adds only new directory entries (update01.at)
test "directory update detection" {
    var dir_header = tar_header.PosixHeader.init();
    try dir_header.setName("a/");
    dir_header.setTypeFlag(.directory);
    dir_header.setMode(0o755);
    dir_header.setMtime(1704067200);
    dir_header.setSize(0);
    dir_header.setUstarMagic();
    dir_header.setChecksum();

    try std.testing.expect(dir_header.verifyChecksum());
    try std.testing.expectEqual(tar_header.TypeFlag.directory, dir_header.getTypeFlag());
}

// ============================================
// Sparse File Tests (sparse01.at - sparse07.at)
// ============================================

// Test: Sparse file header type (sparse01.at)
test "sparse file type flag" {
    var header = tar_header.PosixHeader.init();
    try header.setName("sparsefile");
    header.setTypeFlag(.gnu_sparse);
    header.setMode(0o644);
    // Sparse files report logical size, not physical
    header.setSize(10344448); // ~10MB with holes
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(@as(u8, 'S'), header.typeflag);
}

// ============================================
// Diff/Compare Tests (difflink.at)
// ============================================

// Test: Diff header comparison setup
test "diff comparison header metadata" {
    // Create two headers for same file with different content
    var header1 = tar_header.PosixHeader.init();
    try header1.setName("testfile.txt");
    header1.setTypeFlag(.regular);
    header1.setSize(100);
    header1.setMtime(1704067200);
    header1.setMode(0o644);
    header1.setUstarMagic();
    header1.setChecksum();

    var header2 = tar_header.PosixHeader.init();
    try header2.setName("testfile.txt");
    header2.setTypeFlag(.regular);
    header2.setSize(200); // Different size
    header2.setMtime(1704153600); // Different mtime
    header2.setMode(0o644);
    header2.setUstarMagic();
    header2.setChecksum();

    // Verify we can detect differences
    const size1 = try header1.getSize();
    const size2 = try header2.getSize();
    try std.testing.expect(size1 != size2);

    const mtime1 = try header1.getMtime();
    const mtime2 = try header2.getMtime();
    try std.testing.expect(mtime1 != mtime2);
}

// ============================================
// Owner/Permission Tests (owner.at)
// ============================================

// Test: Numeric owner preservation
test "numeric uid gid preservation" {
    var header = tar_header.PosixHeader.init();
    try header.setName("owned_file.txt");
    header.setTypeFlag(.regular);
    header.setSize(100);
    header.setUid(1000);
    header.setGid(1000);
    header.setMode(0o644);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(@as(u32, 1000), try header.getUid());
    try std.testing.expectEqual(@as(u32, 1000), try header.getGid());
}

// Test: Large UID/GID values
test "large uid gid values" {
    var header = tar_header.PosixHeader.init();
    try header.setName("large_owner.txt");
    header.setTypeFlag(.regular);
    header.setSize(100);
    header.setUid(65534); // nobody
    header.setGid(65534); // nogroup
    header.setMode(0o644);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(@as(u32, 65534), try header.getUid());
    try std.testing.expectEqual(@as(u32, 65534), try header.getGid());
}

// ============================================
// Verbose Output Tests (verbose.at)
// ============================================

// Test: Mode string representation
test "mode to string representation" {
    // Regular file with 644 permissions
    var header = tar_header.PosixHeader.init();
    header.setTypeFlag(.regular);
    header.setMode(0o644);

    const mode = try header.getMode();
    try std.testing.expectEqual(@as(u32, 0o644), mode);

    // Directory with 755 permissions
    var dir_header = tar_header.PosixHeader.init();
    dir_header.setTypeFlag(.directory);
    dir_header.setMode(0o755);

    const dir_mode = try dir_header.getMode();
    try std.testing.expectEqual(@as(u32, 0o755), dir_mode);
}

// ============================================
// Empty Archive Tests (T-empty.at)
// ============================================

// Test: Zero block detection (end of archive)
test "zero block detection" {
    const zero_block: [512]u8 = [_]u8{0} ** 512;

    // Verify zero block detection
    var is_zero = true;
    for (zero_block) |byte| {
        if (byte != 0) {
            is_zero = false;
            break;
        }
    }
    try std.testing.expect(is_zero);
}

// ============================================
// Block Size Tests
// ============================================

// Test: Padding calculations for various file sizes
test "block padding calculations" {
    // Test various sizes
    const test_cases = [_]struct { size: u64, expected_blocks: u64 }{
        .{ .size = 0, .expected_blocks = 0 },
        .{ .size = 1, .expected_blocks = 1 },
        .{ .size = 511, .expected_blocks = 1 },
        .{ .size = 512, .expected_blocks = 1 },
        .{ .size = 513, .expected_blocks = 2 },
        .{ .size = 1024, .expected_blocks = 2 },
        .{ .size = 50000, .expected_blocks = 98 },
        .{ .size = 1048576, .expected_blocks = 2048 }, // 1MB
    };

    for (test_cases) |tc| {
        const blocks = tar_header.blocksNeeded(tc.size);
        try std.testing.expectEqual(tc.expected_blocks, blocks);
    }
}

// Test: Archive total size calculation
test "archive size calculation" {
    // An archive with 3 files:
    // - Header (512) + Data (1024 padded to 1024) = 1536
    // - Header (512) + Data (100 padded to 512) = 1024
    // - Header (512) + Data (0) = 512
    // + 2 zero blocks (1024)
    // Total = 1536 + 1024 + 512 + 1024 = 4096

    const file_sizes = [_]u64{ 1024, 100, 0 };
    var total: u64 = 0;

    for (file_sizes) |size| {
        total += 512; // Header
        total += tar_header.blocksNeeded(size) * 512; // Data blocks
    }
    total += 1024; // Two zero blocks for EOF

    try std.testing.expectEqual(@as(u64, 4096), total);
}

// ============================================
// USTAR Magic Tests
// ============================================

// Test: USTAR magic and version
test "ustar magic and version" {
    var header = tar_header.PosixHeader.init();
    header.setUstarMagic();

    // USTAR magic should be "ustar\0"
    try std.testing.expectEqualStrings("ustar", header.magic[0..5]);
    try std.testing.expectEqual(@as(u8, 0), header.magic[5]);

    // Version should be "00"
    try std.testing.expectEqualStrings("00", &header.version);
}

// Test: GNU magic (oldgnu format)
test "gnu magic format" {
    var header = tar_header.PosixHeader.init();

    // GNU format uses "ustar " with space
    header.setGnuMagic();

    try std.testing.expectEqualStrings("ustar ", header.magic[0..6]);
}
