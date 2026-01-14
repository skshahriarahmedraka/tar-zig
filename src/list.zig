const std = @import("std");
const tar_header = @import("tar_header.zig");
const buffer = @import("buffer.zig");
const options = @import("options.zig");
const pax = @import("pax.zig");

const PosixHeader = tar_header.PosixHeader;
const TypeFlag = tar_header.TypeFlag;
const BLOCK_SIZE = tar_header.BLOCK_SIZE;

/// Execute the list (-t) command
pub fn execute(allocator: std.mem.Allocator, opts: options.Options) !void {
    const archive_path = opts.archive_file orelse {
        std.debug.print("tar-zig: No archive file specified\n", .{});
        return error.MissingArchiveFile;
    };

    var reader = try buffer.ArchiveReader.init(allocator, archive_path, opts.compression);
    defer reader.deinit();

    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var header_buf: [BLOCK_SIZE]u8 = undefined;
    var long_name: ?[]u8 = null;
    var pax_attrs: ?pax.PaxAttributes = null;
    defer if (long_name) |n| allocator.free(n);
    defer if (pax_attrs) |*p| p.deinit();

    while (true) {
        const bytes_read = try reader.readBlock(&header_buf);
        if (bytes_read == 0) break;
        if (bytes_read < BLOCK_SIZE) return error.UnexpectedEof;

        const header: *const PosixHeader = @ptrCast(&header_buf);

        // Check for end-of-archive
        if (header.isZeroBlock()) {
            // Read second zero block
            _ = try reader.readBlock(&header_buf);
            break;
        }

        // Verify checksum
        if (!header.verifyChecksum()) {
            std.debug.print("tar-zig: Warning: checksum mismatch\n", .{});
        }

        const type_flag = header.getTypeFlag();
        const size = try header.getSize();

        // Handle GNU long name extension
        if (type_flag == .gnu_long_name) {
            if (long_name) |n| allocator.free(n);
            const raw_name = try allocator.alloc(u8, @intCast(size));
            try reader.readDataToBuffer(size, raw_name);
            // Find actual string length (trim trailing nulls)
            var actual_len: usize = raw_name.len;
            while (actual_len > 0 and raw_name[actual_len - 1] == 0) {
                actual_len -= 1;
            }
            // Create properly sized allocation
            long_name = try allocator.alloc(u8, actual_len);
            @memcpy(long_name.?, raw_name[0..actual_len]);
            allocator.free(raw_name);
            continue;
        }

        // Handle PAX extended headers
        if (type_flag == .pax_extended or type_flag == .pax_global) {
            if (pax_attrs) |*p| p.deinit();
            const pax_data = try allocator.alloc(u8, @intCast(size));
            defer allocator.free(pax_data);
            try reader.readDataToBuffer(size, pax_data);
            pax_attrs = try pax.parsePaxHeader(allocator, pax_data);
            continue;
        }

        // Get filename - prefer PAX path, then GNU long name, then header name
        const name = if (pax_attrs) |*p| blk: {
            if (p.path) |pax_path| {
                defer {
                    p.deinit();
                    pax_attrs = null;
                }
                break :blk try allocator.dupe(u8, pax_path);
            }
            break :blk if (long_name) |n| blk2: {
                defer {
                    allocator.free(n);
                    long_name = null;
                }
                break :blk2 try allocator.dupe(u8, n);
            } else try header.getName(allocator);
        } else if (long_name) |n| blk: {
            defer {
                allocator.free(n);
                long_name = null;
            }
            break :blk try allocator.dupe(u8, n);
        } else try header.getName(allocator);
        defer allocator.free(name);

        // Check if this file matches the filter (if any)
        if (opts.files.items.len > 0) {
            var matches = false;
            for (opts.files.items) |pattern| {
                if (matchesPattern(name, pattern)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) {
                // Skip this entry
                if (size > 0) {
                    const blocks = tar_header.blocksNeeded(size);
                    try reader.skipBlocks(blocks);
                }
                continue;
            }
        }

        // Output based on verbosity
        if (opts.verbosity == .verbose or opts.verbosity == .very_verbose) {
            try printVerbose(allocator, stdout, header, name, opts);
        } else {
            try stdout.writeAll(name);
            try stdout.writeAll("\n");
        }

        // Skip file data
        if (size > 0) {
            const blocks = tar_header.blocksNeeded(size);
            try reader.skipBlocks(blocks);
        }
    }
}

/// Print verbose listing (like ls -l)
fn printVerbose(allocator: std.mem.Allocator, file: std.fs.File, header: *const PosixHeader, name: []const u8, opts: options.Options) !void {
    const type_flag = header.getTypeFlag();
    const mode = header.getMode() catch 0;
    const size = header.getSize() catch 0;
    const mtime = header.getMtime() catch 0;
    const uid = header.getUid() catch 0;
    const gid = header.getGid() catch 0;
    const uname_field = header.getUname();
    const gname_field = header.getGname();

    // Type character
    const type_char: u8 = switch (type_flag) {
        .directory => 'd',
        .symbolic_link => 'l',
        .hard_link => 'h',
        .character_device => 'c',
        .block_device => 'b',
        .fifo => 'p',
        else => '-',
    };

    // Permission string
    var perms: [9]u8 = undefined;
    perms[0] = if (mode & 0o400 != 0) 'r' else '-';
    perms[1] = if (mode & 0o200 != 0) 'w' else '-';
    perms[2] = if (mode & 0o100 != 0) 'x' else '-';
    perms[3] = if (mode & 0o040 != 0) 'r' else '-';
    perms[4] = if (mode & 0o020 != 0) 'w' else '-';
    perms[5] = if (mode & 0o010 != 0) 'x' else '-';
    perms[6] = if (mode & 0o004 != 0) 'r' else '-';
    perms[7] = if (mode & 0o002 != 0) 'w' else '-';
    perms[8] = if (mode & 0o001 != 0) 'x' else '-';

    // Format timestamp
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();

    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const month_day = year_day.calculateMonthDay();
    const month_name = months[@intFromEnum(month_day.month) - 1];

    // Format owner/group based on --numeric-owner option
    if (opts.numeric_owner) {
        // Use numeric UID/GID
        const line = try std.fmt.allocPrint(allocator, "{c}{s} {d: <8}/{d: <8} {d: >10} {s} {d:0>2} {d:0>2}:{d:0>2} {s}", .{
            type_char,
            perms,
            uid,
            gid,
            size,
            month_name,
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            name,
        });
        defer allocator.free(line);
        try file.writeAll(line);
    } else {
        // Use names (or numeric if names not available)
        const owner = if (uname_field.len > 0) uname_field else "unknown";
        const group = if (gname_field.len > 0) gname_field else "unknown";

        const line = try std.fmt.allocPrint(allocator, "{c}{s} {s: <8}/{s: <8} {d: >10} {s} {d:0>2} {d:0>2}:{d:0>2} {s}", .{
            type_char,
            perms,
            owner,
            group,
            size,
            month_name,
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            name,
        });
        defer allocator.free(line);
        try file.writeAll(line);
    }

    // Print link target for symlinks
    if (type_flag == .symbolic_link) {
        const linkname = header.getLinkname();
        try file.writeAll(" -> ");
        try file.writeAll(linkname);
    }

    try file.writeAll("\n");
}

/// Check if a filename matches a pattern (simple prefix matching for now)
fn matchesPattern(name: []const u8, pattern: []const u8) bool {
    // Exact match
    if (std.mem.eql(u8, name, pattern)) return true;

    // Pattern is a prefix (for directory matching)
    if (std.mem.startsWith(u8, name, pattern)) {
        if (pattern.len < name.len and name[pattern.len] == '/') {
            return true;
        }
    }

    // Name starts with pattern
    if (std.mem.startsWith(u8, name, pattern)) {
        return true;
    }

    return false;
}

test "matchesPattern" {
    try std.testing.expect(matchesPattern("foo/bar.txt", "foo"));
    try std.testing.expect(matchesPattern("foo/bar.txt", "foo/bar.txt"));
    try std.testing.expect(matchesPattern("foo/bar.txt", "foo/"));
    try std.testing.expect(!matchesPattern("foo/bar.txt", "baz"));
}
