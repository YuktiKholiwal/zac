const std = @import("std");
const messages = @import("../messages.zig");
const mod = @import("mod.zig");
const gitignore = @import("../gitignore.zig");

const MAX_RESULTS: usize = 200;

pub const def = messages.Tool{
    .name = "find_files",
    .description = "Find files whose path matches a simple glob. Supports * (any chars in segment) and **/ (any depth). Skips common build/vendor dirs. Returns up to 200 paths.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pattern": {"type": "string", "description": "Glob, e.g. '**/*.zig' or 'src/**/main.*'"},
    \\    "path": {"type": "string", "description": "Root directory (default: cwd)"}
    \\  },
    \\  "required": ["pattern"]
    \\}
    ,
};

pub fn execute(alloc: std.mem.Allocator, args: std.json.Value) anyerror![]u8 {
    const pattern = mod.getString(args, "pattern") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'pattern' is required", .{});
    const root_path = mod.getString(args, "path") orelse ".";

    var dir = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error opening {s}: {s}", .{ root_path, @errorName(err) });
    };
    defer dir.close();

    var gi = try gitignore.load(alloc);
    defer gi.deinit();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    const w = out.writer();

    var hits: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (gi.isIgnored(entry.path)) continue;
        if (!globMatch(pattern, entry.path)) continue;

        hits += 1;
        if (hits > MAX_RESULTS) break;
        try w.print("{s}/{s}\n", .{ root_path, entry.path });
    }

    if (hits == 0) {
        try w.print("No files match '{s}' under {s}\n", .{ pattern, root_path });
    } else if (hits > MAX_RESULTS) {
        try w.print("\n(truncated at {d}; narrow the pattern)\n", .{MAX_RESULTS});
    }

    return out.toOwnedSlice();
}

/// Tiny recursive glob:
///   *      → match any run of chars within a path segment (not /)
///   **     → match any run of chars including /
///   ?      → match one non-/ char
///   other  → literal
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    return matchAt(pattern, 0, name, 0);
}

fn matchAt(p: []const u8, pi: usize, n: []const u8, ni: usize) bool {
    var i = pi;
    var j = ni;
    while (i < p.len) {
        const c = p[i];
        if (c == '*') {
            const double = i + 1 < p.len and p[i + 1] == '*';
            const skip_pat: usize = if (double) 2 else 1;
            // Try every possible match length for the star.
            const rest_pat = i + skip_pat;
            // Empty match
            if (matchAt(p, rest_pat, n, j)) return true;
            // Consume one char at a time
            while (j < n.len) {
                if (!double and n[j] == '/') return false;
                j += 1;
                if (matchAt(p, rest_pat, n, j)) return true;
            }
            return false;
        } else if (c == '?') {
            if (j >= n.len or n[j] == '/') return false;
            i += 1;
            j += 1;
        } else {
            if (j >= n.len or n[j] != c) return false;
            i += 1;
            j += 1;
        }
    }
    return j == n.len;
}

test "glob: literal" {
    try std.testing.expect(globMatch("foo", "foo"));
    try std.testing.expect(!globMatch("foo", "bar"));
}

test "glob: * within segment" {
    try std.testing.expect(globMatch("*.zig", "main.zig"));
    try std.testing.expect(globMatch("src/*.zig", "src/main.zig"));
    try std.testing.expect(!globMatch("src/*.zig", "src/tools/main.zig"));
}

test "glob: ** crosses segments" {
    try std.testing.expect(globMatch("**/*.zig", "src/tools/edit.zig"));
    try std.testing.expect(globMatch("src/**", "src/tools/edit.zig"));
    try std.testing.expect(globMatch("**/main.*", "src/main.zig"));
}

test "glob: ? single char" {
    try std.testing.expect(globMatch("?bc", "abc"));
    try std.testing.expect(!globMatch("?bc", "/bc"));
    try std.testing.expect(!globMatch("?bc", "abbc"));
}
