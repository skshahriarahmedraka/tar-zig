const std = @import("std");
const tar_header = @import("tar_header.zig");

const PosixHeader = tar_header.PosixHeader;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;

/// PAX extended header keywords
pub const PaxKeyword = enum {
    path,           // File path (for long/Unicode names)
    linkpath,       // Link target path
    size,           // File size (for large files)
    uid,            // User ID
    gid,            // Group ID
    uname,          // User name
    gname,          // Group name
    mtime,          // Modification time (with nanoseconds)
    atime,          // Access time
    ctime,          // Change time
    charset,        // Character set
    comment,        // Archive comment
    hdrcharset,     // Header character set
    
    pub fn toString(self: PaxKeyword) []const u8 {
        return switch (self) {
            .path => "path",
            .linkpath => "linkpath",
            .size => "size",
            .uid => "uid",
            .gid => "gid",
            .uname => "uname",
            .gname => "gname",
            .mtime => "mtime",
            .atime => "atime",
            .ctime => "ctime",
            .charset => "charset",
            .comment => "comment",
            .hdrcharset => "hdrcharset",
        };
    }
    
    pub fn fromString(str: []const u8) ?PaxKeyword {
        const keywords = .{
            .{ "path", PaxKeyword.path },
            .{ "linkpath", PaxKeyword.linkpath },
            .{ "size", PaxKeyword.size },
            .{ "uid", PaxKeyword.uid },
            .{ "gid", PaxKeyword.gid },
            .{ "uname", PaxKeyword.uname },
            .{ "gname", PaxKeyword.gname },
            .{ "mtime", PaxKeyword.mtime },
            .{ "atime", PaxKeyword.atime },
            .{ "ctime", PaxKeyword.ctime },
            .{ "charset", PaxKeyword.charset },
            .{ "comment", PaxKeyword.comment },
            .{ "hdrcharset", PaxKeyword.hdrcharset },
        };
        
        inline for (keywords) |kw| {
            if (std.mem.eql(u8, str, kw[0])) {
                return kw[1];
            }
        }
        return null;
    }
};

/// PAX extended attributes
pub const PaxAttributes = struct {
    allocator: std.mem.Allocator,
    path: ?[]u8 = null,
    linkpath: ?[]u8 = null,
    size: ?u64 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
    uname: ?[]u8 = null,
    gname: ?[]u8 = null,
    mtime: ?f64 = null,
    atime: ?f64 = null,
    ctime: ?f64 = null,
    
    // For vendor-specific extensions
    extra: std.StringHashMap([]u8),

    pub fn init(allocator: std.mem.Allocator) PaxAttributes {
        return .{
            .allocator = allocator,
            .extra = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *PaxAttributes) void {
        if (self.path) |p| self.allocator.free(p);
        if (self.linkpath) |l| self.allocator.free(l);
        if (self.uname) |u| self.allocator.free(u);
        if (self.gname) |g| self.allocator.free(g);
        
        var iter = self.extra.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.extra.deinit();
    }
    
    /// Set an attribute from a key-value pair
    pub fn set(self: *PaxAttributes, key: []const u8, value: []const u8) !void {
        if (PaxKeyword.fromString(key)) |kw| {
            switch (kw) {
                .path => {
                    if (self.path) |p| self.allocator.free(p);
                    self.path = try self.allocator.dupe(u8, value);
                },
                .linkpath => {
                    if (self.linkpath) |l| self.allocator.free(l);
                    self.linkpath = try self.allocator.dupe(u8, value);
                },
                .size => {
                    self.size = std.fmt.parseInt(u64, value, 10) catch null;
                },
                .uid => {
                    self.uid = std.fmt.parseInt(u32, value, 10) catch null;
                },
                .gid => {
                    self.gid = std.fmt.parseInt(u32, value, 10) catch null;
                },
                .uname => {
                    if (self.uname) |u| self.allocator.free(u);
                    self.uname = try self.allocator.dupe(u8, value);
                },
                .gname => {
                    if (self.gname) |g| self.allocator.free(g);
                    self.gname = try self.allocator.dupe(u8, value);
                },
                .mtime => {
                    self.mtime = std.fmt.parseFloat(f64, value) catch null;
                },
                .atime => {
                    self.atime = std.fmt.parseFloat(f64, value) catch null;
                },
                .ctime => {
                    self.ctime = std.fmt.parseFloat(f64, value) catch null;
                },
                else => {},
            }
        } else {
            // Store as vendor extension
            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);
            const value_copy = try self.allocator.dupe(u8, value);
            try self.extra.put(key_copy, value_copy);
        }
    }
};

/// Parse a PAX extended header data block
pub fn parsePaxHeader(allocator: std.mem.Allocator, data: []const u8) !PaxAttributes {
    var attrs = PaxAttributes.init(allocator);
    errdefer attrs.deinit();
    
    var pos: usize = 0;
    while (pos < data.len) {
        // Skip null padding at end
        if (data[pos] == 0) break;
        
        // Format: "length key=value\n"
        // The length includes everything: the length digits, space, key, =, value, and newline
        const remaining = data[pos..];
        
        // Find the space separating length from key
        const space_pos = std.mem.indexOfScalar(u8, remaining, ' ') orelse break;
        const length_str = remaining[0..space_pos];
        const record_len = std.fmt.parseInt(usize, length_str, 10) catch break;
        
        if (record_len == 0 or pos + record_len > data.len) break;
        
        // The record is: "length key=value\n"
        // kv starts after "length " and ends before "\n"
        const kv_start = space_pos + 1;
        const kv_end = record_len - 1; // Exclude the trailing newline
        
        if (kv_end <= kv_start) {
            pos += record_len;
            continue;
        }
        
        const kv = remaining[kv_start..kv_end];
        
        // Split key=value
        if (std.mem.indexOfScalar(u8, kv, '=')) |eq_pos| {
            const key = kv[0..eq_pos];
            const value = kv[eq_pos + 1..];
            try attrs.set(key, value);
        }
        
        pos += record_len;
    }
    
    return attrs;
}

/// Build a PAX extended header data block
pub fn buildPaxHeader(allocator: std.mem.Allocator, attrs: *const PaxAttributes) ![]u8 {
    var records: std.ArrayListUnmanaged(u8) = .{};
    defer records.deinit(allocator);
    
    // Helper to add a record
    const addRecord = struct {
        fn add(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), key: []const u8, value: []const u8) !void {
            // Calculate record length: "len key=value\n"
            // We need to iteratively calculate because length affects itself
            const len: usize = key.len + 1 + value.len + 1; // key=value\n
            var len_digits: usize = 1;
            const temp_len = len + 1; // +1 for space
            
            while (true) {
                const total = temp_len + len_digits;
                const digits = if (total < 10) @as(usize, 1) 
                    else if (total < 100) @as(usize, 2)
                    else if (total < 1000) @as(usize, 3)
                    else if (total < 10000) @as(usize, 4)
                    else @as(usize, 5);
                
                if (digits == len_digits) break;
                len_digits = digits;
            }
            
            const total_len = len + len_digits + 1; // +1 for space
            
            // Format: "length key=value\n"
            var buf: [32]u8 = undefined;
            const len_str = std.fmt.bufPrint(&buf, "{d} ", .{total_len}) catch return;
            try list.appendSlice(alloc, len_str);
            try list.appendSlice(alloc, key);
            try list.append(alloc, '=');
            try list.appendSlice(alloc, value);
            try list.append(alloc, '\n');
        }
    }.add;
    
    if (attrs.path) |p| {
        try addRecord(allocator, &records, "path", p);
    }
    if (attrs.linkpath) |l| {
        try addRecord(allocator, &records, "linkpath", l);
    }
    if (attrs.size) |s| {
        var buf: [32]u8 = undefined;
        const s_str = std.fmt.bufPrint(&buf, "{d}", .{s}) catch "";
        try addRecord(allocator, &records, "size", s_str);
    }
    if (attrs.mtime) |m| {
        var buf: [64]u8 = undefined;
        const m_str = std.fmt.bufPrint(&buf, "{d:.9}", .{m}) catch "";
        try addRecord(allocator, &records, "mtime", m_str);
    }
    if (attrs.uname) |u| {
        try addRecord(allocator, &records, "uname", u);
    }
    if (attrs.gname) |g| {
        try addRecord(allocator, &records, "gname", g);
    }
    
    // Add vendor extensions
    var iter = attrs.extra.iterator();
    while (iter.next()) |entry| {
        try addRecord(allocator, &records, entry.key_ptr.*, entry.value_ptr.*);
    }
    
    return try records.toOwnedSlice(allocator);
}

/// Create a PAX extended header block
pub fn createPaxHeaderBlock(allocator: std.mem.Allocator, data: []const u8, entry_name: []const u8) ![]u8 {
    const data_blocks = tar_header.blocksNeeded(data.len);
    const total_size = BLOCK_SIZE + data_blocks * BLOCK_SIZE;
    
    var result = try allocator.alloc(u8, total_size);
    @memset(result, 0);
    
    // Create the PAX header
    var header: *PosixHeader = @ptrCast(result[0..BLOCK_SIZE]);
    
    // Use a name like "PaxHeader/entry_name" or truncate
    const pax_name = if (entry_name.len <= 90)
        try std.fmt.allocPrint(allocator, "PaxHeader/{s}", .{entry_name})
    else
        try allocator.dupe(u8, "PaxHeader/entry");
    defer allocator.free(pax_name);
    
    header.setName(pax_name[0..@min(pax_name.len, 100)]) catch {};
    header.setTypeFlag(.pax_extended);
    header.setMode(0o644);
    header.setSize(data.len);
    header.setMtime(std.time.timestamp());
    header.setUstarMagic();
    header.setChecksum();
    
    // Copy data after header
    @memcpy(result[BLOCK_SIZE..][0..data.len], data);
    
    return result;
}

/// Check if PAX headers are needed for the given file info
pub fn needsPaxHeaders(name: []const u8, size: u64, linkname: []const u8) bool {
    // Need PAX if:
    // - Filename > 100 chars (and can't use prefix)
    // - Link name > 100 chars
    // - File size > 8GB
    // - Filename contains non-ASCII chars
    
    if (name.len > 100) return true;
    if (linkname.len > 100) return true;
    if (size > tar_header.MAX_OCTAL_VALUE) return true;
    
    // Check for non-ASCII
    for (name) |c| {
        if (c > 127) return true;
    }
    
    return false;
}

test "parsePaxHeader" {
    // PAX format: "length key=value\n" where length includes the length digits themselves
    // "17 path=test.txt\n" = 17 chars: "17" (2) + " " (1) + "path=test.txt" (13) + "\n" (1) = 17
    // "22 mtime=1234567890.5\n" = 22 chars: "22" (2) + " " (1) + "mtime=1234567890.5" (18) + "\n" (1) = 22
    const data = "17 path=test.txt\n22 mtime=1234567890.5\n";
    var attrs = try parsePaxHeader(std.testing.allocator, data);
    defer attrs.deinit();
    
    try std.testing.expectEqualStrings("test.txt", attrs.path.?);
    try std.testing.expectApproxEqAbs(@as(f64, 1234567890.5), attrs.mtime.?, 0.001);
}

test "buildPaxHeader" {
    var attrs = PaxAttributes.init(std.testing.allocator);
    defer attrs.deinit();
    
    attrs.path = try std.testing.allocator.dupe(u8, "test.txt");
    
    const data = try buildPaxHeader(std.testing.allocator, &attrs);
    defer std.testing.allocator.free(data);
    
    try std.testing.expect(std.mem.indexOf(u8, data, "path=test.txt") != null);
}

test "PaxKeyword" {
    try std.testing.expectEqual(PaxKeyword.path, PaxKeyword.fromString("path").?);
    try std.testing.expectEqual(PaxKeyword.mtime, PaxKeyword.fromString("mtime").?);
    try std.testing.expectEqualStrings("path", PaxKeyword.path.toString());
}
