const std = @import("std");
const messages = @import("../messages.zig");
const mod = @import("mod.zig");
const path_guard = @import("../path_guard.zig");

pub const def = messages.Tool{
    .name = "edit",
    .description = "Edit a file by replacing exact text. If old_text appears multiple times and replace_all is false, returns line numbers of all matches so you can disambiguate. Set replace_all=true to replace every occurrence.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {"type": "string"},
    \\    "old_text": {"type": "string"},
    \\    "new_text": {"type": "string"},
    \\    "replace_all": {"type": "boolean"}
    \\  },
    \\  "required": ["path", "old_text", "new_text"]
    \\}
    ,
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

    // Normalise to LF; remember if input was CRLF so we restore on write.
    const had_crlf = std.mem.indexOf(u8, raw, "\r\n") != null;
    const content = if (had_crlf) blk: {
        var tmp = try std.ArrayList(u8).initCapacity(alloc, raw.len);
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (i + 1 < raw.len and raw[i] == '\r' and raw[i + 1] == '\n') continue;
            try tmp.append(raw[i]);
        }
        break :blk try tmp.toOwnedSlice();
    } else try alloc.dupe(u8, raw);
    defer alloc.free(content);

    // Find all match positions.
    var matches = std.ArrayList(usize).init(alloc);
    defer matches.deinit();
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, content, search_start, old_text)) |pos| {
        try matches.append(pos);
        search_start = pos + old_text.len;
    }

    if (matches.items.len == 0) {
        var msg = std.ArrayList(u8).init(alloc);
        errdefer msg.deinit();
        try msg.writer().print(
            "Error: old_text not found in {s}. Match exactly including whitespace.",
            .{path},
        );
        try appendFuzzyHints(msg.writer(), content, old_text);
        return msg.toOwnedSlice();
    }

    if (matches.items.len > 1 and !replace_all) {
        var out = std.ArrayList(u8).init(alloc);
        errdefer out.deinit();
        try out.writer().print(
            "Error: old_text matched {d} times in {s}. Use replace_all=true or add more context:\n",
            .{ matches.items.len, path },
        );
        for (matches.items) |pos| {
            const line_no = countLines(content[0..pos]) + 1;
            try out.writer().print("  Line {d}\n", .{line_no});
        }
        return out.toOwnedSlice();
    }

    // Build new content.
    var rebuilt = std.ArrayList(u8).init(alloc);
    errdefer rebuilt.deinit();
    var cursor: usize = 0;
    var replacements: usize = 0;
    for (matches.items) |pos| {
        try rebuilt.appendSlice(content[cursor..pos]);
        try rebuilt.appendSlice(new_text);
        cursor = pos + old_text.len;
        replacements += 1;
        if (!replace_all) break;
    }
    try rebuilt.appendSlice(content[cursor..]);
    const final_lf = try rebuilt.toOwnedSlice();
    defer alloc.free(final_lf);

    const to_write = if (had_crlf) blk: {
        var tmp = try std.ArrayList(u8).initCapacity(alloc, final_lf.len);
        for (final_lf) |b| {
            if (b == '\n') try tmp.append('\r');
            try tmp.append(b);
        }
        break :blk try tmp.toOwnedSlice();
    } else try alloc.dupe(u8, final_lf);
    defer alloc.free(to_write);

    const out_file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error opening {s} for write: {s}", .{ path, @errorName(err) });
    };
    defer out_file.close();
    out_file.writeAll(to_write) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error writing {s}: {s}", .{ path, @errorName(err) });
    };

    return try std.fmt.allocPrint(alloc, "Edited {s} ({d} replacement{s})", .{
        path,
        replacements,
        if (replacements == 1) "" else "s",
    });
}

fn countLines(slice: []const u8) usize {
    var n: usize = 0;
    for (slice) |b| {
        if (b == '\n') n += 1;
    }
    return n;
}

/// When old_text doesn't match exactly, find lines that contain its first
/// non-empty line as a substring. Stops at 5 hits to keep output small.
fn appendFuzzyHints(w: anytype, content: []const u8, old_text: []const u8) !void {
    var needle: []const u8 = "";
    var ot_it = std.mem.splitScalar(u8, old_text, '\n');
    while (ot_it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t");
        if (t.len > 0) {
            needle = t;
            break;
        }
    }
    if (needle.len < 3) return;

    var hits: usize = 0;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        line_no += 1;
        if (std.mem.indexOf(u8, line, needle) == null) continue;
        if (hits == 0) try w.writeAll("\n\nSimilar lines found — the file may differ in whitespace or surrounding context:\n");
        hits += 1;
        if (hits > 5) {
            try w.writeAll("  ...\n");
            return;
        }
        const truncated = if (line.len > 120) line[0..120] else line;
        try w.print("  Line {d}: {s}\n", .{ line_no, truncated });
    }
}
