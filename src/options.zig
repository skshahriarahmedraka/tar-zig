const std = @import("std");

/// Main operation mode
pub const Operation = enum {
    none,
    create,   // -c
    extract,  // -x
    list,     // -t
    append,   // -r
    update,   // -u
    diff,     // -d, --diff, --compare
    delete,   // --delete
};

/// Verbosity level
pub const Verbosity = enum(u8) {
    quiet = 0,
    normal = 1,
    verbose = 2,      // -v
    very_verbose = 3, // -vv
};

/// Compression method
pub const Compression = enum {
    none,
    gzip,   // -z
    bzip2,  // -j
    xz,     // -J
    zstd,   // --zstd
    auto,   // -a (detect from extension)
};

/// Parsed command-line options
pub const Options = struct {
    allocator: std.mem.Allocator,
    operation: Operation = .none,
    archive_file: ?[]const u8 = null,
    files: std.ArrayListUnmanaged([]const u8) = .{},
    verbosity: Verbosity = .normal,
    compression: Compression = .none,
    directory: ?[]const u8 = null,
    keep_old_files: bool = false,
    strip_components: u32 = 0,
    preserve_permissions: bool = true,
    dereference: bool = false,

    pub fn init(allocator: std.mem.Allocator) Options {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Options) void {
        self.files.deinit(self.allocator);
    }
};

pub const ParseError = error{
    HelpRequested,
    VersionRequested,
    InvalidOption,
    MissingArchiveFile,
    OutOfMemory,
};

/// Parse command-line arguments
pub fn parseArgs(allocator: std.mem.Allocator) ParseError!Options {
    var opts = Options.init(allocator);
    errdefer opts.deinit();

    var args = std.process.args();
    _ = args.skip(); // Skip program name

    var parsing_options = true;

    while (args.next()) |arg| {
        if (parsing_options and arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--")) {
                parsing_options = false;
                continue;
            }

            if (arg.len > 1 and arg[1] == '-') {
                // Long option
                try parseLongOption(&opts, arg[2..], &args);
            } else {
                // Short options (can be combined: -cvf)
                try parseShortOptions(&opts, arg[1..], &args);
            }
        } else {
            // Positional argument (file to archive/extract)
            opts.files.append(opts.allocator, arg) catch return error.OutOfMemory;
        }
    }

    return opts;
}

fn parseLongOption(opts: *Options, option: []const u8, args: *std.process.ArgIterator) ParseError!void {
    if (std.mem.eql(u8, option, "help")) {
        printUsage() catch {};
        return error.HelpRequested;
    } else if (std.mem.eql(u8, option, "version")) {
        printVersion() catch {};
        return error.VersionRequested;
    } else if (std.mem.eql(u8, option, "create")) {
        opts.operation = .create;
    } else if (std.mem.eql(u8, option, "extract") or std.mem.eql(u8, option, "get")) {
        opts.operation = .extract;
    } else if (std.mem.eql(u8, option, "list")) {
        opts.operation = .list;
    } else if (std.mem.eql(u8, option, "append")) {
        opts.operation = .append;
    } else if (std.mem.eql(u8, option, "update")) {
        opts.operation = .update;
    } else if (std.mem.eql(u8, option, "diff") or std.mem.eql(u8, option, "compare")) {
        opts.operation = .diff;
    } else if (std.mem.eql(u8, option, "delete")) {
        opts.operation = .delete;
    } else if (std.mem.eql(u8, option, "verbose")) {
        opts.verbosity = if (opts.verbosity == .verbose) .very_verbose else .verbose;
    } else if (std.mem.eql(u8, option, "gzip") or std.mem.eql(u8, option, "gunzip")) {
        opts.compression = .gzip;
    } else if (std.mem.eql(u8, option, "bzip2")) {
        opts.compression = .bzip2;
    } else if (std.mem.eql(u8, option, "xz")) {
        opts.compression = .xz;
    } else if (std.mem.eql(u8, option, "zstd")) {
        opts.compression = .zstd;
    } else if (std.mem.eql(u8, option, "auto-compress")) {
        opts.compression = .auto;
    } else if (std.mem.eql(u8, option, "keep-old-files")) {
        opts.keep_old_files = true;
    } else if (std.mem.eql(u8, option, "dereference")) {
        opts.dereference = true;
    } else if (std.mem.startsWith(u8, option, "file=")) {
        opts.archive_file = option[5..];
    } else if (std.mem.startsWith(u8, option, "directory=")) {
        opts.directory = option[10..];
    } else if (std.mem.startsWith(u8, option, "strip-components=")) {
        const num_str = option[17..];
        opts.strip_components = std.fmt.parseInt(u32, num_str, 10) catch 0;
    } else if (std.mem.eql(u8, option, "file")) {
        opts.archive_file = args.next();
    } else if (std.mem.eql(u8, option, "directory")) {
        opts.directory = args.next();
    } else {
        std.debug.print("tar-zig: Unknown option --{s}\n", .{option});
        return error.InvalidOption;
    }
}

fn parseShortOptions(opts: *Options, options_str: []const u8, args: *std.process.ArgIterator) ParseError!void {
    var i: usize = 0;
    while (i < options_str.len) : (i += 1) {
        const c = options_str[i];
        switch (c) {
            'c' => opts.operation = .create,
            'x' => opts.operation = .extract,
            't' => opts.operation = .list,
            'r' => opts.operation = .append,
            'u' => opts.operation = .update,
            'd' => opts.operation = .diff,
            'v' => opts.verbosity = if (opts.verbosity == .verbose) .very_verbose else .verbose,
            'z' => opts.compression = .gzip,
            'j' => opts.compression = .bzip2,
            'J' => opts.compression = .xz,
            'a' => opts.compression = .auto,
            'h' => opts.dereference = true,
            'k' => opts.keep_old_files = true,
            'f' => {
                // -f can be followed by filename in same arg or next arg
                if (i + 1 < options_str.len) {
                    opts.archive_file = options_str[i + 1 ..];
                    return; // Rest of options is the filename
                } else {
                    opts.archive_file = args.next();
                }
            },
            'C' => {
                if (i + 1 < options_str.len) {
                    opts.directory = options_str[i + 1 ..];
                    return;
                } else {
                    opts.directory = args.next();
                }
            },
            else => {
                std.debug.print("tar-zig: Unknown option -{c}\n", .{c});
                return error.InvalidOption;
            },
        }
    }
}

pub fn printUsage() !void {
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll(
        \\Usage: tar-zig [OPTION]... [FILE]...
        \\
        \\tar-zig: A tar implementation in Zig
        \\
        \\Main operation mode:
        \\  -c, --create          Create a new archive
        \\  -x, --extract, --get  Extract files from an archive
        \\  -t, --list            List the contents of an archive
        \\  -r, --append          Append files to the end of an archive
        \\  -u, --update          Only append files newer than archive copy
        \\  -d, --diff, --compare Find differences between archive and filesystem
        \\      --delete          Delete from the archive
        \\
        \\Common options:
        \\  -f, --file=ARCHIVE    Use archive file ARCHIVE
        \\  -v, --verbose         Verbosely list files processed
        \\  -C, --directory=DIR   Change to directory DIR
        \\
        \\Compression options:
        \\  -z, --gzip            Filter archive through gzip
        \\  -j, --bzip2           Filter archive through bzip2
        \\  -J, --xz              Filter archive through xz
        \\      --zstd            Filter archive through zstd
        \\  -a, --auto-compress   Use archive suffix to determine compression
        \\
        \\Other options:
        \\  -h, --dereference     Follow symlinks
        \\  -k, --keep-old-files  Don't replace existing files
        \\      --strip-components=N  Strip N leading path components
        \\      --help             Display this help and exit
        \\      --version          Display version information and exit
        \\
        \\Examples:
        \\  tar-zig -cvf archive.tar file1 file2   Create archive from files
        \\  tar-zig -tvf archive.tar               List archive contents
        \\  tar-zig -xvf archive.tar               Extract archive
        \\  tar-zig -czvf archive.tar.gz dir/      Create gzip compressed archive
        \\  tar-zig -rvf archive.tar newfile.txt   Append file to archive
        \\  tar-zig -uvf archive.tar dir/          Update newer files
        \\  tar-zig -dvf archive.tar               Compare archive with filesystem
        \\  tar-zig --delete -f archive.tar file   Delete file from archive
        \\
    );
}

pub fn printVersion() !void {
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll("tar-zig 0.1.0\n");
    try stdout.writeAll("A tar implementation written in Zig\n");
}

test "parseArgs basic" {
    // Basic test - just ensure the structure works
    var opts = Options.init(std.testing.allocator);
    defer opts.deinit();

    try std.testing.expectEqual(Operation.none, opts.operation);
}
