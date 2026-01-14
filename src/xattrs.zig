// Extended attributes (xattrs) support for tar-zig
// Implements --xattrs, --acls, --selinux options
// Based on POSIX extended attributes and PAX format

const std = @import("std");
const tar_header = @import("tar_header.zig");
const builtin = @import("builtin");

const PosixHeader = tar_header.PosixHeader;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;

/// Extended attribute entry
pub const XattrEntry = struct {
    /// Attribute name (e.g., "user.comment", "security.selinux")
    name: []const u8,
    /// Attribute value (binary data)
    value: []const u8,

    pub fn deinit(self: *XattrEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

/// Collection of extended attributes for a file
pub const XattrSet = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(XattrEntry),

    pub fn init(allocator: std.mem.Allocator) XattrSet {
        return .{
            .allocator = allocator,
            .entries = .{},
        };
    }

    pub fn deinit(self: *XattrSet) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    /// Add an extended attribute
    pub fn add(self: *XattrSet, name: []const u8, value: []const u8) !void {
        const entry = XattrEntry{
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
        };
        try self.entries.append(self.allocator, entry);
    }

    /// Get an extended attribute by name
    pub fn get(self: *const XattrSet, name: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry.value;
            }
        }
        return null;
    }

    /// Check if set contains any entries
    pub fn isEmpty(self: *const XattrSet) bool {
        return self.entries.items.len == 0;
    }

    /// Check if set contains ACL entries
    pub fn hasAcls(self: *const XattrSet) bool {
        for (self.entries.items) |entry| {
            if (std.mem.startsWith(u8, entry.name, "system.posix_acl_")) {
                return true;
            }
        }
        return false;
    }

    /// Check if set contains SELinux context
    pub fn hasSelinux(self: *const XattrSet) bool {
        return self.get("security.selinux") != null;
    }
};

/// Options for xattr handling
pub const XattrOptions = struct {
    /// Include all extended attributes
    xattrs: bool = false,
    /// Include POSIX ACLs
    acls: bool = false,
    /// Include SELinux context
    selinux: bool = false,
    /// Exclude patterns for xattr names
    exclude_patterns: []const []const u8 = &.{},
    /// Include only these patterns
    include_patterns: []const []const u8 = &.{},
};

/// Read extended attributes from a file
/// Returns null if xattrs are not supported or file has none
pub fn readXattrs(allocator: std.mem.Allocator, path: []const u8, opts: XattrOptions) !?XattrSet {
    if (!opts.xattrs and !opts.acls and !opts.selinux) {
        return null;
    }

    var xattrs = XattrSet.init(allocator);
    errdefer xattrs.deinit();

    // Platform-specific xattr reading
    if (comptime builtin.os.tag == .linux) {
        try readXattrsLinux(allocator, path, &xattrs, opts);
    } else if (comptime builtin.os.tag == .macos) {
        try readXattrsMacos(allocator, path, &xattrs, opts);
    } else {
        // Xattrs not supported on this platform
        return null;
    }

    if (xattrs.isEmpty()) {
        xattrs.deinit();
        return null;
    }

    return xattrs;
}

/// Linux-specific xattr reading using system calls
fn readXattrsLinux(allocator: std.mem.Allocator, path: []const u8, xattrs: *XattrSet, opts: XattrOptions) !void {
    // Create null-terminated path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = @min(path.len, path_buf.len - 1);
    @memcpy(path_buf[0..path_len], path[0..path_len]);
    path_buf[path_len] = 0;
    const path_z = path_buf[0..path_len :0];

    // First, get the list of attribute names
    var list_buf: [65536]u8 = undefined;
    const list_result = std.posix.system.llistxattr(path_z, &list_buf, list_buf.len);

    if (list_result < 0) {
        // Error or not supported
        return;
    }

    const list_len: usize = @intCast(list_result);
    if (list_len == 0) return;

    // Parse the null-separated list of names
    var i: usize = 0;
    while (i < list_len) {
        const name_start = i;
        while (i < list_len and list_buf[i] != 0) : (i += 1) {}
        const name = list_buf[name_start..i];
        i += 1; // Skip null terminator

        if (name.len == 0) continue;

        // Check if we should include this attribute
        if (!shouldIncludeXattr(name, opts)) continue;

        // Get the attribute value
        var value_buf: [65536]u8 = undefined;
        
        // Need null-terminated name for syscall
        var name_z_buf: [256]u8 = undefined;
        if (name.len >= name_z_buf.len) continue;
        @memcpy(name_z_buf[0..name.len], name);
        name_z_buf[name.len] = 0;
        const name_z = name_z_buf[0..name.len :0];

        const value_result = std.posix.system.lgetxattr(path_z, name_z, &value_buf, value_buf.len);

        if (value_result >= 0) {
            const value_len: usize = @intCast(value_result);
            try xattrs.add(name, value_buf[0..value_len]);
        }
    }
}

/// macOS-specific xattr reading
fn readXattrsMacos(allocator: std.mem.Allocator, path: []const u8, xattrs: *XattrSet, opts: XattrOptions) !void {
    _ = allocator;
    _ = path;
    _ = xattrs;
    _ = opts;
    // macOS uses different syscalls (listxattr, getxattr without 'l' prefix)
    // Implementation would be similar to Linux but with different syscall names
    // For now, this is a placeholder
}

/// Check if an xattr should be included based on options
fn shouldIncludeXattr(name: []const u8, opts: XattrOptions) bool {
    // Check ACL-specific option
    if (std.mem.startsWith(u8, name, "system.posix_acl_")) {
        return opts.acls;
    }

    // Check SELinux-specific option
    if (std.mem.eql(u8, name, "security.selinux")) {
        return opts.selinux;
    }

    // Check exclude patterns
    for (opts.exclude_patterns) |pattern| {
        if (matchXattrPattern(name, pattern)) {
            return false;
        }
    }

    // Check include patterns (if specified, only include matching)
    if (opts.include_patterns.len > 0) {
        for (opts.include_patterns) |pattern| {
            if (matchXattrPattern(name, pattern)) {
                return true;
            }
        }
        return false;
    }

    // Default: include if xattrs option is set
    return opts.xattrs;
}

/// Match xattr name against pattern (supports * wildcard)
fn matchXattrPattern(name: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;

    if (std.mem.indexOf(u8, pattern, "*")) |star_pos| {
        const prefix = pattern[0..star_pos];
        const suffix = pattern[star_pos + 1 ..];

        if (!std.mem.startsWith(u8, name, prefix)) return false;
        if (suffix.len > 0 and !std.mem.endsWith(u8, name, suffix)) return false;
        return true;
    }

    return std.mem.eql(u8, name, pattern);
}

/// Write extended attributes to a file
pub fn writeXattrs(path: []const u8, xattrs: *const XattrSet) !void {
    if (comptime builtin.os.tag == .linux) {
        try writeXattrsLinux(path, xattrs);
    } else if (comptime builtin.os.tag == .macos) {
        try writeXattrsMacos(path, xattrs);
    }
    // Silently ignore on unsupported platforms
}

/// Linux-specific xattr writing
fn writeXattrsLinux(path: []const u8, xattrs: *const XattrSet) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = @min(path.len, path_buf.len - 1);
    @memcpy(path_buf[0..path_len], path[0..path_len]);
    path_buf[path_len] = 0;
    const path_z = path_buf[0..path_len :0];

    for (xattrs.entries.items) |entry| {
        var name_buf: [256]u8 = undefined;
        if (entry.name.len >= name_buf.len) continue;
        @memcpy(name_buf[0..entry.name.len], entry.name);
        name_buf[entry.name.len] = 0;
        const name_z = name_buf[0..entry.name.len :0];

        _ = std.posix.system.lsetxattr(path_z, name_z, entry.value.ptr, entry.value.len, 0);
        // Ignore errors - xattr setting may fail due to permissions
    }
}

/// macOS-specific xattr writing
fn writeXattrsMacos(path: []const u8, xattrs: *const XattrSet) !void {
    _ = path;
    _ = xattrs;
    // Placeholder for macOS implementation
}

/// Encode xattrs for PAX extended header format
pub fn encodeToPax(allocator: std.mem.Allocator, xattrs: *const XattrSet) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    errdefer buffer.deinit(allocator);

    for (xattrs.entries.items) |entry| {
        // PAX format: "length SCHILY.xattr.name=value\n"
        const key = try std.fmt.allocPrint(allocator, "SCHILY.xattr.{s}", .{entry.name});
        defer allocator.free(key);

        // Calculate length (length includes itself)
        // Format: "NN key=value\n" where NN is the total length
        const base_len = key.len + entry.value.len + 3; // " key=value\n"
        var len_digits: usize = 1;
        var check_len = base_len + len_digits;
        while (check_len >= std.math.pow(usize, 10, len_digits)) {
            len_digits += 1;
            check_len = base_len + len_digits;
        }

        const total_len = base_len + len_digits;
        const entry_str = try std.fmt.allocPrint(allocator, "{d} {s}=", .{ total_len, key });
        defer allocator.free(entry_str);

        try buffer.appendSlice(allocator, entry_str);
        try buffer.appendSlice(allocator, entry.value);
        try buffer.append(allocator, '\n');
    }

    return buffer.toOwnedSlice(allocator);
}

/// Decode xattrs from PAX extended header format
pub fn decodeFromPax(allocator: std.mem.Allocator, data: []const u8) !XattrSet {
    var xattrs = XattrSet.init(allocator);
    errdefer xattrs.deinit();

    var i: usize = 0;
    while (i < data.len) {
        // Parse length
        const space_pos = std.mem.indexOfScalarPos(u8, data, i, ' ') orelse break;
        const len_str = data[i..space_pos];
        const entry_len = std.fmt.parseInt(usize, len_str, 10) catch break;

        if (i + entry_len > data.len) break;

        const entry_data = data[space_pos + 1 .. i + entry_len];

        // Parse key=value
        if (std.mem.indexOf(u8, entry_data, "=")) |eq_pos| {
            const key = entry_data[0..eq_pos];
            // Value is everything after = until the newline (exclusive)
            var value = entry_data[eq_pos + 1 ..];
            if (value.len > 0 and value[value.len - 1] == '\n') {
                value = value[0 .. value.len - 1];
            }

            // Check if this is an xattr entry
            if (std.mem.startsWith(u8, key, "SCHILY.xattr.")) {
                const xattr_name = key["SCHILY.xattr.".len..];
                try xattrs.add(xattr_name, value);
            }
        }

        i += entry_len;
    }

    return xattrs;
}

/// ACL entry structure (POSIX.1e format)
pub const AclEntry = struct {
    /// Entry type: user, group, mask, other
    tag: AclTag,
    /// User/group ID (only valid for user/group tags)
    id: ?u32,
    /// Permissions (rwx)
    perms: AclPerms,
};

pub const AclTag = enum(u16) {
    user_obj = 0x0001, // Owner
    user = 0x0002, // Named user
    group_obj = 0x0004, // Owning group
    group = 0x0008, // Named group
    mask = 0x0010, // Mask
    other = 0x0020, // Other
};

pub const AclPerms = packed struct {
    execute: bool = false,
    write: bool = false,
    read: bool = false,
    _padding: u5 = 0,
};

/// Parse POSIX ACL from binary xattr format
pub fn parseAcl(data: []const u8) !std.ArrayListUnmanaged(AclEntry) {
    var entries = std.ArrayListUnmanaged(AclEntry){};
    
    if (data.len < 4) return entries;

    // ACL format: version (4 bytes) + entries (8 bytes each)
    // Version should be 2 for POSIX ACLs
    const version = std.mem.readInt(u32, data[0..4], .little);
    if (version != 2) return entries;

    var i: usize = 4;
    while (i + 8 <= data.len) {
        const tag = std.mem.readInt(u16, data[i..][0..2], .little);
        const perm = std.mem.readInt(u16, data[i + 2 ..][0..2], .little);
        const id = std.mem.readInt(u32, data[i + 4 ..][0..4], .little);

        const entry = AclEntry{
            .tag = @enumFromInt(tag),
            .id = if (tag == @intFromEnum(AclTag.user) or tag == @intFromEnum(AclTag.group)) id else null,
            .perms = @bitCast(@as(u8, @truncate(perm))),
        };

        try entries.append(std.heap.page_allocator, entry);
        i += 8;
    }

    return entries;
}

/// SELinux context helpers
pub const SelinuxContext = struct {
    user: []const u8,
    role: []const u8,
    type_: []const u8,
    level: []const u8,

    /// Parse SELinux context string (user:role:type:level)
    pub fn parse(allocator: std.mem.Allocator, context: []const u8) !SelinuxContext {
        var parts = std.mem.splitScalar(u8, context, ':');

        const user = parts.next() orelse return error.InvalidContext;
        const role = parts.next() orelse return error.InvalidContext;
        const type_ = parts.next() orelse return error.InvalidContext;
        const level = parts.rest();

        return .{
            .user = try allocator.dupe(u8, user),
            .role = try allocator.dupe(u8, role),
            .type_ = try allocator.dupe(u8, type_),
            .level = try allocator.dupe(u8, level),
        };
    }

    pub fn deinit(self: *SelinuxContext, allocator: std.mem.Allocator) void {
        allocator.free(self.user);
        allocator.free(self.role);
        allocator.free(self.type_);
        allocator.free(self.level);
    }

    /// Format as string
    pub fn format(self: *const SelinuxContext, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:{s}:{s}:{s}", .{
            self.user,
            self.role,
            self.type_,
            self.level,
        });
    }
};

test "XattrSet basic operations" {
    var xattrs = XattrSet.init(std.testing.allocator);
    defer xattrs.deinit();

    try xattrs.add("user.comment", "test value");
    try xattrs.add("user.author", "test author");

    try std.testing.expect(!xattrs.isEmpty());
    try std.testing.expectEqual(@as(usize, 2), xattrs.entries.items.len);

    const value = xattrs.get("user.comment");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("test value", value.?);
}

test "XattrSet ACL and SELinux detection" {
    var xattrs = XattrSet.init(std.testing.allocator);
    defer xattrs.deinit();

    try xattrs.add("user.test", "value");
    try std.testing.expect(!xattrs.hasAcls());
    try std.testing.expect(!xattrs.hasSelinux());

    try xattrs.add("system.posix_acl_access", "acl data");
    try std.testing.expect(xattrs.hasAcls());

    try xattrs.add("security.selinux", "user_u:role_r:type_t:s0");
    try std.testing.expect(xattrs.hasSelinux());
}

test "xattr pattern matching" {
    try std.testing.expect(matchXattrPattern("user.comment", "*"));
    try std.testing.expect(matchXattrPattern("user.comment", "user.*"));
    try std.testing.expect(matchXattrPattern("user.comment", "user.comment"));
    try std.testing.expect(!matchXattrPattern("user.comment", "system.*"));
    try std.testing.expect(matchXattrPattern("security.selinux", "security.*"));
}

test "shouldIncludeXattr filtering" {
    const opts_all = XattrOptions{ .xattrs = true, .acls = true, .selinux = true };
    try std.testing.expect(shouldIncludeXattr("user.test", opts_all));
    try std.testing.expect(shouldIncludeXattr("system.posix_acl_access", opts_all));
    try std.testing.expect(shouldIncludeXattr("security.selinux", opts_all));

    const opts_no_acl = XattrOptions{ .xattrs = true, .acls = false, .selinux = false };
    try std.testing.expect(shouldIncludeXattr("user.test", opts_no_acl));
    try std.testing.expect(!shouldIncludeXattr("system.posix_acl_access", opts_no_acl));
    try std.testing.expect(!shouldIncludeXattr("security.selinux", opts_no_acl));
}

test "PAX encoding roundtrip" {
    var xattrs = XattrSet.init(std.testing.allocator);
    defer xattrs.deinit();

    try xattrs.add("user.test", "hello");
    try xattrs.add("user.binary", &[_]u8{ 1, 2, 3, 0, 4, 5 });

    const encoded = try encodeToPax(std.testing.allocator, &xattrs);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeFromPax(std.testing.allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 2), decoded.entries.items.len);
}

test "SELinux context parsing" {
    var ctx = try SelinuxContext.parse(std.testing.allocator, "system_u:object_r:user_home_t:s0");
    defer ctx.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("system_u", ctx.user);
    try std.testing.expectEqualStrings("object_r", ctx.role);
    try std.testing.expectEqualStrings("user_home_t", ctx.type_);
    try std.testing.expectEqualStrings("s0", ctx.level);
}
