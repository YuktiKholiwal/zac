const std = @import("std");
const messages = @import("../messages.zig");
const mod = @import("mod.zig");
const path_guard = @import("../path_guard.zig");

pub const def = messages.Tool{
    .name = "edit",
    .description = "Substitute a specific span of text in a file. Pass `old_text` (the span to find) and `new_text` (its replacement). If `old_text` occurs more than once and `replace_all` is false, the call returns the line numbers of every match so you can add more surrounding context. Set `replace_all` to true to substitute every occurrence at once. Falls back to whitespace-tolerant matching when the exact span isn't found and suggests close matches.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {"type": "string", "description": "File to modify"},
    \\    "old_text": {"type": "string", "description": "Exact span to find — include enough surrounding context to be unique"},
    \\    "new_text": {"type": "string", "description": "Span to substitute in its place"},
    \\    "replace_all": {"type": "boolean", "description": "Substitute every match instead of just the unique one"}
    \\  },
    \\  "required": ["path", "old_text", "new_text"]
    \\}
    ,
};

/// How a match was discovered. Reported back to the model so it knows whether
/// to tighten its `old_text` next time.
const MatchKind = enum {
    exact,
    whitespace_tolerant,
};

const Match = struct {
    /// Byte offset in the canonical (LF-normalised) content.
    pos: usize,
    /// Number of bytes in `content` that this match consumes (may differ from
    /// `old_text.len` when whitespace normalisation grew/shrank the span).
    len: usize,
    kind: MatchKind,
};

pub fn execute(alloc: std.mem.Allocator, args: std.json.Value) anyerror![]u8 {
    const path = mod.getString(args, "path") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'path' is required", .{});
    const old_text = mod.getString(args, "old_text") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'old_text' is required", .{});
    const new_text = mod.getString(args, "new_text") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'new_text' is required", .{});
    const replace_all: bool = mod.getBool(args, "replace_all") orelse false;

    if (old_text.len == 0) {
        return try std.fmt.allocPrint(alloc, "Error: old_text must not be empty", .{});
    }

    if (!mod.isAllowOutside()) {
        const inside = path_guard.isInsideCwd(alloc, path) catch true;
        if (!inside) {
            return try std.fmt.allocPrint(
                alloc,
                "Error: refusing to edit outside the cwd: {s}\nRe-run with --allow-outside if intentional.",
                .{path},
            );
        }
    }

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error opening {s}: {s}", .{ path, @errorName(err) });
    };
    const raw = file.readToEndAlloc(alloc, 16 * 1024 * 1024) catch |err| {
        file.close();
        return try std.fmt.allocPrint(alloc, "Error reading {s}: {s}", .{ path, @errorName(err) });
    };
    file.close();
    defer alloc.free(raw);

    const had_crlf = std.mem.indexOf(u8, raw, "\r\n") != null;
    const content = try normaliseLf(alloc, raw, had_crlf);
    defer alloc.free(content);

    // Stage 1: exact matches.
    var matches = std.ArrayList(Match).init(alloc);
    defer matches.deinit();
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, old_text)) |pos| {
        try matches.append(.{ .pos = pos, .len = old_text.len, .kind = .exact });
        cursor = pos + old_text.len;
    }

    // Stage 2: whitespace-tolerant fallback if exact found nothing.
    var used_fallback = false;
    if (matches.items.len == 0) {
        try findWhitespaceTolerant(alloc, content, old_text, &matches);
        used_fallback = matches.items.len > 0;
    }

    if (matches.items.len == 0) {
        var msg = std.ArrayList(u8).init(alloc);
        errdefer msg.deinit();
        try msg.writer().print(
            "Error: `old_text` did not match anything in {s}, not even after collapsing whitespace.",
            .{path},
        );
        try suggestNearby(msg.writer(), content, old_text);
        return msg.toOwnedSlice();
    }

    if (matches.items.len > 1 and !replace_all) {
        var out = std.ArrayList(u8).init(alloc);
        errdefer out.deinit();
        try out.writer().print(
            "Error: `old_text` matched {d} times in {s}. Either pass `replace_all: true` or add more surrounding context to make it unique:\n",
            .{ matches.items.len, path },
        );
        for (matches.items) |m| {
            const line_no = lineNumber(content, m.pos);
            const tag: []const u8 = if (m.kind == .exact) "" else "  [via whitespace fallback]";
            try out.writer().print("  Line {d}{s}\n", .{ line_no, tag });
        }
        return out.toOwnedSlice();
    }

    // Splice: emit content[..pos], new_text, then content[pos+len..]
    var rebuilt = std.ArrayList(u8).init(alloc);
    errdefer rebuilt.deinit();
    var write_cursor: usize = 0;
    var replacements: usize = 0;
    for (matches.items) |m| {
        try rebuilt.appendSlice(content[write_cursor..m.pos]);
        try rebuilt.appendSlice(new_text);
        write_cursor = m.pos + m.len;
        replacements += 1;
        if (!replace_all) break;
    }
    try rebuilt.appendSlice(content[write_cursor..]);
    const final_lf = try rebuilt.toOwnedSlice();
    defer alloc.free(final_lf);

    const to_write = try restoreCrlf(alloc, final_lf, had_crlf);
    defer alloc.free(to_write);

    const out_file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error opening {s} for write: {s}", .{ path, @errorName(err) });
    };
    defer out_file.close();
    out_file.writeAll(to_write) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error writing {s}: {s}", .{ path, @errorName(err) });
    };

    const verb: []const u8 = if (used_fallback) "Edited (whitespace-tolerant match)" else "Edited";
    return try std.fmt.allocPrint(alloc, "{s} {s} — {d} replacement{s}", .{
        verb,
        path,
        replacements,
        if (replacements == 1) "" else "s",
    });
}

// ──────────────────────────────────────────────────────────────────────────

fn normaliseLf(alloc: std.mem.Allocator, raw: []const u8, had_crlf: bool) ![]u8 {
    if (!had_crlf) return try alloc.dupe(u8, raw);
    var buf = try std.ArrayList(u8).initCapacity(alloc, raw.len);
    errdefer buf.deinit();
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (i + 1 < raw.len and raw[i] == '\r' and raw[i + 1] == '\n') continue;
        try buf.append(raw[i]);
    }
    return buf.toOwnedSlice();
}

fn restoreCrlf(alloc: std.mem.Allocator, lf: []const u8, had_crlf: bool) ![]u8 {
    if (!had_crlf) return try alloc.dupe(u8, lf);
    var buf = try std.ArrayList(u8).initCapacity(alloc, lf.len + lf.len / 32);
    errdefer buf.deinit();
    for (lf) |b| {
        if (b == '\n') try buf.append('\r');
        try buf.append(b);
    }
    return buf.toOwnedSlice();
}

fn lineNumber(content: []const u8, byte_pos: usize) usize {
    var n: usize = 1;
    var i: usize = 0;
    while (i < byte_pos and i < content.len) : (i += 1) {
        if (content[i] == '\n') n += 1;
    }
    return n;
}

/// Reduces a string to its "shape": collapse any run of whitespace into a
/// single space. Used by the fallback matcher so trivial indentation /
/// trailing-whitespace differences don't block an obvious edit.
fn shape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, s.len);
    errdefer buf.deinit();
    var prev_ws = true;
    for (s) |c| {
        const is_ws = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (is_ws) {
            if (!prev_ws) try buf.append(' ');
            prev_ws = true;
        } else {
            try buf.append(c);
            prev_ws = false;
        }
    }
    return buf.toOwnedSlice();
}

/// Find positions where `needle` matches `content` after whitespace shaping.
/// We map shape-positions back to original-content positions by walking
/// both in lockstep.
fn findWhitespaceTolerant(
    alloc: std.mem.Allocator,
    content: []const u8,
    needle: []const u8,
    out_matches: *std.ArrayList(Match),
) !void {
    const shaped_needle = try shape(alloc, needle);
    defer alloc.free(shaped_needle);
    const trimmed_needle = std.mem.trim(u8, shaped_needle, " ");
    if (trimmed_needle.len == 0) return;

    // Walk the content, maintaining a sliding `shape` view from each start
    // position. Cheap-but-correct: try every starting byte.
    var start: usize = 0;
    while (start < content.len) : (start += 1) {
        const end = matchShapeFrom(content, start, trimmed_needle) orelse continue;
        try out_matches.append(.{
            .pos = start,
            .len = end - start,
            .kind = .whitespace_tolerant,
        });
        start = end - 1; // jump past this match on next iteration
    }
}

/// If the shape of content[start..] starts with `shaped_needle`, return the
/// byte index in content that the match ends at. Otherwise null.
fn matchShapeFrom(content: []const u8, start: usize, shaped_needle: []const u8) ?usize {
    var ci = start;
    var ni: usize = 0;
    // Skip leading whitespace in content so we can match against trimmed needle.
    while (ci < content.len and isWs(content[ci])) ci += 1;
    if (ci >= content.len) return null;
    while (ni < shaped_needle.len) {
        if (ci >= content.len) return null;
        const cn = shaped_needle[ni];
        const cc = content[ci];
        if (cn == ' ') {
            if (!isWs(cc)) return null;
            while (ci < content.len and isWs(content[ci])) ci += 1;
            ni += 1;
            continue;
        }
        if (cc != cn) return null;
        ci += 1;
        ni += 1;
    }
    return ci;
}

inline fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Best-effort suggestions when nothing matches. Looks for lines that share
/// the first non-empty line of `needle` as a substring.
fn suggestNearby(w: anytype, content: []const u8, needle: []const u8) !void {
    var key: []const u8 = "";
    var it = std.mem.splitScalar(u8, needle, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t");
        if (t.len > 0) {
            key = t;
            break;
        }
    }
    if (key.len < 3) return;

    var hits: usize = 0;
    var line_no: usize = 0;
    var lit = std.mem.splitScalar(u8, content, '\n');
    while (lit.next()) |line| {
        line_no += 1;
        if (std.mem.indexOf(u8, line, key) == null) continue;
        if (hits == 0) try w.writeAll("\n\nClose candidates by basic substring:\n");
        hits += 1;
        if (hits > 5) {
            try w.writeAll("  …\n");
            return;
        }
        const truncated = if (line.len > 120) line[0..120] else line;
        try w.print("  L{d}: {s}\n", .{ line_no, truncated });
    }
}
