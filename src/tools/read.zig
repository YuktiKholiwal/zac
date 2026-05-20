const std = @import("std");
const messages = @import("../messages.zig");
const mod = @import("mod.zig");

pub const def = messages.Tool{
    .name = "read",
    .description = "Read a file from disk and return its contents with 1-indexed line numbers. Use offset and limit for large files.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {"type": "string", "description": "Path to the file"},
    \\    "offset": {"type": "integer", "description": "1-indexed start line"},
    \\    "limit": {"type": "integer", "description": "Max lines to read"}
    \\  },
    \\  "required": ["path"]
    \\}
    ,
};

pub fn execute(alloc: std.mem.Allocator, args: std.json.Value) anyerror![]u8 {
    const path = mod.getString(args, "path") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'path' is required", .{});
    const offset: usize = if (mod.getInt(args, "offset")) |o| @intCast(@max(1, o)) else 1;
    const limit: usize = if (mod.getInt(args, "limit")) |l| @intCast(@max(0, l)) else 2000;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error opening {s}: {s}", .{ path, @errorName(err) });
    };
    defer file.close();

    const contents = try file.readToEndAlloc(alloc, 16 * 1024 * 1024);
    defer alloc.free(contents);

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
