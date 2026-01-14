const std = @import("std");

/// Main operation mode
pub const Operation = enum {
    none,
    create,      // -c
    extract,     // -x
    list,        // -t
    append,      // -r
    update,      // -u
    diff,        // -d, --diff, --compare
    delete,      // --delete
    concatenate, // -A, --catenate, --concatenate
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

/// Overwrite mode for extraction
pub const OverwriteMode = enum {
    overwrite,         // default: overwrite existing files
    keep_old_files,    // -k: don't replace existing files (error)
    keep_newer_files,  // --keep-newer-files: don't replace newer files
    skip_old_files,    // --skip-old-files: silently skip existing
    unlink_first,      // -U: remove files before extracting
};

/// Archive format
pub const ArchiveFormat = enum {
    gnu,       // GNU tar 1.13.x format (default)
    oldgnu,    // GNU format as per tar <= 1.12
    pax,       // POSIX 1003.1-2001 (pax) format
    ustar,     // POSIX 1003.1-1988 (ustar) format
    v7,        // Old V7 tar format
    
    pub fn fromString(s: []const u8) ?ArchiveFormat {
        if (std.mem.eql(u8, s, "gnu")) return .gnu;
        if (std.mem.eql(u8, s, "oldgnu")) return .oldgnu;
        if (std.mem.eql(u8, s, "pax") or std.mem.eql(u8, s, "posix")) return .pax;
        if (std.mem.eql(u8, s, "ustar")) return .ustar;
        if (std.mem.eql(u8, s, "v7")) return .v7;
        return null;
    }
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
    strip_components: u32 = 0,
    preserve_permissions: bool = true,
    dereference: bool = false,

    // Overwrite control
    overwrite_mode: OverwriteMode = .overwrite,
    keep_old_files: bool = false, // kept for backward compatibility

    // Output control
    to_stdout: bool = false,           // -O, --to-stdout

    // File selection
    exclude_patterns: std.ArrayListUnmanaged([]const u8) = .{},  // --exclude
    files_from: ?[]const u8 = null,    // -T, --files-from
    exclude_from: ?[]const u8 = null,  // -X, --exclude-from
    null_terminated: bool = false,     // --null

    // Path handling
    absolute_names: bool = false,      // -P, --absolute-names

    // File attributes
    touch: bool = false,               // -m, --touch (don't extract mtime)
    numeric_owner: bool = false,       // --numeric-owner

    // Archive reading
    ignore_zeros: bool = false,        // -i, --ignore-zeros

    // Sparse file handling
    sparse: bool = false,              // -S, --sparse

    // Name transformation
    transforms: std.ArrayListUnmanaged([]const u8) = .{},  // --transform

    // Archive format
    format: ArchiveFormat = .gnu,      // -H, --format

    // Blocking factor
    blocking_factor: u32 = 20,         // -b, --blocking-factor (default 20 = 10KB)

    // Phase 2 options
    one_file_system: bool = false,     // --one-file-system (stay on one filesystem)
    newer_mtime: ?i64 = null,          // -N, --newer (only files newer than DATE)
    newer_file: ?[]const u8 = null,    // --newer-mtime (reference file for --newer)
    remove_files: bool = false,        // --remove-files (remove after adding)
    verify: bool = false,              // -W, --verify (verify after writing)
    checkpoint: ?u32 = null,           // --checkpoint[=N] (display progress every N records)
    checkpoint_action: ?[]const u8 = null, // --checkpoint-action=ACTION

    // Phase 3 options - Incremental backups
    listed_incremental: ?[]const u8 = null,  // -g, --listed-incremental=FILE
    incremental: bool = false,               // -G, --incremental (old GNU format)
    level: ?u32 = null,                      // --level=N (incremental backup level)

    // Phase 3 options - Multi-volume archives
    multi_volume: bool = false,              // -M, --multi-volume
    tape_length: ?u64 = null,                // -L, --tape-length=N (volume size in KB)
    volno_file: ?[]const u8 = null,          // --volno-file=FILE
    new_volume_script: ?[]const u8 = null,   // -F, --info-script=COMMAND

    // Phase 3 options - Extended attributes
    xattrs: bool = false,                    // --xattrs
    xattrs_include: std.ArrayListUnmanaged([]const u8) = .{},  // --xattrs-include=PATTERN
    xattrs_exclude: std.ArrayListUnmanaged([]const u8) = .{},  // --xattrs-exclude=PATTERN
    acls: bool = false,                      // --acls (POSIX ACLs)
    selinux: bool = false,                   // --selinux (SELinux context)
    no_xattrs: bool = false,                 // --no-xattrs
    no_acls: bool = false,                   // --no-acls
    no_selinux: bool = false,                // --no-selinux

    // Owned strings that need to be freed
    owned_strings: std.ArrayListUnmanaged([]const u8) = .{},

    pub fn init(allocator: std.mem.Allocator) Options {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Options) void {
        self.files.deinit(self.allocator);
        self.exclude_patterns.deinit(self.allocator);
        self.transforms.deinit(self.allocator);
        self.xattrs_include.deinit(self.allocator);
        self.xattrs_exclude.deinit(self.allocator);
        for (self.owned_strings.items) |s| {
            self.allocator.free(s);
        }
        self.owned_strings.deinit(self.allocator);
    }

    /// Check if a path matches any exclude pattern
    pub fn isExcluded(self: *const Options, path: []const u8) bool {
        for (self.exclude_patterns.items) |pattern| {
            if (matchExcludePattern(path, pattern)) {
                return true;
            }
        }
        return false;
    }
};

/// Match a path against an exclude pattern (supports basic wildcards)
fn matchExcludePattern(path: []const u8, pattern: []const u8) bool {
    // Exact match
    if (std.mem.eql(u8, path, pattern)) return true;

    // Check if pattern matches the basename
    const basename = std.fs.path.basename(path);
    if (std.mem.eql(u8, basename, pattern)) return true;

    // Simple wildcard matching
    if (std.mem.indexOf(u8, pattern, "*")) |star_pos| {
        const prefix = pattern[0..star_pos];
        const suffix = pattern[star_pos + 1 ..];

        // Match against full path
        if (std.mem.startsWith(u8, path, prefix)) {
            if (suffix.len == 0) return true;
            if (std.mem.endsWith(u8, path, suffix)) return true;
        }

        // Match against basename
        if (std.mem.startsWith(u8, basename, prefix)) {
            if (suffix.len == 0) return true;
            if (std.mem.endsWith(u8, basename, suffix)) return true;
        }
    }

    // Directory prefix match (pattern without trailing slash matches dir contents)
    if (std.mem.startsWith(u8, path, pattern)) {
        if (pattern.len < path.len and path[pattern.len] == '/') {
            return true;
        }
    }

    return false;
}

pub const ParseError = error{
    HelpRequested,
    VersionRequested,
    InvalidOption,
    MissingArchiveFile,
    OutOfMemory,
};

/// Parse a date string into a Unix timestamp
/// Supports formats:
/// - Unix timestamp (integer)
/// - YYYY-MM-DD
/// - YYYY-MM-DD HH:MM:SS
/// - Reference to a file path (uses file's mtime)
fn parseDateString(date_str: []const u8) !i64 {
    // Try parsing as Unix timestamp first
    if (std.fmt.parseInt(i64, date_str, 10)) |timestamp| {
        return timestamp;
    } else |_| {}

    // Try parsing as YYYY-MM-DD or YYYY-MM-DD HH:MM:SS
    if (date_str.len >= 10 and date_str[4] == '-' and date_str[7] == '-') {
        const year = std.fmt.parseInt(i32, date_str[0..4], 10) catch return error.InvalidOption;
        const month = std.fmt.parseInt(u32, date_str[5..7], 10) catch return error.InvalidOption;
        const day = std.fmt.parseInt(u32, date_str[8..10], 10) catch return error.InvalidOption;

        var hour: u32 = 0;
        var minute: u32 = 0;
        var second: u32 = 0;

        // Parse time if present (YYYY-MM-DD HH:MM:SS)
        if (date_str.len >= 19 and date_str[10] == ' ' and date_str[13] == ':' and date_str[16] == ':') {
            hour = std.fmt.parseInt(u32, date_str[11..13], 10) catch return error.InvalidOption;
            minute = std.fmt.parseInt(u32, date_str[14..16], 10) catch return error.InvalidOption;
            second = std.fmt.parseInt(u32, date_str[17..19], 10) catch return error.InvalidOption;
        }

        // Calculate days since epoch (simplified calculation)
        // Using a simplified algorithm for date to epoch conversion
        const days = calculateDaysSinceEpoch(year, month, day);
        const timestamp: i64 = days * 86400 + @as(i64, @intCast(hour)) * 3600 + @as(i64, @intCast(minute)) * 60 + @as(i64, @intCast(second));
        return timestamp;
    }

    // Try treating it as a file path and use its mtime
    const stat = std.fs.cwd().statFile(date_str) catch return error.InvalidOption;
    return @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
}

/// Calculate days since Unix epoch (1970-01-01)
fn calculateDaysSinceEpoch(year: i32, month: u32, day: u32) i64 {
    // Adjust for months before March (Jan, Feb treated as 13, 14 of previous year)
    var y = year;
    var m = month;
    if (m <= 2) {
        y -= 1;
        m += 12;
    }
    
    // Calculate days using a modified Julian Day algorithm
    const a = @divFloor(y, 100);
    const b = 2 - a + @divFloor(a, 4);
    
    const jd = @as(i64, @intFromFloat(@floor(365.25 * @as(f64, @floatFromInt(y + 4716))))) +
               @as(i64, @intFromFloat(@floor(30.6001 * @as(f64, @floatFromInt(m + 1))))) +
               @as(i64, @intCast(day)) + b - 1524;
    
    // Unix epoch is Julian Day 2440588
    return jd - 2440588;
}

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

    // Load files from -T/--files-from if specified
    if (opts.files_from) |files_from_path| {
        try loadFilesFrom(&opts, files_from_path);
    }

    // Load exclude patterns from -X/--exclude-from if specified
    if (opts.exclude_from) |exclude_from_path| {
        try loadExcludeFrom(&opts, exclude_from_path);
    }

    return opts;
}

/// Load file names from a file (-T, --files-from)
fn loadFilesFrom(opts: *Options, path: []const u8) ParseError!void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("tar-zig: {s}: Cannot open: {}\n", .{ path, err });
        return error.InvalidOption;
    };
    defer file.close();

    const delimiter: u8 = if (opts.null_terminated) 0 else '\n';

    // Read entire file content
    const content = file.readToEndAlloc(opts.allocator, 1024 * 1024 * 10) catch return error.OutOfMemory;
    opts.owned_strings.append(opts.allocator, content) catch return error.OutOfMemory;

    // Split by delimiter
    var iter = std.mem.splitScalar(u8, content, delimiter);
    while (iter.next()) |line| {
        // Skip empty lines
        if (line.len == 0) continue;

        // Trim trailing carriage return if present (for Windows line endings)
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;

        if (trimmed.len == 0) continue;

        opts.files.append(opts.allocator, trimmed) catch return error.OutOfMemory;
    }
}

/// Load exclude patterns from a file (-X, --exclude-from)
fn loadExcludeFrom(opts: *Options, path: []const u8) ParseError!void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("tar-zig: {s}: Cannot open: {}\n", .{ path, err });
        return error.InvalidOption;
    };
    defer file.close();

    // Read entire file content
    const content = file.readToEndAlloc(opts.allocator, 1024 * 1024 * 10) catch return error.OutOfMemory;
    opts.owned_strings.append(opts.allocator, content) catch return error.OutOfMemory;

    // Split by newline
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        // Skip empty lines and comments
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // Trim trailing carriage return if present
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;

        if (trimmed.len == 0) continue;

        opts.exclude_patterns.append(opts.allocator, trimmed) catch return error.OutOfMemory;
    }
}

fn parseLongOption(opts: *Options, option: []const u8, args: *std.process.ArgIterator) ParseError!void {
    // Help and version
    if (std.mem.eql(u8, option, "help")) {
        printUsage() catch {};
        return error.HelpRequested;
    } else if (std.mem.eql(u8, option, "version")) {
        printVersion() catch {};
        return error.VersionRequested;
    } else if (std.mem.eql(u8, option, "usage")) {
        printShortUsage() catch {};
        return error.HelpRequested;
    }
    // Main operation modes
    else if (std.mem.eql(u8, option, "create")) {
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
    } else if (std.mem.eql(u8, option, "catenate") or std.mem.eql(u8, option, "concatenate")) {
        opts.operation = .concatenate;
    }
    // Verbosity
    else if (std.mem.eql(u8, option, "verbose")) {
        opts.verbosity = if (opts.verbosity == .verbose) .very_verbose else .verbose;
    }
    // Compression options
    else if (std.mem.eql(u8, option, "gzip") or std.mem.eql(u8, option, "gunzip") or std.mem.eql(u8, option, "ungzip")) {
        opts.compression = .gzip;
    } else if (std.mem.eql(u8, option, "bzip2")) {
        opts.compression = .bzip2;
    } else if (std.mem.eql(u8, option, "xz")) {
        opts.compression = .xz;
    } else if (std.mem.eql(u8, option, "zstd")) {
        opts.compression = .zstd;
    } else if (std.mem.eql(u8, option, "auto-compress")) {
        opts.compression = .auto;
    } else if (std.mem.eql(u8, option, "no-auto-compress")) {
        if (opts.compression == .auto) opts.compression = .none;
    }
    // Overwrite control
    else if (std.mem.eql(u8, option, "keep-old-files")) {
        opts.keep_old_files = true;
        opts.overwrite_mode = .keep_old_files;
    } else if (std.mem.eql(u8, option, "keep-newer-files")) {
        opts.overwrite_mode = .keep_newer_files;
    } else if (std.mem.eql(u8, option, "skip-old-files")) {
        opts.overwrite_mode = .skip_old_files;
    } else if (std.mem.eql(u8, option, "overwrite")) {
        opts.overwrite_mode = .overwrite;
    } else if (std.mem.eql(u8, option, "unlink-first")) {
        opts.overwrite_mode = .unlink_first;
    }
    // Symlink handling
    else if (std.mem.eql(u8, option, "dereference")) {
        opts.dereference = true;
    }
    // Output control
    else if (std.mem.eql(u8, option, "to-stdout")) {
        opts.to_stdout = true;
    }
    // File attributes
    else if (std.mem.eql(u8, option, "touch")) {
        opts.touch = true;
    } else if (std.mem.eql(u8, option, "numeric-owner")) {
        opts.numeric_owner = true;
    } else if (std.mem.eql(u8, option, "preserve-permissions") or
        std.mem.eql(u8, option, "same-permissions"))
    {
        opts.preserve_permissions = true;
    } else if (std.mem.eql(u8, option, "no-same-permissions")) {
        opts.preserve_permissions = false;
    }
    // Path handling
    else if (std.mem.eql(u8, option, "absolute-names")) {
        opts.absolute_names = true;
    }
    // Archive reading
    else if (std.mem.eql(u8, option, "ignore-zeros")) {
        opts.ignore_zeros = true;
    }
    // Sparse file handling
    else if (std.mem.eql(u8, option, "sparse")) {
        opts.sparse = true;
    }
    // Archive format
    else if (std.mem.startsWith(u8, option, "format=")) {
        const format_str = option[7..];
        opts.format = ArchiveFormat.fromString(format_str) orelse {
            std.debug.print("tar-zig: Unknown archive format: {s}\n", .{format_str});
            std.debug.print("Valid formats are: gnu, oldgnu, pax, posix, ustar, v7\n", .{});
            return error.InvalidOption;
        };
    } else if (std.mem.eql(u8, option, "format")) {
        if (args.next()) |format_str| {
            opts.format = ArchiveFormat.fromString(format_str) orelse {
                std.debug.print("tar-zig: Unknown archive format: {s}\n", .{format_str});
                std.debug.print("Valid formats are: gnu, oldgnu, pax, posix, ustar, v7\n", .{});
                return error.InvalidOption;
            };
        }
    } else if (std.mem.eql(u8, option, "posix")) {
        opts.format = .pax;
    } else if (std.mem.eql(u8, option, "old-archive") or std.mem.eql(u8, option, "portability")) {
        opts.format = .v7;
    }
    // Blocking factor
    else if (std.mem.startsWith(u8, option, "blocking-factor=")) {
        const num_str = option[16..];
        opts.blocking_factor = std.fmt.parseInt(u32, num_str, 10) catch {
            std.debug.print("tar-zig: Invalid blocking factor: {s}\n", .{num_str});
            return error.InvalidOption;
        };
    } else if (std.mem.eql(u8, option, "blocking-factor")) {
        if (args.next()) |num_str| {
            opts.blocking_factor = std.fmt.parseInt(u32, num_str, 10) catch {
                std.debug.print("tar-zig: Invalid blocking factor: {s}\n", .{num_str});
                return error.InvalidOption;
            };
        }
    } else if (std.mem.startsWith(u8, option, "record-size=")) {
        const num_str = option[12..];
        const record_size = std.fmt.parseInt(u32, num_str, 10) catch {
            std.debug.print("tar-zig: Invalid record size: {s}\n", .{num_str});
            return error.InvalidOption;
        };
        if (record_size % 512 != 0) {
            std.debug.print("tar-zig: Record size must be a multiple of 512\n", .{});
            return error.InvalidOption;
        }
        opts.blocking_factor = record_size / 512;
    }
    // Null-terminated names
    else if (std.mem.eql(u8, option, "null")) {
        opts.null_terminated = true;
    } else if (std.mem.eql(u8, option, "no-null")) {
        opts.null_terminated = false;
    }
    // Options with values (--option=value or --option value)
    else if (std.mem.startsWith(u8, option, "file=")) {
        opts.archive_file = option[5..];
    } else if (std.mem.startsWith(u8, option, "directory=")) {
        opts.directory = option[10..];
    } else if (std.mem.startsWith(u8, option, "strip-components=")) {
        const num_str = option[17..];
        opts.strip_components = std.fmt.parseInt(u32, num_str, 10) catch 0;
    } else if (std.mem.startsWith(u8, option, "exclude=")) {
        opts.exclude_patterns.append(opts.allocator, option[8..]) catch return error.OutOfMemory;
    } else if (std.mem.startsWith(u8, option, "files-from=")) {
        opts.files_from = option[11..];
    } else if (std.mem.startsWith(u8, option, "exclude-from=")) {
        opts.exclude_from = option[13..];
    }
    // Options that take next arg as value
    else if (std.mem.eql(u8, option, "file")) {
        opts.archive_file = args.next();
    } else if (std.mem.eql(u8, option, "directory")) {
        opts.directory = args.next();
    } else if (std.mem.eql(u8, option, "exclude")) {
        if (args.next()) |pattern| {
            opts.exclude_patterns.append(opts.allocator, pattern) catch return error.OutOfMemory;
        }
    } else if (std.mem.eql(u8, option, "files-from")) {
        opts.files_from = args.next();
    } else if (std.mem.eql(u8, option, "exclude-from")) {
        opts.exclude_from = args.next();
    }
    // Transform option
    else if (std.mem.startsWith(u8, option, "transform=")) {
        opts.transforms.append(opts.allocator, option[10..]) catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, option, "transform") or std.mem.eql(u8, option, "xform")) {
        if (args.next()) |expr| {
            opts.transforms.append(opts.allocator, expr) catch return error.OutOfMemory;
        }
    }
    // Phase 2: --one-file-system
    else if (std.mem.eql(u8, option, "one-file-system")) {
        opts.one_file_system = true;
    }
    // Phase 2: --newer, --newer-mtime, -N
    else if (std.mem.startsWith(u8, option, "newer=")) {
        const date_str = option[6..];
        opts.newer_mtime = parseDateString(date_str) catch {
            std.debug.print("tar-zig: Invalid date format: {s}\n", .{date_str});
            return error.InvalidOption;
        };
    } else if (std.mem.eql(u8, option, "newer") or std.mem.eql(u8, option, "after-date")) {
        if (args.next()) |date_str| {
            opts.newer_mtime = parseDateString(date_str) catch {
                std.debug.print("tar-zig: Invalid date format: {s}\n", .{date_str});
                return error.InvalidOption;
            };
        }
    } else if (std.mem.startsWith(u8, option, "newer-mtime=")) {
        const date_str = option[12..];
        opts.newer_mtime = parseDateString(date_str) catch {
            std.debug.print("tar-zig: Invalid date format: {s}\n", .{date_str});
            return error.InvalidOption;
        };
    } else if (std.mem.eql(u8, option, "newer-mtime")) {
        if (args.next()) |date_str| {
            opts.newer_mtime = parseDateString(date_str) catch {
                std.debug.print("tar-zig: Invalid date format: {s}\n", .{date_str});
                return error.InvalidOption;
            };
        }
    }
    // Phase 2: --remove-files
    else if (std.mem.eql(u8, option, "remove-files")) {
        opts.remove_files = true;
    }
    // Phase 2: --verify
    else if (std.mem.eql(u8, option, "verify")) {
        opts.verify = true;
    }
    // Phase 2: --checkpoint
    else if (std.mem.startsWith(u8, option, "checkpoint=")) {
        const num_str = option[11..];
        opts.checkpoint = std.fmt.parseInt(u32, num_str, 10) catch {
            std.debug.print("tar-zig: Invalid checkpoint value: {s}\n", .{num_str});
            return error.InvalidOption;
        };
    } else if (std.mem.eql(u8, option, "checkpoint")) {
        opts.checkpoint = 10; // Default to every 10 records
    } else if (std.mem.startsWith(u8, option, "checkpoint-action=")) {
        opts.checkpoint_action = option[18..];
    } else if (std.mem.eql(u8, option, "checkpoint-action")) {
        opts.checkpoint_action = args.next();
    }
    // Phase 3: Incremental backups
    else if (std.mem.startsWith(u8, option, "listed-incremental=")) {
        opts.listed_incremental = option[19..];
    } else if (std.mem.eql(u8, option, "listed-incremental")) {
        opts.listed_incremental = args.next();
    } else if (std.mem.eql(u8, option, "incremental")) {
        opts.incremental = true;
    } else if (std.mem.startsWith(u8, option, "level=")) {
        const level_str = option[6..];
        opts.level = std.fmt.parseInt(u32, level_str, 10) catch {
            std.debug.print("tar-zig: Invalid level: {s}\n", .{level_str});
            return error.InvalidOption;
        };
    }
    // Phase 3: Multi-volume archives
    else if (std.mem.eql(u8, option, "multi-volume")) {
        opts.multi_volume = true;
    } else if (std.mem.startsWith(u8, option, "tape-length=")) {
        const len_str = option[12..];
        opts.tape_length = std.fmt.parseInt(u64, len_str, 10) catch {
            std.debug.print("tar-zig: Invalid tape length: {s}\n", .{len_str});
            return error.InvalidOption;
        };
        opts.tape_length.? *= 1024; // Convert from KB to bytes
    } else if (std.mem.eql(u8, option, "tape-length")) {
        if (args.next()) |len_str| {
            opts.tape_length = std.fmt.parseInt(u64, len_str, 10) catch {
                std.debug.print("tar-zig: Invalid tape length: {s}\n", .{len_str});
                return error.InvalidOption;
            };
            opts.tape_length.? *= 1024;
        }
    } else if (std.mem.startsWith(u8, option, "volno-file=")) {
        opts.volno_file = option[11..];
    } else if (std.mem.eql(u8, option, "volno-file")) {
        opts.volno_file = args.next();
    } else if (std.mem.startsWith(u8, option, "info-script=")) {
        opts.new_volume_script = option[12..];
    } else if (std.mem.eql(u8, option, "info-script") or std.mem.eql(u8, option, "new-volume-script")) {
        opts.new_volume_script = args.next();
    }
    // Phase 3: Extended attributes
    else if (std.mem.eql(u8, option, "xattrs")) {
        opts.xattrs = true;
    } else if (std.mem.eql(u8, option, "no-xattrs")) {
        opts.no_xattrs = true;
        opts.xattrs = false;
    } else if (std.mem.startsWith(u8, option, "xattrs-include=")) {
        opts.xattrs_include.append(opts.allocator, option[15..]) catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, option, "xattrs-include")) {
        if (args.next()) |pattern| {
            opts.xattrs_include.append(opts.allocator, pattern) catch return error.OutOfMemory;
        }
    } else if (std.mem.startsWith(u8, option, "xattrs-exclude=")) {
        opts.xattrs_exclude.append(opts.allocator, option[15..]) catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, option, "xattrs-exclude")) {
        if (args.next()) |pattern| {
            opts.xattrs_exclude.append(opts.allocator, pattern) catch return error.OutOfMemory;
        }
    } else if (std.mem.eql(u8, option, "acls")) {
        opts.acls = true;
    } else if (std.mem.eql(u8, option, "no-acls")) {
        opts.no_acls = true;
        opts.acls = false;
    } else if (std.mem.eql(u8, option, "selinux")) {
        opts.selinux = true;
    } else if (std.mem.eql(u8, option, "no-selinux")) {
        opts.no_selinux = true;
        opts.selinux = false;
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
            // Main operation modes
            'c' => opts.operation = .create,
            'x' => opts.operation = .extract,
            't' => opts.operation = .list,
            'r' => opts.operation = .append,
            'u' => opts.operation = .update,
            'd' => opts.operation = .diff,
            'A' => opts.operation = .concatenate,

            // Verbosity
            'v' => opts.verbosity = if (opts.verbosity == .verbose) .very_verbose else .verbose,

            // Compression
            'z' => opts.compression = .gzip,
            'j' => opts.compression = .bzip2,
            'J' => opts.compression = .xz,
            'a' => opts.compression = .auto,

            // File handling
            'h' => opts.dereference = true,
            'k' => {
                opts.keep_old_files = true;
                opts.overwrite_mode = .keep_old_files;
            },
            'U' => opts.overwrite_mode = .unlink_first,

            // Output control
            'O' => opts.to_stdout = true,

            // File attributes
            'm' => opts.touch = true,
            'p' => opts.preserve_permissions = true,

            // Path handling
            'P' => opts.absolute_names = true,

            // Archive reading
            'i' => opts.ignore_zeros = true,

            // Sparse file handling
            'S' => opts.sparse = true,

            // Options with arguments
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
            'T' => {
                if (i + 1 < options_str.len) {
                    opts.files_from = options_str[i + 1 ..];
                    return;
                } else {
                    opts.files_from = args.next();
                }
            },
            'X' => {
                if (i + 1 < options_str.len) {
                    opts.exclude_from = options_str[i + 1 ..];
                    return;
                } else {
                    opts.exclude_from = args.next();
                }
            },
            'H' => {
                const format_str = if (i + 1 < options_str.len)
                    options_str[i + 1 ..]
                else
                    args.next() orelse {
                        std.debug.print("tar-zig: Option -H requires an argument\n", .{});
                        return error.InvalidOption;
                    };
                opts.format = ArchiveFormat.fromString(format_str) orelse {
                    std.debug.print("tar-zig: Unknown archive format: {s}\n", .{format_str});
                    std.debug.print("Valid formats are: gnu, oldgnu, pax, posix, ustar, v7\n", .{});
                    return error.InvalidOption;
                };
                if (i + 1 < options_str.len) return;
            },
            'b' => {
                const num_str = if (i + 1 < options_str.len)
                    options_str[i + 1 ..]
                else
                    args.next() orelse {
                        std.debug.print("tar-zig: Option -b requires an argument\n", .{});
                        return error.InvalidOption;
                    };
                opts.blocking_factor = std.fmt.parseInt(u32, num_str, 10) catch {
                    std.debug.print("tar-zig: Invalid blocking factor: {s}\n", .{num_str});
                    return error.InvalidOption;
                };
                if (i + 1 < options_str.len) return;
            },

            // Phase 2: -N (newer)
            'N' => {
                const date_str = if (i + 1 < options_str.len)
                    options_str[i + 1 ..]
                else
                    args.next() orelse {
                        std.debug.print("tar-zig: Option -N requires an argument\n", .{});
                        return error.InvalidOption;
                    };
                opts.newer_mtime = parseDateString(date_str) catch {
                    std.debug.print("tar-zig: Invalid date format: {s}\n", .{date_str});
                    return error.InvalidOption;
                };
                if (i + 1 < options_str.len) return;
            },

            // Phase 2: -W (verify)
            'W' => opts.verify = true,

            // Phase 3: -g (listed-incremental)
            'g' => {
                opts.listed_incremental = if (i + 1 < options_str.len)
                    options_str[i + 1 ..]
                else
                    args.next();
                if (i + 1 < options_str.len) return;
            },

            // Phase 3: -G (incremental)
            'G' => opts.incremental = true,

            // Phase 3: -M (multi-volume)
            'M' => opts.multi_volume = true,

            // Phase 3: -L (tape-length)
            'L' => {
                const len_str = if (i + 1 < options_str.len)
                    options_str[i + 1 ..]
                else
                    args.next() orelse {
                        std.debug.print("tar-zig: Option -L requires an argument\n", .{});
                        return error.InvalidOption;
                    };
                opts.tape_length = std.fmt.parseInt(u64, len_str, 10) catch {
                    std.debug.print("tar-zig: Invalid tape length: {s}\n", .{len_str});
                    return error.InvalidOption;
                };
                opts.tape_length.? *= 1024; // Convert KB to bytes
                if (i + 1 < options_str.len) return;
            },

            // Phase 3: -F (info-script/new-volume-script)
            'F' => {
                opts.new_volume_script = if (i + 1 < options_str.len)
                    options_str[i + 1 ..]
                else
                    args.next();
                if (i + 1 < options_str.len) return;
            },

            // Help
            '?' => {
                printUsage() catch {};
                return error.HelpRequested;
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
        \\Usage: tar-zig [OPTION...] [FILE]...
        \\'tar-zig' saves many files together into a single tape or disk archive, and can
        \\restore individual files from the archive.
        \\
        \\Examples:
        \\  tar-zig -cf archive.tar foo bar  # Create archive.tar from files foo and bar.
        \\  tar-zig -tvf archive.tar         # List all files in archive.tar verbosely.
        \\  tar-zig -xf archive.tar          # Extract all files from archive.tar.
        \\
        \\ Main operation mode:
        \\  -A, --catenate, --concatenate   append tar files to an archive
        \\  -c, --create               create a new archive
        \\      --delete               delete from the archive (not on mag tapes!)
        \\  -d, --diff, --compare      find differences between archive and file system
        \\  -r, --append               append files to the end of an archive
        \\  -t, --list                 list the contents of an archive
        \\  -u, --update               only append files newer than copy in archive
        \\  -x, --extract, --get       extract files from an archive
        \\
        \\ Overwrite control:
        \\      --keep-newer-files     don't replace existing files that are newer than
        \\                             their archive copies
        \\  -k, --keep-old-files       don't replace existing files when extracting,
        \\                             treat them as errors
        \\      --overwrite            overwrite existing files when extracting
        \\      --skip-old-files       don't replace existing files when extracting,
        \\                             silently skip over them
        \\  -U, --unlink-first         remove each file prior to extracting over it
        \\
        \\ Select output stream:
        \\  -O, --to-stdout            extract files to standard output
        \\
        \\ Handling of file attributes:
        \\  -m, --touch                don't extract file modified time
        \\      --no-same-permissions  apply the user's umask when extracting permissions
        \\                             from the archive (default for ordinary users)
        \\      --numeric-owner        always use numbers for user/group names
        \\  -p, --preserve-permissions, --same-permissions
        \\                             extract information about file permissions
        \\                             (default for superuser)
        \\
        \\ Device selection and switching:
        \\  -f, --file=ARCHIVE         use archive file or device ARCHIVE
        \\
        \\ Device blocking:
        \\  -b, --blocking-factor=BLOCKS   BLOCKS x 512 bytes per record
        \\  -i, --ignore-zeros         ignore zeroed blocks in archive (means EOF)
        \\      --record-size=NUMBER   NUMBER of bytes per record, multiple of 512
        \\
        \\ Local file name selection:
        \\  -C, --directory=DIR        change to directory DIR
        \\      --exclude=PATTERN      exclude files, given as a PATTERN
        \\  -T, --files-from=FILE      get names to extract or create from FILE
        \\  -X, --exclude-from=FILE    exclude patterns listed in FILE
        \\      --null                 -T reads null-terminated names
        \\
        \\ File name transformations:
        \\      --strip-components=NUMBER   strip NUMBER leading components from file
        \\                             names on extraction
        \\      --transform=EXPRESSION, --xform=EXPRESSION
        \\                             use sed replace EXPRESSION to transform file names
        \\
        \\ Archive format selection:
        \\  -H, --format=FORMAT        create archive of the given format
        \\
        \\ FORMAT is one of the following:
        \\    gnu                      GNU tar 1.13.x format
        \\    oldgnu                   GNU format as per tar <= 1.12
        \\    pax, posix               POSIX 1003.1-2001 (pax) format
        \\    ustar                    POSIX 1003.1-1988 (ustar) format
        \\    v7                       old V7 tar format
        \\
        \\      --old-archive, --portability
        \\                             same as --format=v7
        \\      --posix                same as --format=posix
        \\
        \\ Compression options:
        \\  -a, --auto-compress        use archive suffix to determine the compression
        \\                             program
        \\  -j, --bzip2                filter the archive through bzip2
        \\  -J, --xz                   filter the archive through xz
        \\      --no-auto-compress     do not use archive suffix to determine the
        \\                             compression program
        \\      --zstd                 filter the archive through zstd
        \\  -z, --gzip, --gunzip, --ungzip   filter the archive through gzip
        \\
        \\ Handling of sparse files:
        \\  -S, --sparse               handle sparse files efficiently
        \\
        \\ Local file selection:
        \\  -h, --dereference          follow symlinks; archive and dump the files they
        \\                             point to
        \\  -N, --newer=DATE-OR-FILE, --after-date=DATE-OR-FILE
        \\                             only store files newer than DATE-OR-FILE
        \\      --newer-mtime=DATE     compare date and time when data changed only
        \\      --one-file-system      stay in local file system when creating archive
        \\  -P, --absolute-names       don't strip leading '/'s from file names
        \\      --remove-files         remove files after adding them to the archive
        \\
        \\ Informative output:
        \\  -v, --verbose              verbosely list files processed
        \\      --checkpoint[=NUMBER]  display progress messages every NUMBERth record
        \\                             (default 10)
        \\      --checkpoint-action=ACTION   execute ACTION on each checkpoint
        \\  -W, --verify               attempt to verify the archive after writing it
        \\
        \\ Incremental backup options:
        \\  -g, --listed-incremental=FILE   handle new GNU-format incremental backup
        \\  -G, --incremental          handle old GNU-format incremental backup
        \\      --level=NUMBER         dump level for created listed-incremental archive
        \\
        \\ Multi-volume archive options:
        \\  -M, --multi-volume         create/list/extract multi-volume archive
        \\  -L, --tape-length=NUMBER   change tape after writing NUMBER x 1024 bytes
        \\      --volno-file=FILE      use/update the volume number in FILE
        \\  -F, --info-script=FILE, --new-volume-script=FILE
        \\                             run script at end of each tape (implies -M)
        \\
        \\ Extended attributes:
        \\      --xattrs               enable extended attributes support
        \\      --xattrs-include=MASK  specify the include pattern for xattr keys
        \\      --xattrs-exclude=MASK  specify the exclude pattern for xattr keys
        \\      --no-xattrs            disable extended attributes support
        \\      --acls                 enable POSIX ACLs support
        \\      --no-acls              disable POSIX ACLs support
        \\      --selinux              enable SELinux context support
        \\      --no-selinux           disable SELinux context support
        \\
        \\ Other options:
        \\  -?, --help                 give this help list
        \\      --usage                give a short usage message
        \\      --version              print program version
        \\
        \\*This* tar-zig defaults to:
        \\--format=gnu -f- --quoting-style=escape
        \\
        \\Report bugs to: https://github.com/user/tar-zig/issues
        \\
    );
}

pub fn printShortUsage() !void {
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll(
        \\Usage: tar-zig [-AcdrtuxU] [-C DIR] [-f ARCHIVE] [-T FILE] [-X FILE]
        \\            [--exclude=PATTERN] [--files-from=FILE] [--exclude-from=FILE]
        \\            [--strip-components=N] [--keep-old-files] [--keep-newer-files]
        \\            [--skip-old-files] [--overwrite] [--unlink-first]
        \\            [--to-stdout] [--touch] [--numeric-owner] [--absolute-names]
        \\            [--ignore-zeros] [--null] [-ajJzpvhkmiOP]
        \\            [--gzip] [--bzip2] [--xz] [--zstd] [--auto-compress]
        \\            [--help] [--usage] [--version]
        \\            [FILE]...
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
