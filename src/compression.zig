const std = @import("std");
const options = @import("options.zig");

/// Get the compression program name for a given compression type
pub fn getCompressionProgram(compression: options.Compression) ?[]const u8 {
    return switch (compression) {
        .gzip => "gzip",
        .bzip2 => "bzip2",
        .xz => "xz",
        .zstd => "zstd",
        .none, .auto => null,
    };
}

/// Get the decompression program name for a given compression type
pub fn getDecompressionProgram(compression: options.Compression) ?[]const u8 {
    return switch (compression) {
        .gzip => "gzip",
        .bzip2 => "bzip2",
        .xz => "xz",
        .zstd => "zstd",
        .none, .auto => null,
    };
}

/// Get decompression arguments
pub fn getDecompressionArgs(compression: options.Compression) []const []const u8 {
    return switch (compression) {
        .gzip => &[_][]const u8{ "gzip", "-d", "-c" },
        .bzip2 => &[_][]const u8{ "bzip2", "-d", "-c" },
        .xz => &[_][]const u8{ "xz", "-d", "-c" },
        .zstd => &[_][]const u8{ "zstd", "-d", "-c" },
        .none, .auto => &[_][]const u8{},
    };
}

/// Get compression arguments
pub fn getCompressionArgs(compression: options.Compression) []const []const u8 {
    return switch (compression) {
        .gzip => &[_][]const u8{ "gzip", "-c" },
        .bzip2 => &[_][]const u8{ "bzip2", "-c" },
        .xz => &[_][]const u8{ "xz", "-c" },
        .zstd => &[_][]const u8{ "zstd", "-c" },
        .none, .auto => &[_][]const u8{},
    };
}

/// Compressed file reader - reads from a file through a decompression process
pub const CompressedReader = struct {
    allocator: std.mem.Allocator,
    process: std.process.Child,
    stdout_file: std.fs.File,
    input_file: std.fs.File,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, compression: options.Compression) !CompressedReader {
        const args = getDecompressionArgs(compression);
        if (args.len == 0) return error.InvalidCompression;

        // Open the input file
        const input_file = try std.fs.cwd().openFile(path, .{});
        errdefer input_file.close();

        // We need to use a different approach: spawn process with stdin from file
        // Create argument list with input file
        var argv: std.ArrayListUnmanaged([]const u8) = .{};
        defer argv.deinit(allocator);
        for (args) |arg| {
            try argv.append(allocator, arg);
        }
        try argv.append(allocator, path);

        // Spawn decompression process
        var process = std.process.Child.init(argv.items, allocator);
        process.stdin_behavior = .Ignore;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Inherit;

        try process.spawn();

        return CompressedReader{
            .allocator = allocator,
            .process = process,
            .stdout_file = process.stdout.?,
            .input_file = input_file,
        };
    }

    pub fn deinit(self: *CompressedReader) void {
        _ = self.process.wait() catch {};
        self.input_file.close();
    }

    pub fn readAll(self: *CompressedReader, buffer: []u8) !usize {
        return self.stdout_file.readAll(buffer);
    }

    pub fn read(self: *CompressedReader, buffer: []u8) !usize {
        return self.stdout_file.read(buffer);
    }
};

/// Compressed file writer - writes to a file through a compression process
pub const CompressedWriter = struct {
    allocator: std.mem.Allocator,
    process: std.process.Child,
    stdin_file: ?std.fs.File,
    output_file: std.fs.File,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, compression: options.Compression) !CompressedWriter {
        const args = getCompressionArgs(compression);
        if (args.len == 0) return error.InvalidCompression;

        // Create the output file
        const output_file = try std.fs.cwd().createFile(path, .{});
        errdefer output_file.close();

        // Spawn compression process - it reads from stdin, we'll redirect stdout to file
        var process = std.process.Child.init(args, allocator);
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;  // We'll manually redirect
        process.stderr_behavior = .Inherit;

        try process.spawn();

        return CompressedWriter{
            .allocator = allocator,
            .process = process,
            .stdin_file = process.stdin,
            .output_file = output_file,
        };
    }

    pub fn deinit(self: *CompressedWriter) void {
        self.output_file.close();
    }

    pub fn writeAll(self: *CompressedWriter, data: []const u8) !void {
        if (self.stdin_file) |f| {
            try f.writeAll(data);
        }
    }

    pub fn finish(self: *CompressedWriter) !void {
        if (self.finished) return;
        self.finished = true;
        
        // Close stdin to signal EOF to compressor
        if (self.stdin_file) |f| {
            f.close();
            self.stdin_file = null;
            // Also clear the process's reference so it doesn't double-close
            self.process.stdin = null;
        }
        
        // Read compressed output and write to file
        var buf: [8192]u8 = undefined;
        if (self.process.stdout) |stdout| {
            while (true) {
                const n = try stdout.read(&buf);
                if (n == 0) break;
                try self.output_file.writeAll(buf[0..n]);
            }
        }
        
        // Wait for process to complete
        const result = try self.process.wait();
        if (result.Exited != 0) {
            return error.CompressionFailed;
        }
    }
};

/// Detect compression type from file magic bytes
pub fn detectCompressionFromMagic(file: std.fs.File) !options.Compression {
    var magic: [6]u8 = undefined;
    const bytes_read = try file.readAll(&magic);
    
    // Seek back to start
    try file.seekTo(0);
    
    if (bytes_read < 2) return .none;
    
    // Gzip: 1f 8b
    if (magic[0] == 0x1f and magic[1] == 0x8b) {
        return .gzip;
    }
    
    // Bzip2: 42 5a 68 ('BZh')
    if (bytes_read >= 3 and magic[0] == 0x42 and magic[1] == 0x5a and magic[2] == 0x68) {
        return .bzip2;
    }
    
    // XZ: fd 37 7a 58 5a 00
    if (bytes_read >= 6 and magic[0] == 0xfd and magic[1] == 0x37 and magic[2] == 0x7a and 
        magic[3] == 0x58 and magic[4] == 0x5a and magic[5] == 0x00) {
        return .xz;
    }
    
    // Zstd: 28 b5 2f fd
    if (bytes_read >= 4 and magic[0] == 0x28 and magic[1] == 0xb5 and magic[2] == 0x2f and magic[3] == 0xfd) {
        return .zstd;
    }
    
    return .none;
}

test "getCompressionProgram" {
    try std.testing.expectEqualStrings("gzip", getCompressionProgram(.gzip).?);
    try std.testing.expectEqualStrings("bzip2", getCompressionProgram(.bzip2).?);
    try std.testing.expectEqualStrings("xz", getCompressionProgram(.xz).?);
    try std.testing.expectEqualStrings("zstd", getCompressionProgram(.zstd).?);
    try std.testing.expectEqual(@as(?[]const u8, null), getCompressionProgram(.none));
}
