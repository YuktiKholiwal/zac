const std = @import("std");
const messages = @import("../messages.zig");
const mod = @import("mod.zig");

pub const def = messages.Tool{
    .name = "ls",
    .description = "Show the entries of a directory, one per line, with a type tag (f=file, d=dir, l=symlink) and the byte size of files. Non-recursive.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {"type": "string", "description": "Directory path (default: cwd)"}
    \\  }
    \\}
    ,
};

pub fn execute(alloc: std.mem.Allocator, args: std.json.Value) anyerror![]u8 {
    const path = mod.getString(args, "path") orelse ".";

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error opening {s}: {s}", .{ path, @errorName(err) });
    };
    defer dir.close();

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    const w = out.writer();

    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        count += 1;
        const kind: u8 = switch (entry.kind) {
            .directory => 'd',
            .sym_link => 'l',
            .file => 'f',
            else => '?',
        };
        if (entry.kind == .file) {
            const sub = dir.openFile(entry.name, .{}) catch {
                try w.print("{c} {s}\n", .{ kind, entry.name });
                continue;
            };
            defer sub.close();
            const stat = sub.stat() catch {
                try w.print("{c} {s}\n", .{ kind, entry.name });
                continue;
            };
            try w.print("{c} {s} ({d} bytes)\n", .{ kind, entry.name, stat.size });
        } else {
            try w.print("{c} {s}\n", .{ kind, entry.name });
        }
    }

    if (count == 0) try w.print("(empty)\n", .{});

    return out.toOwnedSlice();
}
