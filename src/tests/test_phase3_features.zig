// Phase 3 Feature Tests for tar-zig
// Tests for incremental backups, multi-volume archives, and extended attributes

const std = @import("std");
const testing = std.testing;
const incremental = @import("../incremental.zig");
const multivolume = @import("../multivolume.zig");
const xattrs = @import("../xattrs.zig");
const tar_header = @import("../tar_header.zig");

const PosixHeader = tar_header.PosixHeader;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;

// ============================================
// SECTION 1: Incremental Backup Tests
// ============================================

test "incremental: snapshot init and deinit" {
    var snapshot = incremental.Snapshot.init(testing.allocator);
    defer snapshot.deinit();

    try testing.expectEqual(@as(usize, 0), snapshot.entries.items.len);
    try testing.expectEqualStrings(incremental.SNAPSHOT_VERSION, snapshot.version);
}

test "incremental: snapshot update directory" {
    var snapshot = incremental.Snapshot.init(testing.allocator);
    defer snapshot.deinit();

    const entry = try snapshot.updateDirectory("/home/user/docs", 65025, 12345, 1700000000, 123456789);
    try testing.expectEqual(@as(u64, 65025), entry.dev);
    try testing.expectEqual(@as(u64, 12345), entry.ino);
    try testing.expectEqual(@as(i64, 1700000000), entry.mtime_sec);

    // Update existing should modify in place
    const entry2 = try snapshot.updateDirectory("/home/user/docs", 65025, 12345, 1700000001, 0);
    try testing.expectEqual(@as(i64, 1700000001), entry2.mtime_sec);
    try testing.expectEqual(@as(usize, 1), snapshot.entries.items.len);
}

test "incremental: snapshot add content" {
    var snapshot = incremental.Snapshot.init(testing.allocator);
    defer snapshot.deinit();

    var entry = try snapshot.updateDirectory("/test", 1, 100, 1000, 0);
    try snapshot.addContent(entry, "file1.txt", 'Y');
    try snapshot.addContent(entry, "file2.txt", 'Y');
    try snapshot.addContent(entry, "deleted.txt", 'N');

    try testing.expectEqual(@as(usize, 3), entry.contents.items.len);
    try testing.expectEqual(@as(u8, 'Y'), entry.content_flags.items[0]);
    try testing.expectEqual(@as(u8, 'N'), entry.content_flags.items[2]);
}

test "incremental: hasFileChanged detection" {
    var snapshot = incremental.Snapshot.init(testing.allocator);
    defer snapshot.deinit();

    var entry = try snapshot.updateDirectory("/home/user", 1, 100, 1000, 0);
    try snapshot.addContent(entry, "old_file.txt", 'Y');

    // New file should be marked as changed
    try testing.expect(incremental.hasFileChanged(&snapshot, "/home/user", "new_file.txt", 500));

    // Existing file with older mtime should NOT be changed
    try testing.expect(!incremental.hasFileChanged(&snapshot, "/home/user", "old_file.txt", 500));

    // Existing file with newer mtime SHOULD be changed
    try testing.expect(incremental.hasFileChanged(&snapshot, "/home/user", "old_file.txt", 2000));

    // File in non-existent directory should be changed
    try testing.expect(incremental.hasFileChanged(&snapshot, "/other/path", "file.txt", 500));
}

test "incremental: hasDirectoryChanged detection" {
    var snapshot = incremental.Snapshot.init(testing.allocator);
    defer snapshot.deinit();

    _ = try snapshot.updateDirectory("/data", 65025, 12345, 1000, 0);

    // Same directory, older mtime - not changed
    try testing.expect(!incremental.hasDirectoryChanged(&snapshot, "/data", 65025, 12345, 500));

    // Same directory, newer mtime - changed
    try testing.expect(incremental.hasDirectoryChanged(&snapshot, "/data", 65025, 12345, 2000));

    // Different inode (directory replaced) - changed
    try testing.expect(incremental.hasDirectoryChanged(&snapshot, "/data", 65025, 99999, 500));

    // Different device - changed
    try testing.expect(incremental.hasDirectoryChanged(&snapshot, "/data", 99999, 12345, 500));

    // Non-existent directory - changed
    try testing.expect(incremental.hasDirectoryChanged(&snapshot, "/nonexistent", 1, 1, 500));
}

test "incremental: dumpdir builder" {
    var builder = incremental.DumpdirBuilder.init(testing.allocator);
    defer builder.deinit();

    try builder.addEntry('Y', "file1.txt");
    try builder.addEntry('Y', "subdir");
    try builder.addEntry('N', "deleted_file.txt");
    try builder.addEntry('D', "renamed_dir");

    const data = builder.getData();
    try testing.expect(data.len > 0);

    // Check structure: flag + name + null for each entry
    try testing.expectEqual(@as(u8, 'Y'), data[0]);

    // Size should include space for final null
    try testing.expect(builder.getSize() == data.len + 1);
}

test "incremental: snapshot find directory" {
    var snapshot = incremental.Snapshot.init(testing.allocator);
    defer snapshot.deinit();

    _ = try snapshot.updateDirectory("/home", 1, 100, 1000, 0);
    _ = try snapshot.updateDirectory("/var/log", 1, 200, 2000, 0);

    const found = snapshot.findDirectory("/home");
    try testing.expect(found != null);
    try testing.expectEqual(@as(u64, 100), found.?.ino);

    const found2 = snapshot.findDirectory("/var/log");
    try testing.expect(found2 != null);
    try testing.expectEqual(@as(u64, 200), found2.?.ino);

    const not_found = snapshot.findDirectory("/nonexistent");
    try testing.expect(not_found == null);
}

// ============================================
// SECTION 2: Multi-Volume Archive Tests
// ============================================

test "multivolume: state initialization" {
    var state = try multivolume.MultiVolumeState.init(testing.allocator, "backup.tar", 10 * 1024 * 1024);
    defer state.deinit();

    try testing.expectEqual(@as(u64, 10 * 1024 * 1024), state.volume_size);
    try testing.expectEqual(@as(u32, 1), state.current_volume);
    try testing.expectEqual(@as(u64, 0), state.bytes_written);
}

test "multivolume: volume naming" {
    var state = try multivolume.MultiVolumeState.init(testing.allocator, "archive.tar", 1024 * 1024);
    defer state.deinit();

    const name1 = try state.getVolumeName(1);
    defer testing.allocator.free(name1);
    try testing.expectEqualStrings("archive.tar-01", name1);

    const name2 = try state.getVolumeName(2);
    defer testing.allocator.free(name2);
    try testing.expectEqualStrings("archive.tar-02", name2);

    const name99 = try state.getVolumeName(99);
    defer testing.allocator.free(name99);
    try testing.expectEqualStrings("archive.tar-99", name99);
}

test "multivolume: space tracking" {
    var state = try multivolume.MultiVolumeState.init(testing.allocator, "test.tar", 10000);
    defer state.deinit();

    // Initially should have full space
    try testing.expectEqual(@as(u64, 10000), state.remainingSpace());
    try testing.expect(!state.needsVolumeSwitch(5000));

    // Record some writes
    state.recordWrite(3000);
    try testing.expectEqual(@as(u64, 7000), state.remainingSpace());
    try testing.expect(!state.needsVolumeSwitch(7000));
    try testing.expect(state.needsVolumeSwitch(7001));

    // More writes
    state.recordWrite(7000);
    try testing.expectEqual(@as(u64, 0), state.remainingSpace());
    try testing.expect(state.needsVolumeSwitch(1));
}

test "multivolume: file tracking" {
    var state = try multivolume.MultiVolumeState.init(testing.allocator, "test.tar", 1024 * 1024);
    defer state.deinit();

    try state.startFile("large_file.bin", 5 * 1024 * 1024);
    try testing.expectEqualStrings("large_file.bin", state.current_file_name.?);
    try testing.expectEqual(@as(u64, 5 * 1024 * 1024), state.current_file_size);
    try testing.expectEqual(@as(u64, 0), state.current_file_offset);

    state.updateFileProgress(1024 * 1024);
    try testing.expectEqual(@as(u64, 1024 * 1024), state.current_file_offset);

    state.finishFile();
    try testing.expect(state.current_file_name == null);
}

test "multivolume: volume header creation" {
    const header = multivolume.createVolumeHeader(.{
        .label = "BACKUP_VOL1",
        .volume_number = 1,
        .total_volumes = 5,
        .timestamp = 1700000000,
    });

    try testing.expectEqual(@as(u8, multivolume.CONTINUATION_FLAG), header.typeflag);
    try testing.expectEqualStrings("BACKUP_VOL1", std.mem.sliceTo(&header.name, 0));
    try testing.expect(header.validateChecksum());
}

test "multivolume: continuation header creation" {
    var original = PosixHeader.init();
    original.setName("big_database.sql") catch unreachable;
    original.setSize(100 * 1024 * 1024);
    original.setMode(0o644);
    original.setMtime(1700000000);
    original.setChecksum();

    const cont = multivolume.createContinuationHeader(
        "big_database.sql",
        50 * 1024 * 1024, // remaining
        50 * 1024 * 1024, // offset
        &original,
    );

    try testing.expectEqual(@as(u8, multivolume.MULTIVOLUME_FLAG), cont.typeflag);
    try testing.expectEqual(@as(u64, 50 * 1024 * 1024), cont.getSize());
    try testing.expect(cont.validateChecksum());
}

test "multivolume: parse multivolume header" {
    var header = PosixHeader.init();
    header.typeflag = multivolume.MULTIVOLUME_FLAG;

    const parsed = multivolume.parseMultiVolumeHeader(&header);
    try testing.expect(parsed != null);
    try testing.expect(parsed.?.is_continuation);
}

test "multivolume: volume switch tracking" {
    var state = try multivolume.MultiVolumeState.init(testing.allocator, "test.tar", 1000);
    defer state.deinit();

    try testing.expectEqual(@as(u32, 1), state.current_volume);
    state.recordWrite(500);

    try state.switchVolume();
    try testing.expectEqual(@as(u32, 2), state.current_volume);
    try testing.expectEqual(@as(u64, 0), state.bytes_written);
}

// ============================================
// SECTION 3: Extended Attributes Tests
// ============================================

test "xattrs: set basic operations" {
    var xattr_set = xattrs.XattrSet.init(testing.allocator);
    defer xattr_set.deinit();

    try xattr_set.add("user.comment", "This is a test file");
    try xattr_set.add("user.author", "Test Author");
    try xattr_set.add("user.created", "2024-01-01");

    try testing.expect(!xattr_set.isEmpty());
    try testing.expectEqual(@as(usize, 3), xattr_set.entries.items.len);

    const comment = xattr_set.get("user.comment");
    try testing.expect(comment != null);
    try testing.expectEqualStrings("This is a test file", comment.?);

    const nonexistent = xattr_set.get("user.nonexistent");
    try testing.expect(nonexistent == null);
}

test "xattrs: binary values" {
    var xattr_set = xattrs.XattrSet.init(testing.allocator);
    defer xattr_set.deinit();

    const binary_data = [_]u8{ 0x00, 0x01, 0x02, 0xFF, 0xFE, 0x00, 0x10 };
    try xattr_set.add("user.binary", &binary_data);

    const retrieved = xattr_set.get("user.binary");
    try testing.expect(retrieved != null);
    try testing.expectEqualSlices(u8, &binary_data, retrieved.?);
}

test "xattrs: ACL detection" {
    var xattr_set = xattrs.XattrSet.init(testing.allocator);
    defer xattr_set.deinit();

    try testing.expect(!xattr_set.hasAcls());

    try xattr_set.add("user.test", "value");
    try testing.expect(!xattr_set.hasAcls());

    try xattr_set.add("system.posix_acl_access", "acl binary data");
    try testing.expect(xattr_set.hasAcls());
}

test "xattrs: SELinux detection" {
    var xattr_set = xattrs.XattrSet.init(testing.allocator);
    defer xattr_set.deinit();

    try testing.expect(!xattr_set.hasSelinux());

    try xattr_set.add("user.test", "value");
    try testing.expect(!xattr_set.hasSelinux());

    try xattr_set.add("security.selinux", "system_u:object_r:user_home_t:s0");
    try testing.expect(xattr_set.hasSelinux());
}

test "xattrs: PAX encoding" {
    var xattr_set = xattrs.XattrSet.init(testing.allocator);
    defer xattr_set.deinit();

    try xattr_set.add("user.test", "hello world");

    const encoded = try xattrs.encodeToPax(testing.allocator, &xattr_set);
    defer testing.allocator.free(encoded);

    try testing.expect(encoded.len > 0);
    try testing.expect(std.mem.indexOf(u8, encoded, "SCHILY.xattr.user.test") != null);
}

test "xattrs: PAX decoding" {
    const pax_data = "36 SCHILY.xattr.user.comment=test\n";

    var decoded = try xattrs.decodeFromPax(testing.allocator, pax_data);
    defer decoded.deinit();

    const value = decoded.get("user.comment");
    try testing.expect(value != null);
    try testing.expectEqualStrings("test", value.?);
}

test "xattrs: PAX roundtrip" {
    var original = xattrs.XattrSet.init(testing.allocator);
    defer original.deinit();

    try original.add("user.key1", "value1");
    try original.add("user.key2", "value2");

    const encoded = try xattrs.encodeToPax(testing.allocator, &original);
    defer testing.allocator.free(encoded);

    var decoded = try xattrs.decodeFromPax(testing.allocator, encoded);
    defer decoded.deinit();

    try testing.expectEqual(@as(usize, 2), decoded.entries.items.len);
    try testing.expectEqualStrings("value1", decoded.get("user.key1").?);
    try testing.expectEqualStrings("value2", decoded.get("user.key2").?);
}

test "xattrs: SELinux context parsing" {
    var ctx = try xattrs.SelinuxContext.parse(testing.allocator, "system_u:object_r:httpd_sys_content_t:s0");
    defer ctx.deinit(testing.allocator);

    try testing.expectEqualStrings("system_u", ctx.user);
    try testing.expectEqualStrings("object_r", ctx.role);
    try testing.expectEqualStrings("httpd_sys_content_t", ctx.type_);
    try testing.expectEqualStrings("s0", ctx.level);
}

test "xattrs: SELinux context with MLS range" {
    var ctx = try xattrs.SelinuxContext.parse(testing.allocator, "user_u:user_r:user_t:s0-s0:c0.c1023");
    defer ctx.deinit(testing.allocator);

    try testing.expectEqualStrings("user_u", ctx.user);
    try testing.expectEqualStrings("user_r", ctx.role);
    try testing.expectEqualStrings("user_t", ctx.type_);
    try testing.expectEqualStrings("s0-s0:c0.c1023", ctx.level);
}

test "xattrs: SELinux context format" {
    var ctx = try xattrs.SelinuxContext.parse(testing.allocator, "staff_u:staff_r:staff_t:s0");
    defer ctx.deinit(testing.allocator);

    const formatted = try ctx.format(testing.allocator);
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings("staff_u:staff_r:staff_t:s0", formatted);
}

// ============================================
// SECTION 4: Edge Case Tests
// ============================================

test "edge: empty snapshot" {
    var snapshot = incremental.Snapshot.init(testing.allocator);
    defer snapshot.deinit();

    // Empty snapshot should indicate all files as changed
    try testing.expect(incremental.hasFileChanged(&snapshot, "/any/path", "file.txt", 0));
    try testing.expect(incremental.hasDirectoryChanged(&snapshot, "/any/path", 1, 1, 0));
}

test "edge: zero-size volume" {
    // Volume size of 0 should trigger immediate volume switch
    var state = try multivolume.MultiVolumeState.init(testing.allocator, "test.tar", 0);
    defer state.deinit();

    try testing.expect(state.needsVolumeSwitch(1));
    try testing.expectEqual(@as(u64, 0), state.remainingSpace());
}

test "edge: very large volume size" {
    const huge_size: u64 = 1024 * 1024 * 1024 * 1024; // 1 TB
    var state = try multivolume.MultiVolumeState.init(testing.allocator, "test.tar", huge_size);
    defer state.deinit();

    try testing.expect(!state.needsVolumeSwitch(1024 * 1024 * 1024)); // 1 GB
    try testing.expectEqual(huge_size, state.remainingSpace());
}

test "edge: empty xattr set" {
    var xattr_set = xattrs.XattrSet.init(testing.allocator);
    defer xattr_set.deinit();

    try testing.expect(xattr_set.isEmpty());
    try testing.expect(!xattr_set.hasAcls());
    try testing.expect(!xattr_set.hasSelinux());
    try testing.expect(xattr_set.get("anything") == null);
}

test "edge: xattr with empty value" {
    var xattr_set = xattrs.XattrSet.init(testing.allocator);
    defer xattr_set.deinit();

    try xattr_set.add("user.empty", "");
    try testing.expect(!xattr_set.isEmpty());

    const value = xattr_set.get("user.empty");
    try testing.expect(value != null);
    try testing.expectEqual(@as(usize, 0), value.?.len);
}

test "edge: xattr with very long name" {
    var xattr_set = xattrs.XattrSet.init(testing.allocator);
    defer xattr_set.deinit();

    const long_name = "user." ++ "x" ** 200;
    try xattr_set.add(long_name, "value");

    const value = xattr_set.get(long_name);
    try testing.expect(value != null);
}

test "edge: xattr with very long value" {
    var xattr_set = xattrs.XattrSet.init(testing.allocator);
    defer xattr_set.deinit();

    const long_value = "v" ** 65536;
    try xattr_set.add("user.longval", long_value);

    const value = xattr_set.get("user.longval");
    try testing.expect(value != null);
    try testing.expectEqual(@as(usize, 65536), value.?.len);
}

test "edge: dumpdir with special characters" {
    var builder = incremental.DumpdirBuilder.init(testing.allocator);
    defer builder.deinit();

    try builder.addEntry('Y', "file with spaces.txt");
    try builder.addEntry('Y', "файл.txt"); // Cyrillic
    try builder.addEntry('Y', "文件.txt"); // Chinese
    try builder.addEntry('Y', "file\twith\ttabs");

    const data = builder.getData();
    try testing.expect(data.len > 0);
}

test "edge: snapshot directory with trailing slash" {
    var snapshot = incremental.Snapshot.init(testing.allocator);
    defer snapshot.deinit();

    _ = try snapshot.updateDirectory("/path/to/dir/", 1, 100, 1000, 0);

    // Should find with trailing slash
    const found = snapshot.findDirectory("/path/to/dir/");
    try testing.expect(found != null);

    // But not without (exact match required)
    const not_found = snapshot.findDirectory("/path/to/dir");
    try testing.expect(not_found == null);
}

test "edge: multiple volumes rapid switching" {
    var state = try multivolume.MultiVolumeState.init(testing.allocator, "test.tar", 512);
    defer state.deinit();

    // Switch volumes multiple times
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try state.switchVolume();
    }

    try testing.expectEqual(@as(u32, 11), state.current_volume);
}

// ============================================
// SECTION 5: Integration-style Tests
// ============================================

test "integration: incremental backup simulation" {
    var snapshot = incremental.Snapshot.init(testing.allocator);
    defer snapshot.deinit();

    // Simulate first backup - all directories and files are new
    var dir1 = try snapshot.updateDirectory("/home/user", 1, 1000, 1000, 0);
    try snapshot.addContent(dir1, "document.txt", 'Y');
    try snapshot.addContent(dir1, "photo.jpg", 'Y');

    var dir2 = try snapshot.updateDirectory("/home/user/projects", 1, 1001, 1000, 0);
    try snapshot.addContent(dir2, "main.c", 'Y');
    try snapshot.addContent(dir2, "Makefile", 'Y');

    // Verify state after first backup
    try testing.expectEqual(@as(usize, 2), snapshot.entries.items.len);

    // Simulate incremental check
    // New file should be backed up
    try testing.expect(incremental.hasFileChanged(&snapshot, "/home/user", "new_file.txt", 2000));
    // Existing unchanged file should not
    try testing.expect(!incremental.hasFileChanged(&snapshot, "/home/user", "document.txt", 500));
    // Modified file should be backed up
    try testing.expect(incremental.hasFileChanged(&snapshot, "/home/user", "photo.jpg", 2000));
}

test "integration: multivolume archive simulation" {
    var state = try multivolume.MultiVolumeState.init(testing.allocator, "backup.tar", 1024 * 100); // 100KB volumes
    defer state.deinit();

    // Simulate writing files
    const file_sizes = [_]u64{ 30 * 1024, 50 * 1024, 80 * 1024, 20 * 1024 };

    for (file_sizes) |size| {
        if (state.needsVolumeSwitch(size)) {
            try state.switchVolume();
        }
        state.recordWrite(size);
    }

    // Should have switched volumes due to 80KB file
    try testing.expect(state.current_volume > 1);
}

test "integration: xattrs full workflow" {
    var xattr_set = xattrs.XattrSet.init(testing.allocator);
    defer xattr_set.deinit();

    // Add various types of xattrs
    try xattr_set.add("user.mime_type", "text/plain");
    try xattr_set.add("user.charset", "utf-8");
    try xattr_set.add("security.selinux", "system_u:object_r:user_home_t:s0");

    // Encode to PAX format
    const pax_data = try xattrs.encodeToPax(testing.allocator, &xattr_set);
    defer testing.allocator.free(pax_data);

    // Decode back
    var restored = try xattrs.decodeFromPax(testing.allocator, pax_data);
    defer restored.deinit();

    // Verify all attributes preserved
    try testing.expectEqual(@as(usize, 3), restored.entries.items.len);
    try testing.expectEqualStrings("text/plain", restored.get("user.mime_type").?);
    try testing.expect(restored.hasSelinux());
}
