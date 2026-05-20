const std = @import("std");
const ui = @import("ui.zig");

pub const Decision = enum { allow_once, allow_session, allow_pattern, deny };

pub const Permission = struct {
    /// Tools the user has chosen to allow blanket for the rest of the session.
    session_allowlist: std.StringHashMap(void),
    /// Per-tool prefix patterns. Calls whose preview starts with one of these
    /// patterns auto-allow.
    pattern_allowlist: std.StringHashMap(std.ArrayList([]const u8)),
    /// If true, every tool call is auto-allowed (yolo mode).
    yolo: bool,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, yolo: bool) Permission {
        return .{
            .session_allowlist = std.StringHashMap(void).init(alloc),
            .pattern_allowlist = std.StringHashMap(std.ArrayList([]const u8)).init(alloc),
            .yolo = yolo,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Permission) void {
        var sit = self.session_allowlist.keyIterator();
        while (sit.next()) |k| self.alloc.free(k.*);
        self.session_allowlist.deinit();

        var pit = self.pattern_allowlist.iterator();
        while (pit.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |p| self.alloc.free(p);
            entry.value_ptr.deinit();
        }
        self.pattern_allowlist.deinit();
    }

    /// Returns true if the call should proceed.
    pub fn check(
        self: *Permission,
        tool_name: []const u8,
        preview: []const u8,
    ) !bool {
        if (self.yolo) return true;
        if (isReadOnly(tool_name)) return true;
        if (self.session_allowlist.contains(tool_name)) return true;
        if (self.matchesPattern(tool_name, preview)) return true;

        const decision = try ask(tool_name, preview);
        switch (decision) {
            .allow_once => return true,
            .allow_session => {
                const owned = try self.alloc.dupe(u8, tool_name);
                try self.session_allowlist.put(owned, {});
                return true;
            },
            .allow_pattern => {
                try self.addPattern(tool_name, derivePattern(preview));
                return true;
            },
            .deny => return false,
        }
    }

    fn matchesPattern(self: *const Permission, tool: []const u8, preview: []const u8) bool {
        const list = self.pattern_allowlist.get(tool) orelse return false;
        for (list.items) |p| {
            if (std.mem.startsWith(u8, preview, p)) return true;
        }
        return false;
    }

    fn addPattern(self: *Permission, tool: []const u8, pat: []const u8) !void {
        const gop = try self.pattern_allowlist.getOrPut(tool);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.alloc.dupe(u8, tool);
            gop.value_ptr.* = std.ArrayList([]const u8).init(self.alloc);
        }
        try gop.value_ptr.append(try self.alloc.dupe(u8, pat));
    }
};

fn isReadOnly(tool: []const u8) bool {
    return std.mem.eql(u8, tool, "read") or
        std.mem.eql(u8, tool, "grep") or
        std.mem.eql(u8, tool, "find_files") or
        std.mem.eql(u8, tool, "list_dir") or
        std.mem.eql(u8, tool, "write_todo_list");
}

/// Heuristic: for bash, take everything up to the first whitespace boundary
/// after the executable + flags up to the first non-flag word, so 'git status'
/// becomes 'git ' and 'cargo test foo' becomes 'cargo test'. Keep it simple:
/// just take the first whitespace-delimited token + a trailing space.
fn derivePattern(preview: []const u8) []const u8 {
    const space = std.mem.indexOfScalar(u8, preview, ' ') orelse return preview;
    return preview[0 .. space + 1];
}

fn ask(tool: []const u8, preview: []const u8) !Decision {
    const stderr = std.io.getStdErr().writer();
    const stdin = std.io.getStdIn().reader();
    const pattern = derivePattern(preview);

    try ui.bell(stderr);
    try ui.permissionBox(stderr, tool, preview, pattern);

    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    stdin.streamUntilDelimiter(fbs.writer(), '\n', buf.len) catch |err| switch (err) {
        error.EndOfStream, error.StreamTooLong => {},
        else => return err,
    };
    const raw = fbs.getWritten();
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .deny;
    return switch (std.ascii.toLower(trimmed[0])) {
        'y' => .allow_once,
        'a' => .allow_session,
        'p' => .allow_pattern,
        else => .deny,
    };
}

test "permission: yolo allows everything" {
    var p = Permission.init(std.testing.allocator, true);
    defer p.deinit();
    try std.testing.expect(try p.check("bash", "rm -rf /"));
    try std.testing.expect(try p.check("write", "/etc/passwd"));
}

test "permission: read-only tools auto-allow without yolo" {
    var p = Permission.init(std.testing.allocator, false);
    defer p.deinit();
    try std.testing.expect(try p.check("read", "any path"));
    try std.testing.expect(try p.check("grep", "foo"));
    try std.testing.expect(try p.check("write_todo_list", ""));
}

test "permission: session allowlist persists across calls" {
    var p = Permission.init(std.testing.allocator, false);
    defer p.deinit();
    const owned = try p.alloc.dupe(u8, "bash");
    try p.session_allowlist.put(owned, {});
    try std.testing.expect(try p.check("bash", "anything"));
    try std.testing.expect(try p.check("bash", "rm -rf /"));
}

test "permission: pattern matches prefix" {
    var p = Permission.init(std.testing.allocator, false);
    defer p.deinit();
    try p.addPattern("bash", "git ");
    try std.testing.expect(try p.check("bash", "git status"));
    try std.testing.expect(try p.check("bash", "git diff foo bar"));
    // Doesn't apply to a different tool.
    try std.testing.expect(!p.matchesPattern("write", "git anything"));
}

test "permission: derivePattern takes first word + space" {
    try std.testing.expectEqualStrings("git ", derivePattern("git status"));
    try std.testing.expectEqualStrings("cargo ", derivePattern("cargo test foo"));
    // No space → entire preview.
    try std.testing.expectEqualStrings("ls", derivePattern("ls"));
}
