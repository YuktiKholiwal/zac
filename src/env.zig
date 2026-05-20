const std = @import("std");

/// Minimal .env loader. Supports:
///   KEY=value
///   KEY="quoted value"
///   KEY='single quoted'
///   # comment lines and blank lines
/// Does NOT support: variable expansion, multiline values, export prefix.
pub const EnvFile = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMap([]const u8),

    pub fn deinit(self: *EnvFile) void {
        self.map.deinit();
        self.arena.deinit();
    }

    pub fn get(self: *const EnvFile, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }
};

/// Loads .env from the given path. Missing file is not an error — returns an
/// empty EnvFile.
pub fn load(parent_alloc: std.mem.Allocator, path: []const u8) !EnvFile {
    var ef = EnvFile{
        .arena = std.heap.ArenaAllocator.init(parent_alloc),
        .map = std.StringHashMap([]const u8).init(parent_alloc),
    };
    errdefer ef.deinit();

    const alloc = ef.arena.allocator();

    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return ef,
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(alloc, 1 * 1024 * 1024);

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (value.len >= 2) {
            const first = value[0];
            const last = value[value.len - 1];
            if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
                value = value[1 .. value.len - 1];
            }
        }

        if (key.len == 0) continue;
        try ef.map.put(key, value);
    }

    return ef;
}

test ".env: parse basic and quoted" {
    const alloc = std.testing.allocator;
    const tmp_path = "test_env_basic.env";
    {
        var f = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\# a comment
            \\PLAIN=value
            \\QUOTED="with spaces"
            \\SINGLE='also fine'
            \\
            \\BAD_NO_EQ
            \\
        );
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var ef = try load(alloc, tmp_path);
    defer ef.deinit();

    try std.testing.expectEqualStrings("value", ef.get("PLAIN").?);
    try std.testing.expectEqualStrings("with spaces", ef.get("QUOTED").?);
    try std.testing.expectEqualStrings("also fine", ef.get("SINGLE").?);
    try std.testing.expect(ef.get("BAD_NO_EQ") == null);
}

test ".env: missing file returns empty" {
    const alloc = std.testing.allocator;
    var ef = try load(alloc, "definitely_not_a_real.env");
    defer ef.deinit();
    try std.testing.expect(ef.get("ANYTHING") == null);
}
