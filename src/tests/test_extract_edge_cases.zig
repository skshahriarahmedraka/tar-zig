const std = @import("std");
const tar_header = @import("tar_header");

// Extract Edge Case Tests for tar-zig
// Based on GNU tar tests: extrac01.at - extrac31.at

// ============================================
// Extract Format Tests (extrac05.at - extrac06.at)
// ============================================

// Test: Symlink in read-only directory extraction (extrac06.at)
test "symlink header for read-only dir" {
    var dir_header = tar_header.PosixHeader.init();
    try dir_header.setName("dir/");
    dir_header.setTypeFlag(.directory);
    dir_header.setMode(0o555); // Read-only directory
    dir_header.setSize(0);
    dir_header.setUstarMagic();
    dir_header.setChecksum();

    var symlink_header = tar_header.PosixHeader.init();
    try symlink_header.setName("dir/foo");
    symlink_header.setLinkname("../foo");
    symlink_header.setTypeFlag(.symbolic_link);
    symlink_header.setMode(0o777);
    symlink_header.setSize(0);
    symlink_header.setUstarMagic();
    symlink_header.setChecksum();

    try std.testing.expect(dir_header.verifyChecksum());
    try std.testing.expect(symlink_header.verifyChecksum());
}

// Test: Extract specific members with wildcards (extrac04.at pattern)
test "headers for wildcard matching" {
    const test_files = [_]struct {
        name: []const u8,
        should_match_star_1: bool, // *1 pattern
    }{
        .{ .name = "file1", .should_match_star_1 = true },
        .{ .name = "file2", .should_match_star_1 = false },
        .{ .name = "directory/file1", .should_match_star_1 = true },
        .{ .name = "directory/file2", .should_match_star_1 = false },
    };

    for (test_files) |tf| {
        var header = tar_header.PosixHeader.init();
        try header.setName(tf.name);
        header.setTypeFlag(.regular);
        header.setSize(100);
        header.setUstarMagic();
        header.setChecksum();

        try std.testing.expect(header.verifyChecksum());

        // Check if name ends with "1"
        const name = try header.getName(std.testing.allocator);
        defer std.testing.allocator.free(name);
        const ends_with_1 = std.mem.endsWith(u8, name, "1");
        try std.testing.expectEqual(tf.should_match_star_1, ends_with_1);
    }
}

// ============================================
// Overwrite Tests (extrac04.at, extrac07.at)
// ============================================

// Test: File overwrite header setup
test "overwrite scenario headers" {
    // Old file header
    var old_header = tar_header.PosixHeader.init();
    try old_header.setName("file.txt");
    old_header.setTypeFlag(.regular);
    old_header.setSize(10);
    old_header.setMtime(1704067200); // Earlier time
    old_header.setMode(0o644);
    old_header.setUstarMagic();
    old_header.setChecksum();

    // New file header (same name, different content)
    var new_header = tar_header.PosixHeader.init();
    try new_header.setName("file.txt");
    new_header.setTypeFlag(.regular);
    new_header.setSize(20); // Different size
    new_header.setMtime(1704153600); // Later time
    new_header.setMode(0o644);
    new_header.setUstarMagic();
    new_header.setChecksum();

    // Both headers should be valid
    try std.testing.expect(old_header.verifyChecksum());
    try std.testing.expect(new_header.verifyChecksum());

    // Names should match
    const old_name = try old_header.getName(std.testing.allocator);
    defer std.testing.allocator.free(old_name);
    const new_name = try new_header.getName(std.testing.allocator);
    defer std.testing.allocator.free(new_name);
    try std.testing.expectEqualStrings(old_name, new_name);
}

// ============================================
// Strip Components Tests (extrac11.at pattern)
// ============================================

// Test: Path manipulation for strip-components
test "strip components path calculation" {
    const test_cases = [_]struct {
        path: []const u8,
        strip: usize,
        expected: ?[]const u8,
    }{
        .{ .path = "a/b/c/file.txt", .strip = 0, .expected = "a/b/c/file.txt" },
        .{ .path = "a/b/c/file.txt", .strip = 1, .expected = "b/c/file.txt" },
        .{ .path = "a/b/c/file.txt", .strip = 2, .expected = "c/file.txt" },
        .{ .path = "a/b/c/file.txt", .strip = 3, .expected = "file.txt" },
        .{ .path = "a/b/c/file.txt", .strip = 4, .expected = null }, // Too many strips
        .{ .path = "file.txt", .strip = 1, .expected = null },
    };

    for (test_cases) |tc| {
        const result = stripComponents(tc.path, tc.strip);
        if (tc.expected) |expected| {
            try std.testing.expect(result != null);
            try std.testing.expectEqualStrings(expected, result.?);
        } else {
            try std.testing.expect(result == null);
        }
    }
}

// Helper function to strip path components
fn stripComponents(path: []const u8, count: usize) ?[]const u8 {
    if (count == 0) return path;

    var components_stripped: usize = 0;
    var i: usize = 0;

    while (i < path.len and components_stripped < count) {
        if (path[i] == '/') {
            components_stripped += 1;
            i += 1;
            // Skip consecutive slashes
            while (i < path.len and path[i] == '/') {
                i += 1;
            }
        } else {
            i += 1;
        }
    }

    if (components_stripped < count) return null;
    if (i >= path.len) return null;

    return path[i..];
}

// ============================================
// Permission Preservation Tests
// ============================================

// Test: Various permission modes
test "permission mode preservation" {
    const modes = [_]u32{
        0o000, // No permissions
        0o644, // Regular file
        0o755, // Executable
        0o777, // Full permissions
        0o400, // Read only owner
        0o700, // Owner full
        0o444, // Read all
        0o555, // Read/exec all
        0o664, // Group write
        0o775, // Group write + exec
    };

    for (modes) |mode| {
        var header = tar_header.PosixHeader.init();
        try header.setName("test_perms.txt");
        header.setTypeFlag(.regular);
        header.setMode(mode);
        header.setSize(0);
        header.setUstarMagic();
        header.setChecksum();

        try std.testing.expect(header.verifyChecksum());
        const stored_mode = try header.getMode();
        try std.testing.expectEqual(mode, stored_mode);
    }
}

// Test: Special permission bits (setuid, setgid, sticky)
test "special permission bits" {
    // Test setuid (4755)
    {
        var header = tar_header.PosixHeader.init();
        try header.setName("special_setuid");
        header.setTypeFlag(.regular);
        header.setMode(0o4755);
        header.setSize(0);
        header.setUstarMagic();
        header.setChecksum();

        try std.testing.expect(header.verifyChecksum());
        const stored_mode = try header.getMode();
        try std.testing.expectEqual(@as(u32, 0o4755), stored_mode);
    }

    // Test setgid (2755)
    {
        var header = tar_header.PosixHeader.init();
        try header.setName("special_setgid");
        header.setTypeFlag(.regular);
        header.setMode(0o2755);
        header.setSize(0);
        header.setUstarMagic();
        header.setChecksum();

        try std.testing.expect(header.verifyChecksum());
        const stored_mode = try header.getMode();
        try std.testing.expectEqual(@as(u32, 0o2755), stored_mode);
    }

    // Test sticky (1755)
    {
        var header = tar_header.PosixHeader.init();
        try header.setName("special_sticky");
        header.setTypeFlag(.regular);
        header.setMode(0o1755);
        header.setSize(0);
        header.setUstarMagic();
        header.setChecksum();

        try std.testing.expect(header.verifyChecksum());
        const stored_mode = try header.getMode();
        try std.testing.expectEqual(@as(u32, 0o1755), stored_mode);
    }

    // Test all special bits (7755)
    {
        var header = tar_header.PosixHeader.init();
        try header.setName("special_all");
        header.setTypeFlag(.regular);
        header.setMode(0o7755);
        header.setSize(0);
        header.setUstarMagic();
        header.setChecksum();

        try std.testing.expect(header.verifyChecksum());
        const stored_mode = try header.getMode();
        try std.testing.expectEqual(@as(u32, 0o7755), stored_mode);
    }
}

// ============================================
// Timestamp Tests (time01.at, time02.at)
// ============================================

// Test: Various mtime values
test "mtime value ranges" {
    const mtimes = [_]i64{
        0, // Unix epoch
        1, // Just after epoch
        1704067200, // 2024-01-01
        2147483647, // Max 32-bit signed (2038 problem)
        4102444800, // 2100-01-01 (beyond 32-bit)
    };

    for (mtimes) |mtime| {
        var header = tar_header.PosixHeader.init();
        try header.setName("time_test.txt");
        header.setTypeFlag(.regular);
        header.setMtime(mtime);
        header.setSize(0);
        header.setUstarMagic();
        header.setChecksum();

        try std.testing.expect(header.verifyChecksum());
        const stored_mtime = try header.getMtime();
        try std.testing.expectEqual(mtime, stored_mtime);
    }
}

// ============================================
// Empty File/Directory Tests (T-empty.at)
// ============================================

// Test: Empty file header
test "empty file header" {
    var header = tar_header.PosixHeader.init();
    try header.setName("empty.txt");
    header.setTypeFlag(.regular);
    header.setSize(0);
    header.setMode(0o644);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    const size = try header.getSize();
    try std.testing.expectEqual(@as(u64, 0), size);

    // Empty file needs 0 data blocks
    const blocks = tar_header.blocksNeeded(0);
    try std.testing.expectEqual(@as(u64, 0), blocks);
}

// Test: Empty directory header
test "empty directory header" {
    var header = tar_header.PosixHeader.init();
    try header.setName("empty_dir/");
    header.setTypeFlag(.directory);
    header.setSize(0);
    header.setMode(0o755);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(tar_header.TypeFlag.directory, header.getTypeFlag());
}

// ============================================
// Character Encoding Tests
// ============================================

// Test: ASCII filenames
test "ascii filename preservation" {
    const ascii_names = [_][]const u8{
        "simple.txt",
        "file_with_underscore.txt",
        "file-with-dash.txt",
        "file.multiple.dots.txt",
        "UPPERCASE.TXT",
        "MixedCase.Txt",
        "numbers123.txt",
    };

    for (ascii_names) |name| {
        var header = tar_header.PosixHeader.init();
        try header.setName(name);
        header.setTypeFlag(.regular);
        header.setSize(0);
        header.setUstarMagic();
        header.setChecksum();

        const stored_name = try header.getName(std.testing.allocator);
        defer std.testing.allocator.free(stored_name);
        try std.testing.expectEqualStrings(name, stored_name);
    }
}

// Test: Filenames with spaces
test "filename with spaces" {
    const name = "file with spaces.txt";
    var header = tar_header.PosixHeader.init();
    try header.setName(name);
    header.setTypeFlag(.regular);
    header.setSize(0);
    header.setUstarMagic();
    header.setChecksum();

    const stored_name = try header.getName(std.testing.allocator);
    defer std.testing.allocator.free(stored_name);
    try std.testing.expectEqualStrings(name, stored_name);
}

// ============================================
// Device File Tests (for completeness)
// ============================================

// Test: Character device header
test "character device header" {
    var header = tar_header.PosixHeader.init();
    try header.setName("dev/null");
    header.setTypeFlag(.character_device);
    header.setMode(0o666);
    header.setSize(0);
    header.setDevMajor(1);
    header.setDevMinor(3);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(tar_header.TypeFlag.character_device, header.getTypeFlag());
    try std.testing.expectEqual(@as(u32, 1), try header.getDevMajor());
    try std.testing.expectEqual(@as(u32, 3), try header.getDevMinor());
}

// Test: Block device header
test "block device header" {
    var header = tar_header.PosixHeader.init();
    try header.setName("dev/sda");
    header.setTypeFlag(.block_device);
    header.setMode(0o660);
    header.setSize(0);
    header.setDevMajor(8);
    header.setDevMinor(0);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(tar_header.TypeFlag.block_device, header.getTypeFlag());
}

// Test: FIFO/Named pipe header
test "fifo header" {
    var header = tar_header.PosixHeader.init();
    try header.setName("my_fifo");
    header.setTypeFlag(.fifo);
    header.setMode(0o644);
    header.setSize(0);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(tar_header.TypeFlag.fifo, header.getTypeFlag());
}

// ============================================
// Archive Boundary Tests
// ============================================

// Test: Multiple headers in sequence (simulating archive)
test "sequential headers integrity" {
    var headers: [5]tar_header.PosixHeader = undefined;

    // Create sequence of different file types
    const entries = [_]struct {
        name: []const u8,
        typeflag: tar_header.TypeFlag,
        size: u64,
    }{
        .{ .name = "dir/", .typeflag = .directory, .size = 0 },
        .{ .name = "dir/file1.txt", .typeflag = .regular, .size = 100 },
        .{ .name = "dir/file2.txt", .typeflag = .regular, .size = 200 },
        .{ .name = "dir/link.txt", .typeflag = .symbolic_link, .size = 0 },
        .{ .name = "dir/subdir/", .typeflag = .directory, .size = 0 },
    };

    for (entries, 0..) |entry, i| {
        headers[i] = tar_header.PosixHeader.init();
        try headers[i].setName(entry.name);
        headers[i].setTypeFlag(entry.typeflag);
        headers[i].setSize(entry.size);
        headers[i].setMode(if (entry.typeflag == .directory) 0o755 else 0o644);
        headers[i].setUstarMagic();
        headers[i].setChecksum();
    }

    // All headers should be valid
    for (&headers) |*h| {
        try std.testing.expect(h.verifyChecksum());
    }
}

// Test: Archive size calculation with mixed content
test "archive size with mixed content" {
    // Simulate archive with:
    // - 1 directory (header only)
    // - 2 regular files (header + data)
    // - 1 symlink (header only)
    // - 2 EOF blocks

    const sizes = [_]u64{ 0, 1000, 512, 0 }; // dir, file1, file2, symlink
    var total_size: u64 = 0;

    for (sizes) |size| {
        total_size += 512; // Header
        total_size += tar_header.blocksNeeded(size) * 512;
    }
    total_size += 1024; // Two EOF blocks

    // Expected: 4 headers (2048) + 2 blocks for 1000 bytes (1024) + 1 block for 512 bytes (512) + EOF (1024)
    // = 2048 + 1024 + 512 + 1024 = 4608
    try std.testing.expectEqual(@as(u64, 4608), total_size);
}

// ============================================
// Prefix/Name Split Tests
// ============================================

// Test: Name exactly at boundary (100 chars)
test "name at 100 char boundary" {
    // Exactly 100 characters
    const name_100 = "a" ** 96 ++ ".txt";
    try std.testing.expectEqual(@as(usize, 100), name_100.len);

    var header = tar_header.PosixHeader.init();
    try header.setName(name_100);
    header.setTypeFlag(.regular);
    header.setUstarMagic();
    header.setChecksum();

    const stored_name = try header.getName(std.testing.allocator);
    defer std.testing.allocator.free(stored_name);
    try std.testing.expectEqualStrings(name_100, stored_name);
}

// Test: Name requiring prefix split
test "name with prefix split" {
    // Path that requires prefix: 60 char prefix + / + 50 char name = 111 chars
    const prefix = "very/long/directory/path/that/needs/prefix/storage";
    const filename = "a" ** 46 ++ ".txt";
    const full_path = prefix ++ "/" ++ filename;

    try std.testing.expect(full_path.len > 100);
    try std.testing.expect(full_path.len <= 256);

    var header = tar_header.PosixHeader.init();
    try header.setName(full_path);
    header.setTypeFlag(.regular);
    header.setUstarMagic();
    header.setChecksum();

    const stored_name = try header.getName(std.testing.allocator);
    defer std.testing.allocator.free(stored_name);
    try std.testing.expectEqualStrings(full_path, stored_name);
}
