const std = @import("std");
const messages = @import("messages.zig");
const gateway = @import("gateway.zig");
const sse = @import("sse.zig");
const tools = @import("tools/mod.zig");
const cancel = @import("cancel.zig");
const permission_mod = @import("permission.zig");
const ui = @import("ui.zig");

pub const MAX_TURNS: usize = 25;

/// Real transport: each turn opens an HTTP stream to the gateway and parses its
/// SSE body. `run` is generic over the transport (see `transport: anytype`) so
/// tests can substitute a scripted source without touching the network.
pub const GatewayParser = sse.Parser(std.http.Client.Request.Reader);

pub const GatewayTransport = struct {
    client: *std.http.Client,

    pub fn openTurn(
        self: *GatewayTransport,
        alloc: std.mem.Allocator,
        cfg: gateway.Config,
        msgs: []const messages.Message,
        tool_defs: []const messages.Tool,
    ) !GatewayTurn {
        // Box the stream so its address is stable: the parser's reader holds a
        // pointer into stream.req, which must outlive returning the turn by value.
        const stream = try alloc.create(gateway.Stream);
        errdefer alloc.destroy(stream);
        stream.* = try gateway.chatStream(alloc, self.client, cfg, msgs, tool_defs);
        errdefer stream.deinit();
        return .{
            .alloc = alloc,
            .stream = stream,
            .parser = GatewayParser.init(alloc, stream.req.reader()),
        };
    }
};

pub const GatewayTurn = struct {
    alloc: std.mem.Allocator,
    stream: *gateway.Stream,
    parser: GatewayParser,

    pub fn next(self: *GatewayTurn) !?sse.Event {
        return self.parser.next();
    }
    pub fn deinit(self: *GatewayTurn) void {
        self.parser.deinit();
        self.stream.deinit();
        self.alloc.destroy(self.stream);
    }
};

/// One conversation turn. Streams text to `stdout_writer` and runs any tool
/// calls, looping until the model emits finish_reason=stop (or we hit MAX_TURNS).
/// Mutates `msgs` in place: appends the assistant turn and any tool messages.
/// `transport` supplies each turn's event stream — see `GatewayTransport`.
pub fn run(
    alloc: std.mem.Allocator,
    cfg: gateway.Config,
    perm: *permission_mod.Permission,
    msgs: *std.ArrayList(messages.Message),
    tool_defs: []const messages.Tool,
    stdout_writer: anytype,
    transport: anytype,
) !sse.Usage {
    var last_usage: sse.Usage = .{};
    var turn: usize = 0;
    while (turn < MAX_TURNS) : (turn += 1) {
        var ts = try transport.openTurn(alloc, cfg, msgs.items, tool_defs);
        defer ts.deinit();

        var text = std.ArrayList(u8).init(alloc);
        defer text.deinit();
        var line_renderer = ui.LineRenderer.init(alloc);
        defer line_renderer.deinit();

        var pending = std.ArrayList(messages.OwnedToolCall).init(alloc);
        defer {
            for (pending.items) |*c| c.deinit();
            pending.deinit();
        }

        var finish: sse.FinishReason = .other;
        var cancelled = false;
        var turn_usage: sse.Usage = .{};
        var reasoning_open = false;

        event_loop: while (try ts.next()) |ev| {
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
                    try line_renderer.feed(stdout_writer, t);
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
        try line_renderer.flush(stdout_writer);

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

        // Run the tools whenever the model emitted any. We intentionally do not
        // gate on finish_reason == tool_calls: some providers/gateways emit tool
        // calls but report finish_reason "stop", which would otherwise strand
        // the calls in history unexecuted and silently end the turn.
        if (owned_calls.len == 0) {
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
            try ui.toolCallStart(stdout_writer, alloc, call.name, path_opt, summary(call.arguments));

            var tool_timer = std.time.Timer.start() catch null;
            const result = try tools.dispatch(alloc, perm, call.name, call.arguments);
            const tool_ms: u64 = if (tool_timer) |*t| t.read() / std.time.ns_per_ms else 0;
            const is_edit = std.mem.eql(u8, call.name, "edit");
            try ui.toolCallFinish(
                stdout_writer,
                alloc,
                call.name,
                path_opt,
                summary(call.arguments),
                result,
                is_edit,
                tool_ms,
            );

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

// ──────────────────────────────────────────────────────────────────────────
// Tests

const testing = std.testing;

/// Test transport: replays one canned SSE byte-script per turn instead of
/// hitting the network. Mirrors GatewayTransport's shape (openTurn → a turn
/// with next()/deinit()).
const ScriptParser = sse.Parser(std.io.FixedBufferStream([]const u8).Reader);

const ScriptTransport = struct {
    scripts: []const []const u8,
    idx: usize = 0,

    fn openTurn(
        self: *ScriptTransport,
        alloc: std.mem.Allocator,
        cfg: gateway.Config,
        msgs: []const messages.Message,
        tool_defs: []const messages.Tool,
    ) !ScriptTurn {
        _ = cfg;
        _ = msgs;
        _ = tool_defs;
        const script = self.scripts[self.idx];
        self.idx += 1;
        // Box the buffer stream so the parser's reader pointer stays valid.
        const fbs = try alloc.create(std.io.FixedBufferStream([]const u8));
        errdefer alloc.destroy(fbs);
        fbs.* = std.io.fixedBufferStream(script);
        return .{
            .alloc = alloc,
            .fbs = fbs,
            .parser = ScriptParser.init(alloc, fbs.reader()),
        };
    }
};

const ScriptTurn = struct {
    alloc: std.mem.Allocator,
    fbs: *std.io.FixedBufferStream([]const u8),
    parser: ScriptParser,

    fn next(self: *ScriptTurn) !?sse.Event {
        return self.parser.next();
    }
    fn deinit(self: *ScriptTurn) void {
        self.parser.deinit();
        self.alloc.destroy(self.fbs);
    }
};

fn freeMsgs(alloc: std.mem.Allocator, msgs: *std.ArrayList(messages.Message)) void {
    for (msgs.items) |m| {
        alloc.free(m.content);
        if (m.tool_call_id) |id| alloc.free(id);
        for (m.tool_calls) |c| {
            alloc.free(c.id);
            alloc.free(c.name);
            alloc.free(c.arguments);
        }
        if (m.tool_calls.len > 0) alloc.free(m.tool_calls);
    }
    msgs.deinit();
}

test "agent: full loop runs a tool call then finishes on stop" {
    const alloc = testing.allocator;
    ui.init(true); // no color; loop output is discarded to null_writer anyway

    var perm = permission_mod.Permission.init(alloc, false); // ls is read-only → auto-allows
    defer perm.deinit();

    var msgs = std.ArrayList(messages.Message).init(alloc);
    defer freeMsgs(alloc, &msgs);
    try msgs.append(.{ .role = .user, .content = try alloc.dupe(u8, "list files") });

    const tool_defs = try tools.definitions(alloc);
    defer alloc.free(tool_defs);

    // Turn 1: the model calls `ls .`. Turn 2: it replies and stops.
    const turn1 =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"ls\",\"arguments\":\"{\\\"path\\\":\\\".\\\"}\"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const turn2 =
        "data: {\"choices\":[{\"delta\":{\"content\":\"all done\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const scripts = [_][]const u8{ turn1, turn2 };
    var transport = ScriptTransport{ .scripts = &scripts };

    const cfg = gateway.Config{
        .base_url = @constCast(@as([]const u8, "u")),
        .api_key = @constCast(@as([]const u8, "k")),
        .model = @constCast(@as([]const u8, "m")),
    };

    _ = try run(alloc, cfg, &perm, &msgs, tool_defs, std.io.null_writer, &transport);

    // Expect history: user, assistant(tool_calls), tool result, assistant("all done").
    try testing.expectEqual(@as(usize, 4), msgs.items.len);
    try testing.expectEqual(messages.Role.assistant, msgs.items[1].role);
    try testing.expectEqual(@as(usize, 1), msgs.items[1].tool_calls.len);
    try testing.expectEqualStrings("ls", msgs.items[1].tool_calls[0].name);
    try testing.expectEqual(messages.Role.tool, msgs.items[2].role);
    try testing.expectEqualStrings("all done", msgs.items[3].content);
}
