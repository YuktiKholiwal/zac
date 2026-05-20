const std = @import("std");
const glob = @import("tools/find_files.zig");

/// Simplified .gitignore matcher. Supports the patterns most repos actually use:
///   foo            → match basename anywhere
///   *.zig          → suffix match
///   /foo           → anchored at root
///   foo/           → directory only (we keep the pattern; caller decides)
///   foo/bar        → match path segment
///   **/foo         → any-depth, anywhere
///   # comments and blank lines
///   !pattern       → negation (un-ignore)
pub const Gitignore = struct {
    arena: std.heap.ArenaAllocator,
    rules: std.ArrayList(Rule),

    pub fn deinit(self: *Gitignore) void {
        self.rules.deinit();
        self.arena.deinit();
    }

    pub fn isIgnored(self: *const Gitignore, path: []const u8) bool {
        var verdict = false;
        for (self.rules.items) |r| {
            if (matches(r, path)) verdict = !r.negate;
        }
        return verdict;
    }
};

const Rule = struct {
    pattern: []const u8,
    negate: bool,
    anchored: bool,
    dir_only: bool,
};

fn matches(r: Rule, path: []const u8) bool {
    // gitignore semantics: a rule matches if the pattern matches the path,
    // any path suffix starting after '/', or any path prefix ending before '/'.
    // The prefix case is what makes `zig-out` match `zig-out/bin/foo`.
    if (r.anchored) {
        if (glob.globMatch(r.pattern, path)) return true;
        return matchesPrefix(r.pattern, path);
    }
    if (glob.globMatch(r.pattern, path)) return true;
    if (matchesPrefix(r.pattern, path)) return true;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/' and i + 1 < path.len) {
            const sub = path[i + 1 ..];
            if (glob.globMatch(r.pattern, sub)) return true;
            if (matchesPrefix(r.pattern, sub)) return true;
        }
    }
    return false;
}

fn matchesPrefix(pattern: []const u8, path: []const u8) bool {
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            if (glob.globMatch(pattern, path[0..i])) return true;
        }
    }
    return false;
}

/// Loads .gitignore from the cwd (and merges built-in defaults).
/// Always succeeds — a missing .gitignore yields the defaults only.
pub fn load(parent_alloc: std.mem.Allocator) !Gitignore {
    var gi = Gitignore{
        .arena = std.heap.ArenaAllocator.init(parent_alloc),
        .rules = std.ArrayList(Rule).init(parent_alloc),
    };
    errdefer gi.deinit();

    const a = gi.arena.allocator();

    // Built-in defaults: hide things git tracks anyway.
    const defaults = [_][]const u8{ ".git", "node_modules", "target", "zig-out", ".zig-cache" };
    for (defaults) |p| {
        try gi.rules.append(.{
            .pattern = try a.dupe(u8, p),
            .negate = false,
            .anchored = false,
            .dir_only = true,
        });
    }

    const file = std.fs.cwd().openFile(".gitignore", .{}) catch return gi;
    defer file.close();

    const body = try file.readToEndAlloc(a, 1 * 1024 * 1024);
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var pat = line;
        var negate = false;
        if (pat[0] == '!') {
            negate = true;
            pat = pat[1..];
        }
        var anchored = false;
        if (pat.len > 0 and pat[0] == '/') {
            anchored = true;
            pat = pat[1..];
        }
        var dir_only = false;
        if (pat.len > 0 and pat[pat.len - 1] == '/') {
            dir_only = true;
            pat = pat[0 .. pat.len - 1];
        }
        if (pat.len == 0) continue;

        try gi.rules.append(.{
            .pattern = try a.dupe(u8, pat),
            .negate = negate,
            .anchored = anchored,
            .dir_only = dir_only,
        });
    }

    return gi;
}

test "gitignore: defaults match build dirs" {
    const alloc = std.testing.allocator;
    var gi = try load(alloc);
    defer gi.deinit();
    try std.testing.expect(gi.isIgnored("zig-out/bin/foo"));
    try std.testing.expect(gi.isIgnored("node_modules/x/y.js"));
    try std.testing.expect(gi.isIgnored(".git/HEAD"));
    try std.testing.expect(!gi.isIgnored("src/main.zig"));
}

test "gitignore: anchored vs floating" {
    const alloc = std.testing.allocator;
    // We can't easily inject a .gitignore for this test without changing cwd,
    // so we just exercise the rule matcher directly.
    var gi = Gitignore{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .rules = std.ArrayList(Rule).init(alloc),
    };
    defer gi.deinit();

    const a = gi.arena.allocator();
    try gi.rules.append(.{ .pattern = try a.dupe(u8, "build"), .negate = false, .anchored = false, .dir_only = false });
    try gi.rules.append(.{ .pattern = try a.dupe(u8, "secret.txt"), .negate = false, .anchored = true, .dir_only = false });

    try std.testing.expect(gi.isIgnored("build"));
    try std.testing.expect(gi.isIgnored("some/dir/build"));
    try std.testing.expect(gi.isIgnored("secret.txt"));
    try std.testing.expect(!gi.isIgnored("dir/secret.txt")); // anchored
}
