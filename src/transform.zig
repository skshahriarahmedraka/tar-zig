const std = @import("std");

/// A parsed transform expression (sed-like s/REGEXP/REPLACEMENT/[flags])
pub const Transform = struct {
    pattern: []const u8,
    replacement: []const u8,
    flags: Flags,
    
    pub const Flags = struct {
        global: bool = false,       // g - replace all occurrences
        ignore_case: bool = false,  // i - case insensitive (not fully supported)
        extended: bool = false,     // x - extended regex (not fully supported)
        symlink: bool = true,       // S - apply to symlink targets
        hardlink: bool = true,      // H - apply to hardlink targets
        regular: bool = true,       // R - apply to regular file names (default)
    };
};

/// Parse a sed-like transform expression: s/pattern/replacement/flags
/// Supports different delimiters (first char after 's')
pub fn parseTransform(expr: []const u8) ?Transform {
    if (expr.len < 4) return null;
    
    // Must start with 's'
    if (expr[0] != 's') return null;
    
    const delimiter = expr[1];
    
    // Find the pattern (between first and second delimiter)
    var pattern_end: usize = 2;
    while (pattern_end < expr.len and expr[pattern_end] != delimiter) {
        // Handle escaped delimiter
        if (expr[pattern_end] == '\\' and pattern_end + 1 < expr.len) {
            pattern_end += 2;
        } else {
            pattern_end += 1;
        }
    }
    
    if (pattern_end >= expr.len) return null;
    
    const pattern = expr[2..pattern_end];
    
    // Find the replacement (between second and third delimiter)
    var replacement_end: usize = pattern_end + 1;
    while (replacement_end < expr.len and expr[replacement_end] != delimiter) {
        // Handle escaped delimiter
        if (expr[replacement_end] == '\\' and replacement_end + 1 < expr.len) {
            replacement_end += 2;
        } else {
            replacement_end += 1;
        }
    }
    
    const replacement = expr[pattern_end + 1 .. replacement_end];
    
    // Parse flags (after third delimiter)
    var flags = Transform.Flags{};
    if (replacement_end < expr.len) {
        const flag_str = expr[replacement_end + 1 ..];
        for (flag_str) |c| {
            switch (c) {
                'g' => flags.global = true,
                'i' => flags.ignore_case = true,
                'x' => flags.extended = true,
                'S' => flags.symlink = true,
                'H' => flags.hardlink = true,
                'R' => flags.regular = true,
                's' => flags.symlink = false,
                'h' => flags.hardlink = false,
                'r' => flags.regular = false,
                else => {},
            }
        }
    }
    
    return Transform{
        .pattern = pattern,
        .replacement = replacement,
        .flags = flags,
    };
}

/// Apply a single transform to a name
pub fn applyTransform(allocator: std.mem.Allocator, name: []const u8, transform: Transform) ![]u8 {
    // Simple string replacement (not full regex for now)
    // This handles the most common use case: s/old/new/ or s/old/new/g
    
    if (transform.flags.global) {
        return replaceAll(allocator, name, transform.pattern, transform.replacement);
    } else {
        return replaceFirst(allocator, name, transform.pattern, transform.replacement);
    }
}

/// Replace all occurrences of pattern with replacement
fn replaceAll(allocator: std.mem.Allocator, input: []const u8, pattern: []const u8, replacement: []const u8) ![]u8 {
    if (pattern.len == 0) {
        return allocator.dupe(u8, input);
    }
    
    // Count occurrences first
    var count: usize = 0;
    var pos: usize = 0;
    while (pos <= input.len - pattern.len) {
        if (std.mem.eql(u8, input[pos..pos + pattern.len], pattern)) {
            count += 1;
            pos += pattern.len;
        } else {
            pos += 1;
        }
    }
    
    if (count == 0) {
        return allocator.dupe(u8, input);
    }
    
    // Calculate new size
    const new_size = input.len - (count * pattern.len) + (count * replacement.len);
    var result = try allocator.alloc(u8, new_size);
    
    // Build result
    var write_pos: usize = 0;
    var read_pos: usize = 0;
    
    while (read_pos <= input.len - pattern.len) {
        if (std.mem.eql(u8, input[read_pos..read_pos + pattern.len], pattern)) {
            @memcpy(result[write_pos..write_pos + replacement.len], replacement);
            write_pos += replacement.len;
            read_pos += pattern.len;
        } else {
            result[write_pos] = input[read_pos];
            write_pos += 1;
            read_pos += 1;
        }
    }
    
    // Copy remaining bytes
    while (read_pos < input.len) {
        result[write_pos] = input[read_pos];
        write_pos += 1;
        read_pos += 1;
    }
    
    return result;
}

/// Replace first occurrence of pattern with replacement
fn replaceFirst(allocator: std.mem.Allocator, input: []const u8, pattern: []const u8, replacement: []const u8) ![]u8 {
    if (pattern.len == 0 or input.len < pattern.len) {
        return allocator.dupe(u8, input);
    }
    
    // Find first occurrence
    var pos: usize = 0;
    while (pos <= input.len - pattern.len) {
        if (std.mem.eql(u8, input[pos..pos + pattern.len], pattern)) {
            // Found it - build result
            const new_size = input.len - pattern.len + replacement.len;
            var result = try allocator.alloc(u8, new_size);
            
            // Copy before pattern
            @memcpy(result[0..pos], input[0..pos]);
            // Copy replacement
            @memcpy(result[pos..pos + replacement.len], replacement);
            // Copy after pattern
            @memcpy(result[pos + replacement.len..], input[pos + pattern.len..]);
            
            return result;
        }
        pos += 1;
    }
    
    // No match found
    return allocator.dupe(u8, input);
}

/// Apply multiple transforms to a name
pub fn applyTransforms(allocator: std.mem.Allocator, name: []const u8, transform_exprs: []const []const u8) ![]u8 {
    if (transform_exprs.len == 0) {
        return allocator.dupe(u8, name);
    }
    
    var current = try allocator.dupe(u8, name);
    
    for (transform_exprs) |expr| {
        if (parseTransform(expr)) |transform| {
            const next = try applyTransform(allocator, current, transform);
            allocator.free(current);
            current = next;
        }
    }
    
    return current;
}

// Tests
test "parse simple transform" {
    const t = parseTransform("s/foo/bar/").?;
    try std.testing.expectEqualStrings("foo", t.pattern);
    try std.testing.expectEqualStrings("bar", t.replacement);
    try std.testing.expect(!t.flags.global);
}

test "parse transform with global flag" {
    const t = parseTransform("s/foo/bar/g").?;
    try std.testing.expectEqualStrings("foo", t.pattern);
    try std.testing.expectEqualStrings("bar", t.replacement);
    try std.testing.expect(t.flags.global);
}

test "parse transform with different delimiter" {
    const t = parseTransform("s#old#new#").?;
    try std.testing.expectEqualStrings("old", t.pattern);
    try std.testing.expectEqualStrings("new", t.replacement);
}

test "apply transform replace first" {
    const result = try applyTransform(std.testing.allocator, "foo/bar/foo", Transform{
        .pattern = "foo",
        .replacement = "baz",
        .flags = .{},
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("baz/bar/foo", result);
}

test "apply transform replace all" {
    const result = try applyTransform(std.testing.allocator, "foo/bar/foo", Transform{
        .pattern = "foo",
        .replacement = "baz",
        .flags = .{ .global = true },
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("baz/bar/baz", result);
}

test "apply multiple transforms" {
    const transforms = [_][]const u8{ "s/old/new/", "s/test/prod/g" };
    const result = try applyTransforms(std.testing.allocator, "old/test/test", &transforms);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("new/prod/prod", result);
}

test "empty pattern" {
    const result = try replaceFirst(std.testing.allocator, "hello", "", "x");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "no match" {
    const result = try replaceFirst(std.testing.allocator, "hello", "xyz", "abc");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}
