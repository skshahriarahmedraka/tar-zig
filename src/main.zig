const std = @import("std");
const options = @import("options.zig");
const list = @import("list.zig");
const extract = @import("extract.zig");
const create = @import("create.zig");
const append = @import("append.zig");
const update = @import("update.zig");
const diff = @import("diff.zig");
const delete = @import("delete.zig");
const concatenate = @import("concatenate.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var opts = options.parseArgs(allocator) catch |err| {
        if (err == error.HelpRequested or err == error.VersionRequested) {
            return;
        }
        return err;
    };
    defer opts.deinit();

    switch (opts.operation) {
        .list => try list.execute(allocator, opts),
        .extract => try extract.execute(allocator, opts),
        .create => try create.execute(allocator, opts),
        .append => try append.execute(allocator, opts),
        .update => try update.execute(allocator, opts),
        .diff => try diff.execute(allocator, opts),
        .delete => try delete.execute(allocator, opts),
        .concatenate => try concatenate.execute(allocator, opts),
        .none => {
            try options.printUsage();
            return error.NoOperationSpecified;
        },
    }
}

test {
    _ = @import("tar_header.zig");
    _ = @import("options.zig");
    _ = @import("buffer.zig");
    _ = @import("compression.zig");
    _ = @import("pax.zig");
    _ = @import("list.zig");
    _ = @import("extract.zig");
    _ = @import("create.zig");
    _ = @import("append.zig");
    _ = @import("update.zig");
    _ = @import("diff.zig");
    _ = @import("delete.zig");
    _ = @import("concatenate.zig");
    _ = @import("file_utils.zig");
    _ = @import("tests/integration_tests.zig");
}
