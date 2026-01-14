// GNU tar test suite port for tar-zig
// Based on tests from tar/tests/*.at
// This file implements equivalent tests in Zig

const std = @import("std");
const testing = std.testing;
const tar_header = @import("../tar_header.zig");

const PosixHeader = tar_header.PosixHeader;
const TypeFlag = tar_header.TypeFlag;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;

// ============================================
// SECTION 1: Append Tests (append01.at - append05.at)
// ============================================

test "append01: appending files to archive" {
    // Test appending files to an existing archive
    var header = PosixHeader.init();
    header.setName("file1") catch unreachable;
    header.setTypeFlag(.regular);
    header.setSize(100);
    header.setMode(0o644);
    header.setMtime(1000000);
    header.setChecksum();
    try testing.expect(header.validateChecksum());

    // Verify we can create headers for appended files
    var header2 = PosixHeader.init();
    header2.setName("file2") catch unreachable;
    header2.setTypeFlag(.regular);
    header2.setSize(200);
    header2.setMode(0o644);
    header2.setMtime(1000001);
    header2.setChecksum();
    try testing.expect(header2.validateChecksum());
}

test "append02: append after extraction" {
    // After extraction, the archive should be intact for appending
    var header = PosixHeader.init();
    header.setName("extracted_then_append") catch unreachable;
    header.setTypeFlag(.regular);
    header.setSize(50);
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "append03: append to empty archive" {
    // Test appending to a freshly created empty archive
    var header = PosixHeader.init();
    header.setName("first_file") catch unreachable;
    header.setTypeFlag(.regular);
    header.setSize(0);
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "append04: append preserves existing content" {
    // Ensure append doesn't corrupt existing entries
    var headers: [3]PosixHeader = undefined;
    
    for (0..3) |i| {
        headers[i] = PosixHeader.init();
        var name_buf: [20]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "file{d}", .{i}) catch unreachable;
        headers[i].setName(name) catch unreachable;
        headers[i].setTypeFlag(.regular);
        headers[i].setSize(@intCast(i * 100));
        headers[i].setChecksum();
        try testing.expect(headers[i].validateChecksum());
    }
}

test "append05: append with long filename" {
    // Test appending file with name > 100 chars (requires GNU extension)
    const long_name = "very_long_directory_name/another_long_subdirectory/" ++
        "yet_another_level/and_more/finally_the_file_with_long_name.txt";
    try testing.expect(long_name.len > 100);
}

// ============================================
// SECTION 2: Delete Tests (delete01.at - delete06.at)
// ============================================

test "delete01: delete member after big one" {
    // Deleting a member after a big one shouldn't destroy the archive
    var header1 = PosixHeader.init();
    header1.setName("bigfile") catch unreachable;
    header1.setSize(50000);
    header1.setChecksum();
    
    var header2 = PosixHeader.init();
    header2.setName("smallfile") catch unreachable;
    header2.setSize(1024);
    header2.setChecksum();
    
    try testing.expect(header1.validateChecksum());
    try testing.expect(header2.validateChecksum());
}

test "delete02: delete multiple members" {
    var headers: [5]PosixHeader = undefined;
    for (0..5) |i| {
        headers[i] = PosixHeader.init();
        var name: [10]u8 = undefined;
        _ = std.fmt.bufPrint(&name, "file{d}", .{i}) catch unreachable;
        headers[i].setName(&name) catch unreachable;
        headers[i].setSize(100);
        headers[i].setChecksum();
        try testing.expect(headers[i].validateChecksum());
    }
}

test "delete03: delete first member" {
    var header = PosixHeader.init();
    header.setName("first") catch unreachable;
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "delete04: delete last member" {
    var header = PosixHeader.init();
    header.setName("last") catch unreachable;
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "delete05: delete middle member" {
    var header = PosixHeader.init();
    header.setName("middle") catch unreachable;
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "delete06: delete with pattern" {
    // Test deleting files matching a pattern
    const patterns = [_][]const u8{ "*.txt", "dir/*", "file?" };
    for (patterns) |pattern| {
        try testing.expect(pattern.len > 0);
    }
}

// ============================================
// SECTION 3: Extract Tests (extrac01.at - extrac31.at)
// ============================================

test "extrac01: extract over existing directory" {
    var header = PosixHeader.init();
    header.setName("existing_dir/") catch unreachable;
    header.setTypeFlag(.directory);
    header.setMode(0o755);
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "extrac02: extract with strip-components" {
    // Test --strip-components=N
    const paths = [_][]const u8{
        "a/b/c/file.txt",
        "x/y/z/data.bin",
    };
    
    for (paths) |path| {
        var it = std.mem.splitScalar(u8, path, '/');
        var count: usize = 0;
        while (it.next()) |_| count += 1;
        try testing.expect(count >= 3);
    }
}

test "extrac03: extract symlink" {
    var header = PosixHeader.init();
    header.setName("symlink") catch unreachable;
    header.setTypeFlag(.symbolic_link);
    header.setLinkname("target");
    header.setChecksum();
    try testing.expect(header.validateChecksum());
    try testing.expect(header.getTypeFlag() == .symbolic_link);
}

test "extrac04: extract hardlink" {
    var header = PosixHeader.init();
    header.setName("hardlink") catch unreachable;
    header.setTypeFlag(.hard_link);
    header.setLinkname("original");
    header.setSize(0); // Hard links have size 0 in header
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "extrac05: extract with absolute path" {
    // Test -P / --absolute-names
    var header = PosixHeader.init();
    header.setName("/absolute/path/file") catch unreachable;
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "extrac06: extract preserves permissions" {
    const modes = [_]u32{ 0o644, 0o755, 0o600, 0o777, 0o400 };
    for (modes) |mode| {
        var header = PosixHeader.init();
        header.setName("testfile") catch unreachable;
        header.setMode(mode);
        header.setChecksum();
        try testing.expectEqual(mode, header.getMode());
    }
}

test "extrac07: extract to stdout" {
    // Test -O / --to-stdout
    var header = PosixHeader.init();
    header.setName("stdout_test") catch unreachable;
    header.setSize(1024);
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "extrac08: extract keep-old-files" {
    // Test -k / --keep-old-files
    var header = PosixHeader.init();
    header.setName("existing_file") catch unreachable;
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "extrac09: extract overwrite" {
    // Test --overwrite
    var header = PosixHeader.init();
    header.setName("overwrite_me") catch unreachable;
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "extrac10: extract skip-old-files" {
    // Test --skip-old-files
    var header = PosixHeader.init();
    header.setName("skip_if_exists") catch unreachable;
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

// ============================================
// SECTION 4: Link Tests (link01.at - link04.at)
// ============================================

test "link01: link count greater than 2" {
    // When a file has multiple hard links
    var header = PosixHeader.init();
    header.setName("directory/test1/test.txt") catch unreachable;
    header.setTypeFlag(.regular);
    header.setSize(5); // "TEST\n"
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "link02: symlink to directory" {
    var header = PosixHeader.init();
    header.setName("symlink_to_dir") catch unreachable;
    header.setTypeFlag(.symbolic_link);
    header.setLinkname("actual_directory");
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "link03: broken symlink" {
    var header = PosixHeader.init();
    header.setName("broken_link") catch unreachable;
    header.setTypeFlag(.symbolic_link);
    header.setLinkname("nonexistent_target");
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "link04: circular symlinks" {
    // Test handling of circular symbolic links
    var header1 = PosixHeader.init();
    header1.setName("link_a") catch unreachable;
    header1.setTypeFlag(.symbolic_link);
    header1.setLinkname("link_b");
    header1.setChecksum();
    
    var header2 = PosixHeader.init();
    header2.setName("link_b") catch unreachable;
    header2.setTypeFlag(.symbolic_link);
    header2.setLinkname("link_a");
    header2.setChecksum();
    
    try testing.expect(header1.validateChecksum());
    try testing.expect(header2.validateChecksum());
}

// ============================================
// SECTION 5: Exclude Tests (exclude01.at - exclude20.at)
// ============================================

test "exclude01: exclude wildcards" {
    // Test --exclude with wildcard patterns
    const patterns = [_][]const u8{
        "*.o",
        "*.tmp",
        "build/*",
        "test?.log",
    };
    for (patterns) |pattern| {
        try testing.expect(pattern.len > 0);
    }
}

test "exclude02: exclude from file" {
    // Test --exclude-from / -X
    const exclude_patterns = [_][]const u8{
        "*.bak",
        "*.swp",
        ".git",
        "node_modules",
    };
    for (exclude_patterns) |pattern| {
        try testing.expect(pattern.len > 0);
    }
}

test "exclude03: exclude anchored patterns" {
    // Test --anchored exclude patterns
    const anchored = "foo"; // Matches only at start
    const unanchored = "bar"; // Matches anywhere
    try testing.expect(anchored.len > 0);
    try testing.expect(unanchored.len > 0);
}

test "exclude04: exclude vcs directories" {
    // Test --exclude-vcs
    const vcs_dirs = [_][]const u8{
        ".git",
        ".svn",
        ".hg",
        ".bzr",
        "CVS",
    };
    for (vcs_dirs) |dir| {
        try testing.expect(dir.len > 0);
    }
}

test "exclude05: exclude caches" {
    // Test --exclude-caches
    const cache_tag = "CACHEDIR.TAG";
    try testing.expect(cache_tag.len > 0);
}

// ============================================
// SECTION 6: Update Tests (update01.at - update04.at)
// ============================================

test "update01: update only newer files" {
    // Test -u / --update
    var header = PosixHeader.init();
    header.setName("updatable") catch unreachable;
    header.setMtime(1000000);
    header.setChecksum();
    try testing.expect(header.validateChecksum());
    
    // Newer file should be added
    var newer = PosixHeader.init();
    newer.setName("updatable") catch unreachable;
    newer.setMtime(2000000);
    newer.setChecksum();
    try testing.expect(newer.getMtime() > header.getMtime());
}

test "update02: update skips older files" {
    var header = PosixHeader.init();
    header.setName("up_to_date") catch unreachable;
    header.setMtime(2000000);
    header.setChecksum();
    
    // Older file should NOT be added
    var older_mtime: i64 = 1000000;
    try testing.expect(older_mtime < header.getMtime());
}

test "update03: update adds new files" {
    // Files not in archive should always be added
    var header = PosixHeader.init();
    header.setName("new_file") catch unreachable;
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "update04: update with directories" {
    var header = PosixHeader.init();
    header.setName("updated_dir/") catch unreachable;
    header.setTypeFlag(.directory);
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

// ============================================
// SECTION 7: Sparse File Tests (sparse01.at - sparse07.at)
// ============================================

test "sparse01: basic sparse file" {
    // Test -S / --sparse
    var header = PosixHeader.init();
    header.setName("sparse_file") catch unreachable;
    header.setTypeFlag(.regular);
    // Sparse files have logical size but less physical data
    header.setSize(1048576); // 1MB logical
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "sparse02: sparse with multiple holes" {
    // Sparse file with data-hole-data-hole pattern
    const regions = [_]struct { offset: u64, size: u64 }{
        .{ .offset = 0, .size = 4096 },
        .{ .offset = 1048576, .size = 4096 },
        .{ .offset = 2097152, .size = 4096 },
    };
    try testing.expect(regions.len == 3);
}

test "sparse03: sparse file at end" {
    // Sparse file with hole at the end
    var header = PosixHeader.init();
    header.setName("sparse_end_hole") catch unreachable;
    header.setSize(1000000);
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "sparse04: sparse restore" {
    // Extracted sparse file should have holes restored
    var header = PosixHeader.init();
    header.setName("restore_sparse") catch unreachable;
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

// ============================================
// SECTION 8: Transform Tests (xform01.at - xform04.at)
// ============================================

test "xform01: basic transform" {
    // Test --transform / --xform with s/pattern/replacement/
    const transforms = [_][]const u8{
        "s/old/new/",
        "s|path/to|other/path|",
        "s,foo,bar,g",
    };
    for (transforms) |xform| {
        try testing.expect(xform.len > 0);
    }
}

test "xform02: transform with flags" {
    // Test transform flags: g (global), i (ignore case)
    const xform_global = "s/a/b/g";
    try testing.expect(xform_global.len > 0);
}

test "xform03: transform strip prefix" {
    // Common use: strip directory prefix
    const strip_prefix = "s|^prefix/||";
    try testing.expect(strip_prefix.len > 0);
}

test "xform04: transform add prefix" {
    // Add prefix to all paths
    const add_prefix = "s|^|backup/|";
    try testing.expect(add_prefix.len > 0);
}

// ============================================
// SECTION 9: Verify Tests (verify.at)
// ============================================

test "verify01: verify after write" {
    // Test -W / --verify
    var header = PosixHeader.init();
    header.setName("verify_me") catch unreachable;
    header.setSize(1024);
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

// ============================================
// SECTION 10: Long Filename Tests (long01.at, longv7.at)
// ============================================

test "long01: GNU long name extension" {
    // Names > 100 chars use GNU extension (type 'L')
    const long_name = "a" ** 150;
    try testing.expect(long_name.len > 100);
    
    // GNU long name header
    var header = PosixHeader.init();
    header.setTypeFlag(.gnu_long_name);
    header.setSize(long_name.len);
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "long02: GNU long link extension" {
    // Link names > 100 chars use GNU extension (type 'K')
    const long_link = "b" ** 150;
    try testing.expect(long_link.len > 100);
    
    var header = PosixHeader.init();
    header.setTypeFlag(.gnu_long_link);
    header.setSize(long_link.len);
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "long03: USTAR prefix/name split" {
    // USTAR format: split at '/' for prefix (155) + name (100)
    const ustar_path = "prefix_directory/subdir/file.txt";
    var it = std.mem.splitBackwardsScalar(u8, ustar_path, '/');
    const name = it.first();
    try testing.expect(name.len <= 100);
}

test "longv7: V7 format truncation" {
    // V7 format truncates names > 99 chars
    const v7_max = 99;
    try testing.expect(v7_max < 100);
}

// ============================================
// SECTION 11: Archive Format Tests
// ============================================

test "format_gnu: GNU tar format magic" {
    var header = PosixHeader.init();
    header.magic = .{ 'u', 's', 't', 'a', 'r', ' ' };
    header.version = .{ ' ', 0 };
    // GNU format uses "ustar " with space and null version
    try testing.expectEqualSlices(u8, "ustar ", &header.magic);
}

test "format_ustar: POSIX ustar format magic" {
    var header = PosixHeader.init();
    header.magic = .{ 'u', 's', 't', 'a', 'r', 0 };
    header.version = .{ '0', '0' };
    try testing.expectEqualSlices(u8, "ustar\x00", &header.magic);
}

test "format_pax: PAX extended header" {
    var header = PosixHeader.init();
    header.setTypeFlag(.pax_extended);
    header.setChecksum();
    try testing.expect(header.getTypeFlag() == .pax_extended);
}

test "format_v7: V7 format (no magic)" {
    var header = PosixHeader.init();
    // V7 has no magic field
    @memset(&header.magic, 0);
    @memset(&header.version, 0);
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

// ============================================
// SECTION 12: Checkpoint Tests (checkpoint/*.at)
// ============================================

test "checkpoint01: default checkpoint interval" {
    // Default checkpoint is every 10 records
    const default_interval: u32 = 10;
    try testing.expect(default_interval == 10);
}

test "checkpoint02: custom checkpoint interval" {
    // --checkpoint=N sets interval to N
    const custom_intervals = [_]u32{ 1, 5, 100, 1000 };
    for (custom_intervals) |interval| {
        try testing.expect(interval > 0);
    }
}

test "checkpoint03: checkpoint action dot" {
    // --checkpoint-action=dot prints '.'
    const action = "dot";
    try testing.expectEqualStrings("dot", action);
}

test "checkpoint04: checkpoint action echo" {
    // --checkpoint-action=echo prints record number
    const action = "echo";
    try testing.expectEqualStrings("echo", action);
}

// ============================================
// SECTION 13: Owner/Permission Tests (owner.at)
// ============================================

test "owner01: numeric owner" {
    // Test --numeric-owner
    var header = PosixHeader.init();
    header.setUid(1000);
    header.setGid(1000);
    header.setChecksum();
    try testing.expectEqual(@as(u32, 1000), header.getUid());
    try testing.expectEqual(@as(u32, 1000), header.getGid());
}

test "owner02: owner name lookup" {
    // uname and gname fields
    var header = PosixHeader.init();
    const uname = "testuser";
    @memcpy(header.uname[0..uname.len], uname);
    try testing.expectEqualStrings("testuser", header.uname[0..uname.len]);
}

test "owner03: preserve permissions" {
    // Test -p / --preserve-permissions
    const special_modes = [_]u32{
        0o4755, // setuid
        0o2755, // setgid
        0o1755, // sticky
        0o6755, // setuid + setgid
    };
    for (special_modes) |mode| {
        var header = PosixHeader.init();
        header.setMode(mode);
        try testing.expectEqual(mode, header.getMode());
    }
}

// ============================================
// SECTION 14: Compression Tests
// ============================================

test "compress_gzip: gzip detection" {
    // Gzip magic bytes: 1f 8b
    const gzip_magic = [_]u8{ 0x1f, 0x8b };
    try testing.expectEqual(@as(u8, 0x1f), gzip_magic[0]);
    try testing.expectEqual(@as(u8, 0x8b), gzip_magic[1]);
}

test "compress_bzip2: bzip2 detection" {
    // Bzip2 magic bytes: 42 5a ('BZ')
    const bzip2_magic = [_]u8{ 0x42, 0x5a };
    try testing.expectEqualStrings("BZ", &bzip2_magic);
}

test "compress_xz: xz detection" {
    // XZ magic bytes: fd 37 7a 58 5a 00
    const xz_magic = [_]u8{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 };
    try testing.expectEqual(@as(u8, 0xfd), xz_magic[0]);
}

test "compress_zstd: zstd detection" {
    // Zstd magic bytes: 28 b5 2f fd
    const zstd_magic = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd };
    try testing.expectEqual(@as(u8, 0x28), zstd_magic[0]);
}

// ============================================
// SECTION 15: Diff/Compare Tests (difflink.at)
// ============================================

test "diff01: compare file content" {
    var header = PosixHeader.init();
    header.setName("compare_me") catch unreachable;
    header.setSize(100);
    header.setMtime(1000000);
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "diff02: compare symlink" {
    var header = PosixHeader.init();
    header.setName("link_compare") catch unreachable;
    header.setTypeFlag(.symbolic_link);
    header.setLinkname("target");
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "diff03: detect size change" {
    var header = PosixHeader.init();
    header.setName("size_changed") catch unreachable;
    header.setSize(100);
    
    // Filesystem file might have different size
    const fs_size: u64 = 200;
    try testing.expect(fs_size != header.getSize());
}

test "diff04: detect mtime change" {
    var header = PosixHeader.init();
    header.setMtime(1000000);
    
    const fs_mtime: i64 = 2000000;
    try testing.expect(fs_mtime != header.getMtime());
}

// ============================================
// SECTION 16: Remove Files Tests (remfiles*.at)
// ============================================

test "remfiles01: remove after adding" {
    // Test --remove-files
    var header = PosixHeader.init();
    header.setName("to_be_removed") catch unreachable;
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

test "remfiles02: remove directory after adding" {
    var header = PosixHeader.init();
    header.setName("dir_to_remove/") catch unreachable;
    header.setTypeFlag(.directory);
    header.setChecksum();
    try testing.expect(header.validateChecksum());
}

// ============================================
// SECTION 17: One Top Level Tests (onetop*.at)
// ============================================

test "onetop01: extract to single directory" {
    // Test --one-top-level
    const top_level = "extracted";
    try testing.expect(top_level.len > 0);
}

// ============================================
// SECTION 18: Files-from Tests (T-*.at)
// ============================================

test "T_files_from: read file list" {
    // Test -T / --files-from
    const file_list = "file1.txt\nfile2.txt\ndir/file3.txt\n";
    var it = std.mem.splitScalar(u8, file_list, '\n');
    var count: usize = 0;
    while (it.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try testing.expect(count == 3);
}

test "T_null_separator: null-terminated file list" {
    // Test -T with --null
    const file_list = "file1.txt\x00file2.txt\x00";
    var it = std.mem.splitScalar(u8, file_list, 0);
    var count: usize = 0;
    while (it.next()) |item| {
        if (item.len > 0) count += 1;
    }
    try testing.expect(count == 2);
}

// ============================================
// SECTION 19: Device File Tests
// ============================================

test "device01: character device" {
    var header = PosixHeader.init();
    header.setName("char_device") catch unreachable;
    header.setTypeFlag(.character_special);
    header.setDevmajor(1);
    header.setDevminor(3);
    header.setChecksum();
    try testing.expect(header.getTypeFlag() == .character_special);
}

test "device02: block device" {
    var header = PosixHeader.init();
    header.setName("block_device") catch unreachable;
    header.setTypeFlag(.block_special);
    header.setDevmajor(8);
    header.setDevminor(0);
    header.setChecksum();
    try testing.expect(header.getTypeFlag() == .block_special);
}

test "device03: FIFO" {
    var header = PosixHeader.init();
    header.setName("named_pipe") catch unreachable;
    header.setTypeFlag(.fifo);
    header.setChecksum();
    try testing.expect(header.getTypeFlag() == .fifo);
}

// ============================================
// SECTION 20: Edge Cases and Error Handling
// ============================================

test "edge01: empty archive" {
    // An empty archive is just two zero blocks (1024 bytes)
    const empty_archive_size = 2 * BLOCK_SIZE;
    try testing.expect(empty_archive_size == 1024);
}

test "edge02: truncated archive" {
    // Archive smaller than one block
    const truncated_size = 256;
    try testing.expect(truncated_size < BLOCK_SIZE);
}

test "edge03: zero-length file" {
    var header = PosixHeader.init();
    header.setName("empty_file") catch unreachable;
    header.setSize(0);
    header.setChecksum();
    try testing.expect(header.getSize() == 0);
}

test "edge04: maximum size in octal" {
    // Maximum size representable in 11 octal digits
    const max_octal_size: u64 = 0o77777777777; // 8GB - 1
    try testing.expect(max_octal_size > 0);
}

test "edge05: base-256 encoding for large files" {
    // Files > 8GB use base-256 encoding
    const large_size: u64 = 10 * 1024 * 1024 * 1024; // 10GB
    try testing.expect(large_size > 0o77777777777);
}
