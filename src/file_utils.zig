const std = @import("std");

/// Create a directory, ignoring if it already exists
pub fn createDirectory(path: []const u8) !void {
    std.fs.cwd().makeDir(path) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };
}

/// Create directories recursively (like mkdir -p)
pub fn createDirectoryRecursive(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };
}

/// Create a symbolic link
pub fn createSymlink(target: []const u8, link_path: []const u8) !void {
    // Create parent directories if needed
    if (std.fs.path.dirname(link_path)) |dir| {
        try createDirectoryRecursive(dir);
    }

    // Remove existing file/link if present
    std.fs.cwd().deleteFile(link_path) catch {};

    std.fs.cwd().symLink(target, link_path, .{}) catch |err| {
        std.debug.print("tar-zig: Cannot create symlink {s} -> {s}: {}\n", .{ link_path, target, err });
        return err;
    };
}

/// Create a hard link
pub fn createHardlink(target: []const u8, link_path: []const u8) !void {
    // Create parent directories if needed
    if (std.fs.path.dirname(link_path)) |dir| {
        try createDirectoryRecursive(dir);
    }

    // Remove existing file/link if present
    std.fs.cwd().deleteFile(link_path) catch {};

    // In Zig, we use the low-level API for hard links
    const cwd = std.fs.cwd();
    const target_z = try std.posix.toPosixPath(target);
    const link_z = try std.posix.toPosixPath(link_path);

    std.posix.linkat(cwd.fd, &target_z, cwd.fd, &link_z, 0) catch |err| {
        std.debug.print("tar-zig: Cannot create hardlink {s} -> {s}: {}\n", .{ link_path, target, err });
        return err;
    };
}

/// Set file permissions
pub fn setPermissions(path: []const u8, mode: u32) !void {
    // Find actual string length (exclude any null bytes)
    var actual_len = path.len;
    for (path, 0..) |c, i| {
        if (c == 0) {
            actual_len = i;
            break;
        }
    }
    const clean_path = path[0..actual_len];
    
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (clean_path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..clean_path.len], clean_path);
    path_buf[clean_path.len] = 0;
    
    std.posix.fchmodat(std.fs.cwd().fd, path_buf[0..clean_path.len :0], @intCast(mode), 0) catch |err| {
        // Ignore permission errors for symlinks
        if (err != error.OperationNotSupported) {
            return err;
        }
    };
}

/// Set file modification time
pub fn setModificationTime(path: []const u8, mtime: i64) !void {
    _ = path;
    _ = mtime;
    // Note: File time setting API changed in Zig 0.15
    // For now, skip setting modification time
    // TODO: Use utimensat or similar syscall directly
}

/// Get file information
pub const FileInfo = struct {
    size: u64,
    mode: u32,
    mtime: i64,
    kind: std.fs.File.Kind,
    uid: u32,
    gid: u32,
};

pub fn getFileInfo(path: []const u8) !FileInfo {
    const stat = try std.fs.cwd().statFile(path);
    return FileInfo{
        .size = stat.size,
        .mode = @intCast(stat.mode & 0o7777),
        .mtime = @intCast(@divFloor(stat.mtime, std.time.ns_per_s)),
        .kind = stat.kind,
        .uid = 0, // Would need platform-specific code
        .gid = 0,
    };
}

test "createDirectoryRecursive" {
    // Create a nested directory structure
    const test_path = "tmp_rovodev_test_dir/nested/path";
    try createDirectoryRecursive(test_path);

    // Verify it exists
    var dir = try std.fs.cwd().openDir(test_path, .{});
    dir.close();

    // Cleanup
    std.fs.cwd().deleteTree("tmp_rovodev_test_dir") catch {};
}
