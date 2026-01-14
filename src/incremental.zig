// Incremental backup support for tar-zig
// Implements -g, -G, --listed-incremental options
// Based on GNU tar incremental backup format

const std = @import("std");
const tar_header = @import("tar_header.zig");

const PosixHeader = tar_header.PosixHeader;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;

/// Snapshot file format version
pub const SNAPSHOT_VERSION = "GNU tar-1.32-2";

/// Entry in the snapshot file
pub const SnapshotEntry = struct {
    /// Directory device number
    dev: u64,
    /// Directory inode number
    ino: u64,
    /// Directory name
    name: []const u8,
    /// Modification time (seconds since epoch)
    mtime_sec: i64,
    /// Modification time (nanoseconds)
    mtime_nsec: i64,
    /// List of directory contents at snapshot time
    contents: std.ArrayListUnmanaged([]const u8),
    /// Content status flags (Y=present, N=deleted, D=directory renamed)
    content_flags: std.ArrayListUnmanaged(u8),

    pub fn deinit(self: *SnapshotEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.contents.items) |item| {
            allocator.free(item);
        }
        self.contents.deinit(allocator);
        self.content_flags.deinit(allocator);
    }
};

/// Snapshot file for incremental backups
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    /// Snapshot format version
    version: []const u8,
    /// Time when snapshot was created (seconds)
    time_sec: i64,
    /// Time when snapshot was created (nanoseconds)
    time_nsec: i64,
    /// Directory entries in the snapshot
    entries: std.ArrayListUnmanaged(SnapshotEntry),
    /// Index by directory name for fast lookup
    name_index: std.StringHashMapUnmanaged(usize),

    pub fn init(allocator: std.mem.Allocator) Snapshot {
        return .{
            .allocator = allocator,
            .version = SNAPSHOT_VERSION,
            .time_sec = 0,
            .time_nsec = 0,
            .entries = .{},
            .name_index = .{},
        };
    }

    pub fn deinit(self: *Snapshot) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
        self.name_index.deinit(self.allocator);
    }

    /// Load snapshot from file
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Snapshot {
        var snapshot = Snapshot.init(allocator);
        errdefer snapshot.deinit();

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // New snapshot - start fresh
                const now = std.time.timestamp();
                snapshot.time_sec = now;
                snapshot.time_nsec = 0;
                return snapshot;
            }
            return err;
        };
        defer file.close();

        var reader = file.reader();

        // Read version line
        const version_line = try reader.readUntilDelimiterAlloc(allocator, '\n', 1024);
        defer allocator.free(version_line);

        // Parse version (format: "GNU tar-VERSION-N")
        if (!std.mem.startsWith(u8, version_line, "GNU tar-")) {
            return error.InvalidSnapshotFormat;
        }

        // Read timestamp line (format: "seconds nanoseconds")
        const time_line = try reader.readUntilDelimiterAlloc(allocator, '\n', 256);
        defer allocator.free(time_line);

        var time_iter = std.mem.splitScalar(u8, time_line, ' ');
        if (time_iter.next()) |sec_str| {
            snapshot.time_sec = std.fmt.parseInt(i64, sec_str, 10) catch 0;
        }
        if (time_iter.next()) |nsec_str| {
            snapshot.time_nsec = std.fmt.parseInt(i64, nsec_str, 10) catch 0;
        }

        // Read directory entries
        // Format: nfs dev ino name\0contents...
        while (true) {
            var entry = SnapshotEntry{
                .dev = 0,
                .ino = 0,
                .name = "",
                .mtime_sec = 0,
                .mtime_nsec = 0,
                .contents = .{},
                .content_flags = .{},
            };
            errdefer entry.deinit(allocator);

            // Read entry line until null terminator
            const entry_line = reader.readUntilDelimiterAlloc(allocator, 0, 65536) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            defer allocator.free(entry_line);

            if (entry_line.len == 0) break;

            // Parse entry: "nfs dev ino name"
            var parts = std.mem.splitScalar(u8, entry_line, ' ');
            
            // Skip NFS flag
            _ = parts.next();
            
            // Device number
            if (parts.next()) |dev_str| {
                entry.dev = std.fmt.parseInt(u64, dev_str, 10) catch 0;
            }
            
            // Inode number
            if (parts.next()) |ino_str| {
                entry.ino = std.fmt.parseInt(u64, ino_str, 10) catch 0;
            }
            
            // Remaining is the name
            const rest = parts.rest();
            entry.name = try allocator.dupe(u8, rest);

            // Read mtime line
            const mtime_line = reader.readUntilDelimiterAlloc(allocator, 0, 256) catch "";
            defer if (mtime_line.len > 0) allocator.free(mtime_line);

            if (mtime_line.len > 0) {
                var mtime_parts = std.mem.splitScalar(u8, mtime_line, ' ');
                if (mtime_parts.next()) |sec| {
                    entry.mtime_sec = std.fmt.parseInt(i64, sec, 10) catch 0;
                }
                if (mtime_parts.next()) |nsec| {
                    entry.mtime_nsec = std.fmt.parseInt(i64, nsec, 10) catch 0;
                }
            }

            // Read directory contents (null-separated)
            while (true) {
                const content_name = reader.readUntilDelimiterAlloc(allocator, 0, 65536) catch break;
                if (content_name.len == 0) {
                    allocator.free(content_name);
                    break;
                }
                
                // First char might be a flag (Y, N, D)
                var flag: u8 = 'Y';
                var name = content_name;
                if (content_name.len > 0 and (content_name[0] == 'Y' or content_name[0] == 'N' or content_name[0] == 'D')) {
                    flag = content_name[0];
                    name = try allocator.dupe(u8, content_name[1..]);
                    allocator.free(content_name);
                }
                
                try entry.contents.append(allocator, name);
                try entry.content_flags.append(allocator, flag);
            }

            const idx = snapshot.entries.items.len;
            try snapshot.entries.append(allocator, entry);
            try snapshot.name_index.put(allocator, entry.name, idx);
        }

        return snapshot;
    }

    /// Save snapshot to file
    pub fn save(self: *Snapshot, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var writer = file.writer();

        // Write version
        try writer.print("{s}\n", .{self.version});

        // Write timestamp
        try writer.print("{d} {d}\n", .{ self.time_sec, self.time_nsec });

        // Write directory entries
        for (self.entries.items) |entry| {
            // Write entry header: "nfs dev ino name"
            try writer.print("0 {d} {d} {s}", .{ entry.dev, entry.ino, entry.name });
            try writer.writeByte(0);

            // Write mtime
            try writer.print("{d} {d}", .{ entry.mtime_sec, entry.mtime_nsec });
            try writer.writeByte(0);

            // Write contents
            for (entry.contents.items, entry.content_flags.items) |name, flag| {
                try writer.writeByte(flag);
                try writer.writeAll(name);
                try writer.writeByte(0);
            }

            // End of contents marker
            try writer.writeByte(0);
        }
    }

    /// Look up a directory in the snapshot
    pub fn findDirectory(self: *const Snapshot, name: []const u8) ?*const SnapshotEntry {
        if (self.name_index.get(name)) |idx| {
            return &self.entries.items[idx];
        }
        return null;
    }

    /// Update or add a directory entry
    pub fn updateDirectory(self: *Snapshot, name: []const u8, dev: u64, ino: u64, mtime_sec: i64, mtime_nsec: i64) !*SnapshotEntry {
        if (self.name_index.get(name)) |idx| {
            // Update existing entry
            var entry = &self.entries.items[idx];
            entry.dev = dev;
            entry.ino = ino;
            entry.mtime_sec = mtime_sec;
            entry.mtime_nsec = mtime_nsec;
            // Clear old contents for re-scan
            for (entry.contents.items) |item| {
                self.allocator.free(item);
            }
            entry.contents.clearRetainingCapacity();
            entry.content_flags.clearRetainingCapacity();
            return entry;
        } else {
            // Add new entry
            var entry = SnapshotEntry{
                .dev = dev,
                .ino = ino,
                .name = try self.allocator.dupe(u8, name),
                .mtime_sec = mtime_sec,
                .mtime_nsec = mtime_nsec,
                .contents = .{},
                .content_flags = .{},
            };
            
            const idx = self.entries.items.len;
            try self.entries.append(self.allocator, entry);
            try self.name_index.put(self.allocator, self.entries.items[idx].name, idx);
            return &self.entries.items[idx];
        }
    }

    /// Add a content entry to a directory
    pub fn addContent(self: *Snapshot, entry: *SnapshotEntry, name: []const u8, flag: u8) !void {
        const duped = try self.allocator.dupe(u8, name);
        try entry.contents.append(self.allocator, duped);
        try entry.content_flags.append(self.allocator, flag);
    }
};

/// Check if a file has changed since the last snapshot
pub fn hasFileChanged(snapshot: *const Snapshot, dir_name: []const u8, file_name: []const u8, mtime_sec: i64) bool {
    const entry = snapshot.findDirectory(dir_name) orelse return true;
    
    // Check if file was in the previous snapshot
    for (entry.contents.items, entry.content_flags.items) |name, flag| {
        if (std.mem.eql(u8, name, file_name)) {
            // File existed - check if it's marked as present
            if (flag == 'N') return true; // Was deleted, now exists
            // File existed and is still present - compare times
            return mtime_sec > entry.mtime_sec;
        }
    }
    
    // File is new
    return true;
}

/// Check if a directory has changed since the last snapshot
pub fn hasDirectoryChanged(snapshot: *const Snapshot, dir_name: []const u8, dev: u64, ino: u64, mtime_sec: i64) bool {
    const entry = snapshot.findDirectory(dir_name) orelse return true;
    
    // Check if inode changed (directory was replaced)
    if (entry.dev != dev or entry.ino != ino) return true;
    
    // Check if mtime changed
    return mtime_sec > entry.mtime_sec;
}

/// Dumpdir format for GNU tar incremental backup
/// Format: sequence of null-terminated entries, each prefixed with a type character:
/// 'Y' - file/directory is included
/// 'N' - file/directory existed but was not included (deleted)
/// 'D' - directory was renamed/moved
/// 'R' - file was renamed
pub const DumpdirBuilder = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8),

    pub fn init(allocator: std.mem.Allocator) DumpdirBuilder {
        return .{
            .allocator = allocator,
            .buffer = .{},
        };
    }

    pub fn deinit(self: *DumpdirBuilder) void {
        self.buffer.deinit(self.allocator);
    }

    /// Add an entry to the dumpdir
    pub fn addEntry(self: *DumpdirBuilder, flag: u8, name: []const u8) !void {
        try self.buffer.append(self.allocator, flag);
        try self.buffer.appendSlice(self.allocator, name);
        try self.buffer.append(self.allocator, 0);
    }

    /// Get the final dumpdir data
    pub fn getData(self: *const DumpdirBuilder) []const u8 {
        return self.buffer.items;
    }

    /// Get size including final null terminator
    pub fn getSize(self: *const DumpdirBuilder) usize {
        return self.buffer.items.len + 1; // +1 for final null
    }
};

/// Create a tar header for a directory in incremental mode
/// This includes the dumpdir content as the file data
pub fn createIncrementalDirectoryHeader(
    allocator: std.mem.Allocator,
    dir_name: []const u8,
    dumpdir: *const DumpdirBuilder,
    stat: anytype,
) !PosixHeader {
    _ = allocator;
    
    var header = PosixHeader.init();
    
    // Set name (ensure it ends with /)
    const name_len = @min(dir_name.len, 100);
    @memcpy(header.name[0..name_len], dir_name[0..name_len]);
    
    // Set type flag to directory
    header.setTypeFlag(.directory);
    
    // For incremental backups, directory size is the dumpdir size
    header.setSize(dumpdir.getSize());
    
    header.setMode(@intCast(stat.mode & 0o7777));
    header.setMtime(@intCast(@divFloor(stat.mtime, std.time.ns_per_s)));
    header.setGnuMagic();
    header.setChecksum();
    
    return header;
}

test "snapshot init and deinit" {
    var snapshot = Snapshot.init(std.testing.allocator);
    defer snapshot.deinit();
    
    try std.testing.expectEqual(@as(usize, 0), snapshot.entries.items.len);
}

test "snapshot update directory" {
    var snapshot = Snapshot.init(std.testing.allocator);
    defer snapshot.deinit();
    
    const entry = try snapshot.updateDirectory("/test/dir", 1, 100, 1000, 0);
    try std.testing.expectEqual(@as(u64, 1), entry.dev);
    try std.testing.expectEqual(@as(u64, 100), entry.ino);
    
    // Update should modify existing
    const entry2 = try snapshot.updateDirectory("/test/dir", 2, 200, 2000, 0);
    try std.testing.expectEqual(@as(u64, 2), entry2.dev);
    try std.testing.expectEqual(@as(usize, 1), snapshot.entries.items.len);
}

test "dumpdir builder" {
    var builder = DumpdirBuilder.init(std.testing.allocator);
    defer builder.deinit();
    
    try builder.addEntry('Y', "file1.txt");
    try builder.addEntry('Y', "file2.txt");
    try builder.addEntry('N', "deleted.txt");
    
    const data = builder.getData();
    try std.testing.expect(data.len > 0);
    try std.testing.expectEqual(@as(u8, 'Y'), data[0]);
}

test "hasFileChanged detection" {
    var snapshot = Snapshot.init(std.testing.allocator);
    defer snapshot.deinit();
    
    const entry = try snapshot.updateDirectory("/test", 1, 100, 1000, 0);
    try snapshot.addContent(entry, "existing.txt", 'Y');
    
    // New file should be marked as changed
    try std.testing.expect(hasFileChanged(&snapshot, "/test", "newfile.txt", 500));
    
    // Existing file with older mtime should not be changed
    try std.testing.expect(!hasFileChanged(&snapshot, "/test", "existing.txt", 500));
    
    // Existing file with newer mtime should be changed
    try std.testing.expect(hasFileChanged(&snapshot, "/test", "existing.txt", 2000));
}
