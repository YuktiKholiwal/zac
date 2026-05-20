const std = @import("std");
const messages = @import("messages.zig");

const SESSION_DIR = ".zac";
const SESSION_FILE = "last_session.json";

pub fn pathInHome(alloc: std.mem.Allocator) ![]u8 {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return error.NoHome;
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &.{ home, SESSION_DIR, SESSION_FILE });
}

/// Saves messages as JSON to ~/.zac/last_session.json.
pub fn save(alloc: std.mem.Allocator, msgs: []const messages.Message) !void {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return error.NoHome;
    defer alloc.free(home);

    const dir_path = try std.fs.path.join(alloc, &.{ home, SESSION_DIR });
    defer alloc.free(dir_path);
    try std.fs.cwd().makePath(dir_path);

    const file_path = try std.fs.path.join(alloc, &.{ dir_path, SESSION_FILE });
    defer alloc.free(file_path);

    var file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
    defer file.close();

    var jws = std.json.writeStream(file.writer(), .{});
    try jws.beginArray();
    for (msgs) |m| try jws.write(m);
    try jws.endArray();
}

/// Loads messages from ~/.zac/last_session.json. The returned slice and all
/// inner []u8s are owned by `alloc` — caller frees via freeMessages.
pub fn load(alloc: std.mem.Allocator) !std.ArrayList(messages.Message) {
    const path = try pathInHome(alloc);
    defer alloc.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NoPriorSession,
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(alloc, 32 * 1024 * 1024);
    defer alloc.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, contents, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.MalformedSession;

    var out = std.ArrayList(messages.Message).init(alloc);
    errdefer out.deinit();

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const role_str = (item.object.get("role") orelse continue);
        if (role_str != .string) continue;
        const role = parseRole(role_str.string) orelse continue;

        const content_v = item.object.get("content") orelse continue;
        const content = if (content_v == .string) content_v.string else "";

        var tcid: ?[]u8 = null;
        if (item.object.get("tool_call_id")) |v| {
            if (v == .string) tcid = try alloc.dupe(u8, v.string);
        }

        var calls: []messages.ToolCall = &.{};
        if (item.object.get("tool_calls")) |tcs| {
            if (tcs == .array and tcs.array.items.len > 0) {
                var buf = try alloc.alloc(messages.ToolCall, tcs.array.items.len);
                var i: usize = 0;
                for (tcs.array.items) |tc| {
                    if (tc != .object) continue;
                    const fn_obj = tc.object.get("function") orelse continue;
                    if (fn_obj != .object) continue;
                    const id_v = tc.object.get("id") orelse continue;
                    const name_v = fn_obj.object.get("name") orelse continue;
                    const args_v = fn_obj.object.get("arguments") orelse continue;
                    if (id_v != .string or name_v != .string or args_v != .string) continue;
                    buf[i] = .{
                        .id = try alloc.dupe(u8, id_v.string),
                        .name = try alloc.dupe(u8, name_v.string),
                        .arguments = try alloc.dupe(u8, args_v.string),
                    };
                    i += 1;
                }
                calls = buf[0..i];
            }
        }

        try out.append(.{
            .role = role,
            .content = try alloc.dupe(u8, content),
            .tool_calls = calls,
            .tool_call_id = tcid,
        });
    }

    return out;
}

fn parseRole(s: []const u8) ?messages.Role {
    if (std.mem.eql(u8, s, "system")) return .system;
    if (std.mem.eql(u8, s, "user")) return .user;
    if (std.mem.eql(u8, s, "assistant")) return .assistant;
    if (std.mem.eql(u8, s, "tool")) return .tool;
    return null;
}

test "session: parseRole" {
    try std.testing.expectEqual(messages.Role.system, parseRole("system").?);
    try std.testing.expectEqual(messages.Role.user, parseRole("user").?);
    try std.testing.expectEqual(messages.Role.assistant, parseRole("assistant").?);
    try std.testing.expectEqual(messages.Role.tool, parseRole("tool").?);
    try std.testing.expect(parseRole("nope") == null);
}

test "session: JSON shape of a saved message round-trips" {
    const alloc = std.testing.allocator;

    // Build a small history.
    const calls = [_]messages.ToolCall{
        .{ .id = "call_1", .name = "read", .arguments = "{\"path\":\"x\"}" },
    };
    const msgs = [_]messages.Message{
        .{ .role = .system, .content = "you are zac" },
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .content = "", .tool_calls = &calls },
        .{ .role = .tool, .content = "ok", .tool_call_id = "call_1" },
    };

    // Serialize manually (matches what save() writes).
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    var jws = std.json.writeStream(buf.writer(), .{});
    try jws.beginArray();
    for (msgs) |m| try jws.write(m);
    try jws.endArray();

    // Verify the JSON has the markers we depend on for load().
    const json = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"read\"") != null);
    // The arguments field is itself a JSON string, so the inner JSON appears
    // with escaped quotes: "arguments":"{\"path\":\"x\"}"
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"path\\\":\\\"x\\\"") != null);
}
