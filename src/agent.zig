const std = @import("std");
const messages = @import("messages.zig");
const gateway = @import("gateway.zig");
const sse = @import("sse.zig");
const tools = @import("tools/mod.zig");
const cancel = @import("cancel.zig");
const permission_mod = @import("permission.zig");
const ui = @import("ui.zig");

pub const MAX_TURNS: usize = 25;

/// One conversation turn. Streams text to `stdout_writer` and runs any tool
/// calls, looping until the model emits finish_reason=stop (or we hit MAX_TURNS).
/// Mutates `msgs` in place: appends the assistant turn and any tool messages.
pub fn run(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    cfg: gateway.Config,
    perm: *permission_mod.Permission,
    msgs: *std.ArrayList(messages.Message),
    tool_defs: []const messages.Tool,
    stdout_writer: anytype,
) !sse.Usage {
    var last_usage: sse.Usage = .{};
    var turn: usize = 0;
    while (turn < MAX_TURNS) : (turn += 1) {
        var stream = try gateway.chatStream(alloc, client, cfg, msgs.items, tool_defs);
        defer stream.deinit();

        const ReaderT = @TypeOf(stream.req.reader());
        var parser = sse.Parser(ReaderT).init(alloc, stream.req.reader());
        defer parser.deinit();

        var text = std.ArrayList(u8).init(alloc);
        defer text.deinit();
        var md_state = ui.MdState{};

        var pending = std.ArrayList(messages.OwnedToolCall).init(alloc);
        defer {
            for (pending.items) |*c| c.deinit();
            pending.deinit();
        }

        var finish: sse.FinishReason = .other;
        var cancelled = false;
        var turn_usage: sse.Usage = .{};
        var reasoning_open = false;

        event_loop: while (try parser.next()) |ev| {
            if (cancel.take()) {
                cancelled = true;
                break :event_loop;
            }
            switch (ev) {
                .text_delta => |t| {
                    if (reasoning_open) {
                        try stdout_writer.writeAll("\x1b[0m\n");
                        reasoning_open = false;
                    }
                    try text.appendSlice(t);
                    try ui.renderMarkdown(stdout_writer, &md_state, t);
                },
                .reasoning_delta => |r| {
                    if (!cfg.show_reasoning) continue;
                    if (!reasoning_open) {
                        try stdout_writer.writeAll("\x1b[2m");
                        reasoning_open = true;
                    }
                    try stdout_writer.writeAll(r);
                },
                .tool_call_delta => |d| {
                    while (pending.items.len <= d.index) {
                        try pending.append(messages.OwnedToolCall.init(alloc));
                    }
                    var slot = &pending.items[d.index];
                    if (d.id) |id| try slot.id.appendSlice(id);
                    if (d.name) |n| try slot.name.appendSlice(n);
                    if (d.args_fragment) |a| try slot.arguments.appendSlice(a);
                },
                .finish => |f| {
                    finish = f;
                },
                .usage => |u| {
                    turn_usage = u;
                },
                .done => break :event_loop,
            }
        }

        if (reasoning_open) try stdout_writer.writeAll("\x1b[0m");

        if (turn_usage.total_tokens > 0 or turn_usage.prompt_tokens > 0) {
            last_usage = turn_usage;
        }

        if (cancelled) {
            try stdout_writer.writeAll("\n[cancelled]\n");
            return last_usage;
        }

        // Build the assistant message and append to history.
        var owned_calls = try alloc.alloc(messages.ToolCall, pending.items.len);
        for (pending.items, 0..) |*c, i| {
            owned_calls[i] = .{
                .id = try alloc.dupe(u8, c.id.items),
                .name = try alloc.dupe(u8, c.name.items),
                .arguments = try alloc.dupe(u8, c.arguments.items),
            };
        }
        const assistant_content = try alloc.dupe(u8, text.items);
        try msgs.append(.{
            .role = .assistant,
            .content = assistant_content,
            .tool_calls = owned_calls,
        });

        if (finish != .tool_calls or owned_calls.len == 0) {
            try stdout_writer.writeAll("\n");
            return last_usage;
        }

        // Run each tool, append a tool message per call.
        for (owned_calls) |call| {
            if (cancel.take()) {
                try stdout_writer.writeAll("\n[cancelled]\n");
                return last_usage;
            }
            // Pull a file path out of the args JSON if present.
            const path_opt = extractPath(alloc, call.arguments);
            defer if (path_opt) |p| alloc.free(p);
            try ui.toolCall(stdout_writer, alloc, call.name, path_opt, summary(call.arguments));

            const result = try tools.dispatch(alloc, perm, call.name, call.arguments);
            const is_edit = std.mem.eql(u8, call.name, "edit");
            try ui.toolResult(stdout_writer, result, is_edit);

            try msgs.append(.{
                .role = .tool,
                .tool_call_id = try alloc.dupe(u8, call.id),
                .content = result,
            });
        }
    }

    try stdout_writer.print("\n[max turns ({d}) reached]\n", .{MAX_TURNS});
    return last_usage;
}

fn summary(args: []const u8) []const u8 {
    if (args.len <= 80) return args;
    return args[0..80];
}

/// Best-effort extraction of a "path"/"command"/"pattern" field from JSON args.
/// Returns an allocator-owned dupe so callers can free uniformly.
fn extractPath(alloc: std.mem.Allocator, args_json: []const u8) ?[]u8 {
    if (args_json.len == 0) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    for ([_][]const u8{ "path", "command", "pattern" }) |key| {
        if (parsed.value.object.get(key)) |v| {
            if (v == .string) {
                const dup = alloc.dupe(u8, v.string) catch return null;
                return dup;
            }
        }
    }
    return null;
}
