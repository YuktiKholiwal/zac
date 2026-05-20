const std = @import("std");
const messages = @import("../messages.zig");
const mod = @import("mod.zig");
const gitignore = @import("../gitignore.zig");

const MAX_RESULTS: usize = 200;
const MAX_FILE_BYTES: usize = 4 * 1024 * 1024;

pub const def = messages.Tool{
    .name = "grep",
    .description = "Search file contents for a substring (case-sensitive). Returns file:line:match for up to 200 hits. Skips common build/vendor dirs.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pattern": {"type": "string", "description": "Substring to search for"},
    \\    "path": {"type": "string", "description": "Root directory (default: cwd)"},
    \\    "include": {"type": "string", "description": "Only files with this extension, e.g. '.zig'"}
    \\  },
    \\  "required": ["pattern"]
    \\}
    ,
};

pub fn execute(alloc: std.mem.Allocator, args: std.json.Value) anyerror![]u8 {
    const pattern = mod.getString(args, "pattern") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'pattern' is required", .{});
    const root_path = mod.getString(args, "path") orelse ".";
    const include = mod.getString(args, "include");

    var dir = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error opening {s}: {s}", .{ root_path, @errorName(err) });
    };
    defer dir.close();

    var gi = try gitignore.load(alloc);
    defer gi.deinit();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    const w = out.writer();

    var hits: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (gi.isIgnored(entry.path)) continue;
        if (include) |ext| if (!std.mem.endsWith(u8, entry.path, ext)) continue;

        const file = entry.dir.openFile(entry.basename, .{}) catch continue;
        defer file.close();
        const contents = file.readToEndAlloc(alloc, MAX_FILE_BYTES) catch continue;
        defer alloc.free(contents);

        var line_no: usize = 0;
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| {
            line_no += 1;
            if (std.mem.indexOf(u8, line, pattern) != null) {
                hits += 1;
                if (hits > MAX_RESULTS) break;
                const trimmed = if (line.len > 200) line[0..200] else line;
                try w.print("{s}/{s}:{d}: {s}\n", .{ root_path, entry.path, line_no, trimmed });
            }
        }
        if (hits > MAX_RESULTS) break;
    }

    if (hits == 0) {
        try w.print("No matches for '{s}' under {s}\n", .{ pattern, root_path });
    } else if (hits > MAX_RESULTS) {
        try w.print("\n(truncated at {d} matches; narrow with 'include' or a more specific path)\n", .{MAX_RESULTS});
    }

    return out.toOwnedSlice();
}

