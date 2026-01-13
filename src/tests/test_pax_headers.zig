const std = @import("std");
const pax = @import("pax");

// PAX Extended Header Tests for tar-zig
// Based on GNU tar tests for PAX format support

// Test PAX header parsing with path
test "parse pax path attribute" {
    // "17 path=test.txt\n" = 17 chars
    const data = "17 path=test.txt\n";
    var attrs = try pax.parsePaxHeader(std.testing.allocator, data);
    defer attrs.deinit();

    try std.testing.expect(attrs.path != null);
    try std.testing.expectEqualStrings("test.txt", attrs.path.?);
}

// Test PAX header with size attribute
test "parse pax size attribute" {
    // "21 size=1234567890\n" = "21" (2) + " " (1) + "size=1234567890" (15) + "\n" (1) = 19... need to calc
    // Actually: length includes itself. Let's use a simple value.
    // "14 size=12345\n" = "14" (2) + " " (1) + "size=12345" (10) + "\n" (1) = 14
    const data = "14 size=12345\n";
    var attrs = try pax.parsePaxHeader(std.testing.allocator, data);
    defer attrs.deinit();

    try std.testing.expect(attrs.size != null);
    try std.testing.expectEqual(@as(u64, 12345), attrs.size.?);
}

// Test PAX header with mtime (high precision)
test "parse pax mtime with decimals" {
    // "22 mtime=1234567890.5\n" = 22 chars
    const data = "22 mtime=1234567890.5\n";
    var attrs = try pax.parsePaxHeader(std.testing.allocator, data);
    defer attrs.deinit();

    try std.testing.expect(attrs.mtime != null);
    try std.testing.expectApproxEqAbs(@as(f64, 1234567890.5), attrs.mtime.?, 0.001);
}

// Test PAX header with multiple attributes
test "parse multiple pax attributes" {
    // "17 path=test.txt\n" = 17: "17" + " " + "path=test.txt" + "\n" = 2+1+13+1 = 17 ✓
    // "12 uid=1000\n" = 12: "12" + " " + "uid=1000" + "\n" = 2+1+8+1 = 12 ✓
    // "12 gid=1000\n" = 12: same
    const data = "17 path=test.txt\n12 uid=1000\n12 gid=1000\n";
    var attrs = try pax.parsePaxHeader(std.testing.allocator, data);
    defer attrs.deinit();

    try std.testing.expectEqualStrings("test.txt", attrs.path.?);
    try std.testing.expectEqual(@as(u32, 1000), attrs.uid.?);
    try std.testing.expectEqual(@as(u32, 1000), attrs.gid.?);
}

// Test PAX header with linkpath
test "parse pax linkpath" {
    // "23 linkpath=/tmp/link\n" = "23" + " " + "linkpath=/tmp/link" + "\n" = 2+1+18+1 = 22... 
    // Let's recalc: "22 linkpath=/tmp/link\n" = 22 chars total
    const data = "22 linkpath=/tmp/link\n";
    var attrs = try pax.parsePaxHeader(std.testing.allocator, data);
    defer attrs.deinit();

    try std.testing.expect(attrs.linkpath != null);
    try std.testing.expectEqualStrings("/tmp/link", attrs.linkpath.?);
}

// Test PAX header with uname/gname
test "parse pax uname gname" {
    // "14 uname=root\n" = "14" + " " + "uname=root" + "\n" = 2+1+10+1 = 14 ✓
    // "15 gname=wheel\n" = "15" + " " + "gname=wheel" + "\n" = 2+1+11+1 = 15 ✓
    const data = "14 uname=root\n15 gname=wheel\n";
    var attrs = try pax.parsePaxHeader(std.testing.allocator, data);
    defer attrs.deinit();

    try std.testing.expectEqualStrings("root", attrs.uname.?);
    try std.testing.expectEqualStrings("wheel", attrs.gname.?);
}

// Test empty PAX header
test "parse empty pax header" {
    const data = "";
    var attrs = try pax.parsePaxHeader(std.testing.allocator, data);
    defer attrs.deinit();

    try std.testing.expect(attrs.path == null);
    try std.testing.expect(attrs.size == null);
}

// Test PAX keyword enum
test "pax keyword from string" {
    try std.testing.expectEqual(pax.PaxKeyword.path, pax.PaxKeyword.fromString("path").?);
    try std.testing.expectEqual(pax.PaxKeyword.mtime, pax.PaxKeyword.fromString("mtime").?);
    try std.testing.expectEqual(pax.PaxKeyword.size, pax.PaxKeyword.fromString("size").?);
    try std.testing.expectEqual(pax.PaxKeyword.linkpath, pax.PaxKeyword.fromString("linkpath").?);
    try std.testing.expect(pax.PaxKeyword.fromString("invalid") == null);
}

// Test PAX keyword to string
test "pax keyword to string" {
    try std.testing.expectEqualStrings("path", pax.PaxKeyword.path.toString());
    try std.testing.expectEqualStrings("mtime", pax.PaxKeyword.mtime.toString());
    try std.testing.expectEqualStrings("size", pax.PaxKeyword.size.toString());
}

// Test PAX attributes set method
test "pax attributes set" {
    var attrs = pax.PaxAttributes.init(std.testing.allocator);
    defer attrs.deinit();

    try attrs.set("path", "myfile.txt");
    try attrs.set("size", "12345");
    try attrs.set("uid", "1000");

    try std.testing.expectEqualStrings("myfile.txt", attrs.path.?);
    try std.testing.expectEqual(@as(u64, 12345), attrs.size.?);
    try std.testing.expectEqual(@as(u32, 1000), attrs.uid.?);
}

// Test PAX build header
test "build pax header" {
    var attrs = pax.PaxAttributes.init(std.testing.allocator);
    defer attrs.deinit();

    attrs.path = try std.testing.allocator.dupe(u8, "test.txt");

    const data = try pax.buildPaxHeader(std.testing.allocator, &attrs);
    defer std.testing.allocator.free(data);

    try std.testing.expect(std.mem.indexOf(u8, data, "path=test.txt") != null);
}

// Test needsPaxHeaders function
test "needs pax headers for long name" {
    const long_name = "a" ** 150;
    try std.testing.expect(pax.needsPaxHeaders(long_name, 0, ""));
}

test "needs pax headers for large size" {
    const large_size: u64 = 10 * 1024 * 1024 * 1024; // 10 GB
    try std.testing.expect(pax.needsPaxHeaders("small.txt", large_size, ""));
}

test "no pax headers for normal file" {
    try std.testing.expect(!pax.needsPaxHeaders("normal.txt", 1024, ""));
}
