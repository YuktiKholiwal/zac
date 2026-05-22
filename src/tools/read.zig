const std = @import("std");
const messages = @import("../messages.zig");
const mod = @import("mod.zig");

pub const def = messages.Tool{
    .name = "read",
    .description = "Return the contents of a text file, prefixed with 1-indexed line numbers. For large files, page through with `offset` (first line to show) and `limit` (number of lines). If this file has already been read in the current session, zac returns only the changes since the last read (when the content has changed).",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {"type": "string", "description": "File to read (relative or absolute)"},
    \\    "offset": {"type": "integer", "description": "1-indexed first line"},
    \\    "limit": {"type": "integer", "description": "How many lines to return"}
    \\  },
    \\  "required": ["path"]
    \\}
    ,
};

pub fn execute(alloc: std.mem.Allocator, args: std.json.Value) anyerror![]u8 {
    const path = mod.getString(args, "path") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'path' is required", .{});
    const offset_given = mod.getInt(args, "offset") != null;
    const offset: usize = if (mod.getInt(args, "offset")) |o| @intCast(@max(1, o)) else 1;
    const limit: usize = if (mod.getInt(args, "limit")) |l| @intCast(@max(0, l)) else 2000;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error opening {s}: {s}", .{ path, @errorName(err) });
    };
    defer file.close();

    const contents = try file.readToEndAlloc(alloc, 16 * 1024 * 1024);
    defer alloc.free(contents);

    // Diff-aware re-read: only triggers when the model isn't paging (no
    // offset/limit override) — otherwise we'd hide pages they're asking for.
    const prior = mod.previousContentFor(path);
    if (!offset_given and prior != null and !std.mem.eql(u8, prior.?, contents)) {
        const diff = try renderDiff(alloc, prior.?, contents);
        defer alloc.free(diff);
        mod.observeRead(path);
        mod.recordContentFor(path, contents);
        return try std.fmt.allocPrint(
            alloc,
            "[diff since last read of {s}]\n{s}",
            .{ path, diff },
        );
    }

    mod.observeRead(path);
    mod.recordContentFor(path, contents);

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    const w = out.writer();

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, contents, '\n');
    var emitted: usize = 0;
    while (it.next()) |line| {
        line_no += 1;
        if (line_no < offset) continue;
        if (emitted >= limit) {
            try w.print("... (truncated; pass offset={d} to continue)\n", .{line_no});
            break;
        }
        try w.print("{d:>6}\t{s}\n", .{ line_no, line });
        emitted += 1;
    }

    if (emitted == 0) {
        try w.print("(no lines in range; file has {d} lines)\n", .{line_no});
    }

    return out.toOwnedSlice();
}

/// A tiny line-based diff: emit `=` for unchanged, `-` for old-only, `+` for
/// new-only. Not LCS-optimal, but cheap and readable. Walks the two files in
/// lockstep on matching lines; whenever lines differ, advances the side whose
/// next matching line is closer.
fn renderDiff(alloc: std.mem.Allocator, old: []const u8, new: []const u8) ![]u8 {
    var old_lines = std.ArrayList([]const u8).init(alloc);
    defer old_lines.deinit();
    var new_lines = std.ArrayList([]const u8).init(alloc);
    defer new_lines.deinit();

    var it_old = std.mem.splitScalar(u8, old, '\n');
    while (it_old.next()) |ln| try old_lines.append(ln);
    var it_new = std.mem.splitScalar(u8, new, '\n');
    while (it_new.next()) |ln| try new_lines.append(ln);

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    const w = out.writer();

    var oi: usize = 0;
    var ni: usize = 0;
    while (oi < old_lines.items.len or ni < new_lines.items.len) {
        if (oi < old_lines.items.len and ni < new_lines.items.len and
            std.mem.eql(u8, old_lines.items[oi], new_lines.items[ni]))
        {
            // Equal line — emit a context line every few, otherwise skip.
            oi += 1;
            ni += 1;
            continue;
        }

        // Find next sync point — first line where future old[j] == future new[k].
        const sync = findSync(old_lines.items, oi, new_lines.items, ni) orelse {
            // No future match: dump remainders.
            while (oi < old_lines.items.len) : (oi += 1) {
                try w.print("- {s}\n", .{old_lines.items[oi]});
            }
            while (ni < new_lines.items.len) : (ni += 1) {
                try w.print("+ {s}\n", .{new_lines.items[ni]});
            }
            break;
        };
        while (oi < sync.old_idx) : (oi += 1) {
            try w.print("- {s}\n", .{old_lines.items[oi]});
        }
        while (ni < sync.new_idx) : (ni += 1) {
            try w.print("+ {s}\n", .{new_lines.items[ni]});
        }
    }

    return out.toOwnedSlice();
}

const SyncPoint = struct { old_idx: usize, new_idx: usize };

/// Looks ahead in both arrays for the first matching line within a bounded
/// window. Returns the first (old_idx, new_idx) where the lines match.
fn findSync(old: []const []const u8, oi: usize, new: []const []const u8, ni: usize) ?SyncPoint {
    const window: usize = 50;
    var oj = oi;
    while (oj < old.len and oj - oi < window) : (oj += 1) {
        var nj = ni;
        while (nj < new.len and nj - ni < window) : (nj += 1) {
            if (std.mem.eql(u8, old[oj], new[nj])) {
                return .{ .old_idx = oj, .new_idx = nj };
            }
        }
    }
    return null;
}
