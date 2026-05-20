const std = @import("std");

pub const FinishReason = enum {
    stop,
    tool_calls,
    length,
    other,

    pub fn parse(s: []const u8) FinishReason {
        if (std.mem.eql(u8, s, "stop")) return .stop;
        if (std.mem.eql(u8, s, "tool_calls")) return .tool_calls;
        if (std.mem.eql(u8, s, "length")) return .length;
        return .other;
    }
};

pub const ToolCallDelta = struct {
    index: u32,
    id: ?[]const u8,
    name: ?[]const u8,
    args_fragment: ?[]const u8,
};

pub const Usage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
};

pub const Event = union(enum) {
    text_delta: []const u8,
    reasoning_delta: []const u8,
    tool_call_delta: ToolCallDelta,
    finish: FinishReason,
    usage: Usage,
    done,
};

/// Streaming SSE parser for OpenAI-compatible chat completions.
/// Owns no memory; event payload slices reference an internal scratch buffer
/// that is reused on each call to next().
pub fn Parser(comptime ReaderT: type) type {
    return struct {
        const Self = @This();

        reader: ReaderT,
        line_buf: std.ArrayList(u8),
        json_buf: std.ArrayList(u8),
        parsed: ?std.json.Parsed(std.json.Value) = null,
        /// Pending events queued from a single SSE line (one chunk can contain
        /// text + multiple tool_call deltas + finish_reason).
        pending: std.ArrayList(Event),
        scratch_arena: std.heap.ArenaAllocator,
        done: bool = false,

        pub fn init(alloc: std.mem.Allocator, reader: ReaderT) Self {
            return .{
                .reader = reader,
                .line_buf = std.ArrayList(u8).init(alloc),
                .json_buf = std.ArrayList(u8).init(alloc),
                .pending = std.ArrayList(Event).init(alloc),
                .scratch_arena = std.heap.ArenaAllocator.init(alloc),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.parsed) |*p| p.deinit();
            self.line_buf.deinit();
            self.json_buf.deinit();
            self.pending.deinit();
            self.scratch_arena.deinit();
        }

        pub fn next(self: *Self) !?Event {
            if (self.pending.items.len > 0) {
                return self.pending.orderedRemove(0);
            }
            if (self.done) return null;

            while (true) {
                self.line_buf.clearRetainingCapacity();
                self.reader.streamUntilDelimiter(self.line_buf.writer(), '\n', null) catch |err| switch (err) {
                    error.EndOfStream => {
                        self.done = true;
                        return null;
                    },
                    else => return err,
                };

                // Strip trailing \r.
                var line = self.line_buf.items;
                if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

                if (line.len == 0) continue; // separator between events
                if (std.mem.startsWith(u8, line, ":")) continue; // comment
                if (!std.mem.startsWith(u8, line, "data:")) continue;

                var payload = line[5..];
                if (payload.len > 0 and payload[0] == ' ') payload = payload[1..];

                if (std.mem.eql(u8, payload, "[DONE]")) {
                    self.done = true;
                    return Event{ .done = {} };
                }

                try self.parseChunk(payload);
                if (self.pending.items.len > 0) {
                    return self.pending.orderedRemove(0);
                }
                // Else loop and read more lines.
            }
        }

        fn parseChunk(self: *Self, json_str: []const u8) !void {
            // Reset scratch for this chunk's borrowed strings.
            _ = self.scratch_arena.reset(.retain_capacity);
            const scratch = self.scratch_arena.allocator();

            if (self.parsed) |*p| p.deinit();
            self.parsed = std.json.parseFromSlice(
                std.json.Value,
                self.line_buf.allocator,
                json_str,
                .{},
            ) catch return; // ignore malformed chunks

            const root = self.parsed.?.value;

            // Usage chunks come at the end with empty choices but a `usage` field.
            if (root.object.get("usage")) |u| {
                if (u == .object) {
                    var us: Usage = .{};
                    if (u.object.get("prompt_tokens")) |v| {
                        if (v == .integer) us.prompt_tokens = @intCast(v.integer);
                    }
                    if (u.object.get("completion_tokens")) |v| {
                        if (v == .integer) us.completion_tokens = @intCast(v.integer);
                    }
                    if (u.object.get("total_tokens")) |v| {
                        if (v == .integer) us.total_tokens = @intCast(v.integer);
                    }
                    if (us.total_tokens > 0 or us.prompt_tokens > 0) {
                        try self.pending.append(.{ .usage = us });
                    }
                }
            }

            const choices = root.object.get("choices") orelse return;
            if (choices != .array or choices.array.items.len == 0) return;
            const choice = choices.array.items[0];

            if (choice.object.get("delta")) |delta| {
                if (delta == .object) {
                    if (delta.object.get("content")) |c| {
                        if (c == .string and c.string.len > 0) {
                            const owned = try scratch.dupe(u8, c.string);
                            try self.pending.append(.{ .text_delta = owned });
                        }
                    }
                    // OpenAI o-series / Anthropic-via-Gateway emit one of these.
                    inline for ([_][]const u8{ "reasoning", "reasoning_content" }) |key| {
                        if (delta.object.get(key)) |r| {
                            if (r == .string and r.string.len > 0) {
                                const owned = try scratch.dupe(u8, r.string);
                                try self.pending.append(.{ .reasoning_delta = owned });
                            }
                        }
                    }
                    if (delta.object.get("tool_calls")) |tcs| {
                        if (tcs == .array) {
                            for (tcs.array.items) |tc| {
                                if (tc != .object) continue;
                                var d = ToolCallDelta{
                                    .index = 0,
                                    .id = null,
                                    .name = null,
                                    .args_fragment = null,
                                };
                                if (tc.object.get("index")) |i| {
                                    if (i == .integer) d.index = @intCast(i.integer);
                                }
                                if (tc.object.get("id")) |id| {
                                    if (id == .string) d.id = try scratch.dupe(u8, id.string);
                                }
                                if (tc.object.get("function")) |f| {
                                    if (f == .object) {
                                        if (f.object.get("name")) |n| {
                                            if (n == .string) d.name = try scratch.dupe(u8, n.string);
                                        }
                                        if (f.object.get("arguments")) |a| {
                                            if (a == .string) d.args_fragment = try scratch.dupe(u8, a.string);
                                        }
                                    }
                                }
                                try self.pending.append(.{ .tool_call_delta = d });
                            }
                        }
                    }
                }
            }

            if (choice.object.get("finish_reason")) |fr| {
                if (fr == .string) {
                    try self.pending.append(.{ .finish = FinishReason.parse(fr.string) });
                }
            }
        }
    };
}

test "sse: text deltas + finish + done" {
    const alloc = std.testing.allocator;
    const raw =
        "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\" world\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";

    var fbs = std.io.fixedBufferStream(raw);
    var parser = Parser(@TypeOf(fbs.reader())).init(alloc, fbs.reader());
    defer parser.deinit();

    var got_text = std.ArrayList(u8).init(alloc);
    defer got_text.deinit();
    var saw_finish = false;
    var saw_done = false;

    while (try parser.next()) |ev| switch (ev) {
        .text_delta => |t| try got_text.appendSlice(t),
        .finish => |f| {
            try std.testing.expectEqual(FinishReason.stop, f);
            saw_finish = true;
        },
        .done => saw_done = true,
        else => {},
    };

    try std.testing.expectEqualStrings("hello world", got_text.items);
    try std.testing.expect(saw_finish);
    try std.testing.expect(saw_done);
}

test "sse: tool_call deltas accumulate across chunks" {
    const alloc = std.testing.allocator;
    const raw =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"x\\\"}\"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";

    var fbs = std.io.fixedBufferStream(raw);
    var parser = Parser(@TypeOf(fbs.reader())).init(alloc, fbs.reader());
    defer parser.deinit();

    var args = std.ArrayList(u8).init(alloc);
    defer args.deinit();
    var saw_id = false;
    var saw_name = false;
    var saw_finish_tc = false;

    while (try parser.next()) |ev| switch (ev) {
        .tool_call_delta => |d| {
            if (d.id) |id| {
                try std.testing.expectEqualStrings("call_1", id);
                saw_id = true;
            }
            if (d.name) |n| {
                try std.testing.expectEqualStrings("read", n);
                saw_name = true;
            }
            if (d.args_fragment) |a| try args.appendSlice(a);
            try std.testing.expectEqual(@as(u32, 0), d.index);
        },
        .finish => |f| {
            if (f == .tool_calls) saw_finish_tc = true;
        },
        else => {},
    };

    try std.testing.expect(saw_id);
    try std.testing.expect(saw_name);
    try std.testing.expect(saw_finish_tc);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", args.items);
}

test "sse: usage chunk" {
    const alloc = std.testing.allocator;
    const raw =
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}\n\n" ++
        "data: [DONE]\n\n";

    var fbs = std.io.fixedBufferStream(raw);
    var parser = Parser(@TypeOf(fbs.reader())).init(alloc, fbs.reader());
    defer parser.deinit();

    var saw_usage = false;
    while (try parser.next()) |ev| switch (ev) {
        .usage => |u| {
            try std.testing.expectEqual(@as(u64, 10), u.prompt_tokens);
            try std.testing.expectEqual(@as(u64, 5), u.completion_tokens);
            saw_usage = true;
        },
        else => {},
    };
    try std.testing.expect(saw_usage);
}
