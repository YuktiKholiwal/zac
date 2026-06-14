const std = @import("std");
const messages = @import("messages.zig");
const gateway = @import("gateway.zig");
const sse = @import("sse.zig");

/// If the most recent turn used more than THRESHOLD prompt tokens, summarise
/// the first 2/3 of msgs into a single system note and replace them.
/// Returns true if compaction happened.
pub const THRESHOLD_TOKENS: u64 = 100_000;

pub fn maybeCompact(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    cfg: gateway.Config,
    msgs: *std.ArrayList(messages.Message),
    last_prompt_tokens: u64,
    stderr_writer: anytype,
    force: bool,
) !bool {
    if (!shouldCompact(force, last_prompt_tokens, msgs.items.len)) {
        if (force and msgs.items.len < 6) try stderr_writer.writeAll("[compact: nothing to compact yet]\n");
        return false;
    }

    if (force) {
        try stderr_writer.writeAll("\n[compacting context — manual]\n");
    } else {
        try stderr_writer.print("\n[compacting context — {d} prompt tokens]\n", .{last_prompt_tokens});
    }

    // Keep msgs[0] (system) intact. Compact the first 2/3 of the rest.
    const history_start: usize = 1;
    const total_history = msgs.items.len - 1;
    const cut: usize = history_start + (total_history * 2 / 3);

    const summary = summarize(alloc, client, cfg, msgs.items[history_start..cut]) catch |err| {
        try stderr_writer.print("[compaction failed: {s}]\n", .{@errorName(err)});
        return false;
    };

    // Build the prefixed summary content; ownership moves into spliceSummary.
    const summary_msg_content = try std.fmt.allocPrint(
        alloc,
        "[Compacted history summary]\n{s}",
        .{summary},
    );
    alloc.free(summary);

    const removed = cut - history_start;
    try spliceSummary(alloc, msgs, history_start, cut, summary_msg_content);

    try stderr_writer.print("[compacted {d} messages into 1 summary]\n", .{removed});
    return true;
}

/// Whether maybeCompact should proceed, factored out so the policy is testable
/// without the network round-trip.
fn shouldCompact(force: bool, last_prompt_tokens: u64, msg_count: usize) bool {
    if (!force and last_prompt_tokens < THRESHOLD_TOKENS) return false;
    if (msg_count < 6) return false;
    return true;
}

/// Replace msgs[start..cut) with a single system message owning `content`,
/// freeing the messages it displaces. This is the index math compaction hinges
/// on, isolated from the network so it can be tested directly.
fn spliceSummary(
    alloc: std.mem.Allocator,
    msgs: *std.ArrayList(messages.Message),
    start: usize,
    cut: usize,
    content: []u8,
) !void {
    var i: usize = start;
    while (i < cut) : (i += 1) {
        const m = msgs.items[i];
        alloc.free(m.content);
        if (m.tool_call_id) |id| alloc.free(id);
        for (m.tool_calls) |c| {
            alloc.free(c.id);
            alloc.free(c.name);
            alloc.free(c.arguments);
        }
        if (m.tool_calls.len > 0) alloc.free(m.tool_calls);
    }

    const removed = cut - start;
    const new_len = msgs.items.len - removed + 1;
    if (removed > 1) {
        var j: usize = start + 1;
        while (j < new_len) : (j += 1) {
            msgs.items[j] = msgs.items[j + removed - 1];
        }
        msgs.shrinkRetainingCapacity(new_len);
    } else if (removed == 0) {
        try msgs.insert(start, undefined);
    }
    // removed == 1: shape already correct; overwrite below.

    msgs.items[start] = .{ .role = .system, .content = content };
}

fn summarize(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    cfg: gateway.Config,
    history: []const messages.Message,
) ![]u8 {
    var system_msg_content = std.ArrayList(u8).init(alloc);
    defer system_msg_content.deinit();
    try system_msg_content.writer().writeAll(
        \\You are summarising an in-progress conversation between a user and a coding agent.
        \\Output a concise summary that the agent can use to continue the work. Preserve:
        \\  - the user's goal and any constraints
        \\  - decisions made, including ones the user explicitly approved
        \\  - file paths touched and what changed in each
        \\  - any pending work or open questions
        \\  - tool errors that mattered
        \\Skip pleasantries and intermediate exploration. Aim for under 500 words. No preamble.
    );

    var user_msg_content = std.ArrayList(u8).init(alloc);
    defer user_msg_content.deinit();
    try user_msg_content.writer().writeAll("Conversation to summarise:\n\n");
    for (history) |m| {
        try user_msg_content.writer().print("=== {s} ===\n{s}\n", .{ @tagName(m.role), m.content });
        if (m.tool_calls.len > 0) {
            for (m.tool_calls) |tc| {
                try user_msg_content.writer().print("  tool_call: {s}({s})\n", .{ tc.name, tc.arguments });
            }
        }
    }

    var prompt_msgs = try alloc.alloc(messages.Message, 2);
    defer alloc.free(prompt_msgs);
    prompt_msgs[0] = .{ .role = .system, .content = system_msg_content.items };
    prompt_msgs[1] = .{ .role = .user, .content = user_msg_content.items };

    var stream = try gateway.chatStream(alloc, client, cfg, prompt_msgs, &.{});
    defer stream.deinit();

    const ReaderT = @TypeOf(stream.req.reader());
    var parser = sse.Parser(ReaderT).init(alloc, stream.req.reader());
    defer parser.deinit();

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    while (try parser.next()) |ev| switch (ev) {
        .text_delta => |t| try out.appendSlice(t),
        else => {},
    };

    return out.toOwnedSlice();
}

// ──────────────────────────────────────────────────────────────────────────
// Tests

const testing = std.testing;

test "compaction: shouldCompact respects threshold, force, and min length" {
    try testing.expect(!shouldCompact(false, THRESHOLD_TOKENS - 1, 10)); // under threshold
    try testing.expect(shouldCompact(false, THRESHOLD_TOKENS, 10)); // at threshold
    try testing.expect(shouldCompact(true, 0, 6)); // forced
    try testing.expect(!shouldCompact(true, 0, 5)); // too short even when forced
    try testing.expect(!shouldCompact(false, THRESHOLD_TOKENS, 5)); // too short
}

test "compaction: spliceSummary replaces a range with one system message" {
    const alloc = testing.allocator;
    var msgs = std.ArrayList(messages.Message).init(alloc);
    defer {
        for (msgs.items) |m| alloc.free(m.content);
        msgs.deinit();
    }
    // [system, m1, m2, m3, m4, m5] — content owned by alloc so splice can free.
    const labels = [_][]const u8{ "system", "m1", "m2", "m3", "m4", "m5" };
    const roles = [_]messages.Role{ .system, .user, .assistant, .user, .assistant, .user };
    for (labels, roles) |label, role| {
        try msgs.append(.{ .role = role, .content = try alloc.dupe(u8, label) });
    }

    const summary = try alloc.dupe(u8, "SUMMARY");
    // Replace [1,4): m1, m2, m3 → one summary message.
    try spliceSummary(alloc, &msgs, 1, 4, summary);

    try testing.expectEqual(@as(usize, 4), msgs.items.len); // system, SUMMARY, m4, m5
    try testing.expectEqualStrings("system", msgs.items[0].content);
    try testing.expectEqual(messages.Role.system, msgs.items[1].role);
    try testing.expectEqualStrings("SUMMARY", msgs.items[1].content);
    try testing.expectEqualStrings("m4", msgs.items[2].content);
    try testing.expectEqualStrings("m5", msgs.items[3].content);
}
