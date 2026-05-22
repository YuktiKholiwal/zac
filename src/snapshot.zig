const std = @import("std");
const messages = @import("messages.zig");
const session = @import("session.zig");

const SNAPSHOTS_DIR = ".zac/snapshots";

/// Saves the current conversation history + a snapshot of all files the tracker
/// has observed. Snapshots live under ~/.zac/snapshots/<name>/.
pub fn save(
    alloc: std.mem.Allocator,
    name: []const u8,
    msgs: []const messages.Message,
    tracked_files: [][]const u8,
) !void {
    if (!validName(name)) return error.InvalidSnapshotName;

    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return error.NoHome;
    defer alloc.free(home);

    const dir_path = try std.fs.path.join(alloc, &.{ home, SNAPSHOTS_DIR, name });
    defer alloc.free(dir_path);
    try std.fs.cwd().makePath(dir_path);

    // 1. Conversation as JSON.
    const conv_path = try std.fs.path.join(alloc, &.{ dir_path, "conversation.json" });
    defer alloc.free(conv_path);
    {
        var file = try std.fs.cwd().createFile(conv_path, .{ .truncate = true });
        defer file.close();
        var jws = std.json.writeStream(file.writer(), .{});
        try jws.beginArray();
        for (msgs) |m| try jws.write(m);
        try jws.endArray();
    }

    // 2. Files: copied into <snap>/files/ preserving relative paths.
    const files_root = try std.fs.path.join(alloc, &.{ dir_path, "files" });
    defer alloc.free(files_root);
    try std.fs.cwd().makePath(files_root);

    var saved: usize = 0;
    for (tracked_files) |rel_path| {
        const src = std.fs.cwd().openFile(rel_path, .{}) catch continue;
        defer src.close();
        const data = src.readToEndAlloc(alloc, 16 * 1024 * 1024) catch continue;
        defer alloc.free(data);

        const dst_path = try std.fs.path.join(alloc, &.{ files_root, rel_path });
        defer alloc.free(dst_path);
        if (std.fs.path.dirname(dst_path)) |d| try std.fs.cwd().makePath(d);
        var dst = std.fs.cwd().createFile(dst_path, .{ .truncate = true }) catch continue;
        defer dst.close();
        dst.writeAll(data) catch continue;
        saved += 1;
    }
}

/// Restores a snapshot: replaces msgs with the saved conversation, copies files
/// back to their original cwd paths.
pub fn restore(
    alloc: std.mem.Allocator,
    name: []const u8,
    msgs: *std.ArrayList(messages.Message),
    free_messages_fn: *const fn (std.mem.Allocator, *std.ArrayList(messages.Message)) void,
) !usize {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return error.NoHome;
    defer alloc.free(home);

    const dir_path = try std.fs.path.join(alloc, &.{ home, SNAPSHOTS_DIR, name });
    defer alloc.free(dir_path);

    // Verify existence.
    var dir = std.fs.cwd().openDir(dir_path, .{}) catch return error.SnapshotNotFound;
    dir.close();

    // 1. Restore conversation.
    const conv_path = try std.fs.path.join(alloc, &.{ dir_path, "conversation.json" });
    defer alloc.free(conv_path);
    const conv_file = std.fs.cwd().openFile(conv_path, .{}) catch return error.SnapshotCorrupt;
    const conv_bytes = try conv_file.readToEndAlloc(alloc, 64 * 1024 * 1024);
    conv_file.close();
    defer alloc.free(conv_bytes);

    var loaded = try parseMessages(alloc, conv_bytes);
    free_messages_fn(alloc, msgs);
    msgs.* = loaded;
    loaded = undefined; // ownership moved

    // 2. Restore files.
    const files_root = try std.fs.path.join(alloc, &.{ dir_path, "files" });
    defer alloc.free(files_root);
    return copyTree(alloc, files_root, ".");
}

pub fn list(alloc: std.mem.Allocator, writer: anytype) !void {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return error.NoHome;
    defer alloc.free(home);
    const root = try std.fs.path.join(alloc, &.{ home, SNAPSHOTS_DIR });
    defer alloc.free(root);

    var d = std.fs.cwd().openDir(root, .{ .iterate = true }) catch {
        try writer.writeAll("[no snapshots]\n");
        return;
    };
    defer d.close();

    var it = d.iterate();
    var any = false;
    while (try it.next()) |e| {
        if (e.kind != .directory) continue;
        try writer.print("  {s}\n", .{e.name});
        any = true;
    }
    if (!any) try writer.writeAll("[no snapshots]\n");
}

// ──────────────────────────────────────────────────────────────────────────

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    if (name[0] == '.') return false;
    return true;
}

fn parseMessages(alloc: std.mem.Allocator, body: []const u8) !std.ArrayList(messages.Message) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.MalformedSnapshot;

    var out = std.ArrayList(messages.Message).init(alloc);
    errdefer out.deinit();

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const role_str = item.object.get("role") orelse continue;
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

/// Recursively copies src_root tree onto dst_root, overwriting files.
/// Returns the number of files copied.
fn copyTree(alloc: std.mem.Allocator, src_root: []const u8, dst_root: []const u8) !usize {
    var copied: usize = 0;
    var src = std.fs.cwd().openDir(src_root, .{ .iterate = true }) catch return 0;
    defer src.close();

    var walker = try src.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const src_path = try std.fs.path.join(alloc, &.{ src_root, entry.path });
        defer alloc.free(src_path);
        const dst_path = try std.fs.path.join(alloc, &.{ dst_root, entry.path });
        defer alloc.free(dst_path);

        if (std.fs.path.dirname(dst_path)) |d| try std.fs.cwd().makePath(d);

        const data = std.fs.cwd().readFileAlloc(alloc, src_path, 16 * 1024 * 1024) catch continue;
        defer alloc.free(data);

        var dst = std.fs.cwd().createFile(dst_path, .{ .truncate = true }) catch continue;
        defer dst.close();
        dst.writeAll(data) catch continue;
        copied += 1;
    }
    return copied;
}
