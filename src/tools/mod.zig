const std = @import("std");
const messages = @import("../messages.zig");
const permission_mod = @import("../permission.zig");

const read_tool = @import("read.zig");
const write_tool = @import("write.zig");
const edit_tool = @import("edit.zig");
const bash_tool = @import("bash.zig");
const grep_tool = @import("grep.zig");
const find_tool = @import("find_files.zig");
const list_tool = @import("list_dir.zig");
const todo_tool = @import("todo.zig");

/// Set once at startup. write/edit refuse paths outside cwd unless true.
var allow_outside: bool = false;

pub fn setAllowOutside(v: bool) void {
    allow_outside = v;
}

pub fn isAllowOutside() bool {
    return allow_outside;
}

/// Shared freshness tracker — set by main.zig at startup. Tools that read
/// files register them here so stale-context refresh can detect changes.
const freshness = @import("../freshness.zig");
var tracker: ?*freshness.FreshnessTracker = null;

pub fn setTracker(t: *freshness.FreshnessTracker) void {
    tracker = t;
}

pub fn observeRead(path: []const u8) void {
    if (tracker) |t| {
        t.observe(path) catch {};
    }
}

/// Snapshot of file contents at the last read (for diff-aware re-reads).
pub fn previousContentFor(path: []const u8) ?[]const u8 {
    if (tracker) |t| return t.previousContent(path);
    return null;
}

pub fn recordContentFor(path: []const u8, content: []const u8) void {
    if (tracker) |t| {
        t.recordContent(path, content) catch {};
    }
}

pub const ToolError = error{
    Unknown,
    BadArguments,
    Io,
    OutOfMemory,
    NotFound,
    AmbiguousMatch,
};

pub const Executor = *const fn (std.mem.Allocator, std.json.Value) anyerror![]u8;

pub const Registered = struct {
    def: messages.Tool,
    execute: Executor,
};

pub fn all() []const Registered {
    return &.{
        .{ .def = read_tool.def, .execute = read_tool.execute },
        .{ .def = write_tool.def, .execute = write_tool.execute },
        .{ .def = edit_tool.def, .execute = edit_tool.execute },
        .{ .def = bash_tool.def, .execute = bash_tool.execute },
        .{ .def = grep_tool.def, .execute = grep_tool.execute },
        .{ .def = find_tool.def, .execute = find_tool.execute },
        .{ .def = list_tool.def, .execute = list_tool.execute },
        .{ .def = todo_tool.def, .execute = todo_tool.execute },
    };
}

pub fn definitions(alloc: std.mem.Allocator) ![]messages.Tool {
    const reg = all();
    var out = try alloc.alloc(messages.Tool, reg.len);
    for (reg, 0..) |r, i| out[i] = r.def;
    return out;
}

/// Dispatches a single tool call. arguments_json is the raw JSON string of args.
/// Returns owned output (caller frees).
pub fn dispatch(
    alloc: std.mem.Allocator,
    perm: *permission_mod.Permission,
    name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const args_str = if (arguments_json.len == 0) "{}" else arguments_json;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, args_str, .{}) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error: invalid tool arguments JSON: {s}", .{@errorName(err)});
    };
    defer parsed.deinit();

    for (all()) |r| {
        if (std.mem.eql(u8, r.def.name, name)) {
            const preview = previewArgs(parsed.value);
            const allowed = perm.check(name, preview) catch |err| {
                return try std.fmt.allocPrint(alloc, "Error: permission check failed: {s}", .{@errorName(err)});
            };
            if (!allowed) {
                return try std.fmt.allocPrint(alloc, "Denied by user.", .{});
            }
            return r.execute(alloc, parsed.value) catch |err| {
                return try std.fmt.allocPrint(alloc, "Error: {s}", .{@errorName(err)});
            };
        }
    }
    return try std.fmt.allocPrint(alloc, "Error: unknown tool '{s}'", .{name});
}

/// Build a short preview string for the permission prompt — favours the most
/// human-meaningful field of the args.
var preview_buf: [256]u8 = undefined;
fn previewArgs(v: std.json.Value) []const u8 {
    if (v != .object) return "";
    for ([_][]const u8{ "command", "path", "pattern" }) |key| {
        if (v.object.get(key)) |val| {
            if (val == .string) {
                const s = val.string;
                const n = @min(s.len, preview_buf.len);
                @memcpy(preview_buf[0..n], s[0..n]);
                return preview_buf[0..n];
            }
        }
    }
    return "";
}

pub fn getString(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const v = obj.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

pub fn getInt(obj: std.json.Value, key: []const u8) ?i64 {
    if (obj != .object) return null;
    const v = obj.object.get(key) orelse return null;
    if (v != .integer) return null;
    return v.integer;
}

pub fn getBool(obj: std.json.Value, key: []const u8) ?bool {
    if (obj != .object) return null;
    const v = obj.object.get(key) orelse return null;
    if (v != .bool) return null;
    return v.bool;
}
