const std = @import("std");
const messages = @import("../messages.zig");
const mod = @import("mod.zig");
const path_guard = @import("../path_guard.zig");

pub const def = messages.Tool{
    .name = "write",
    .description = "Write content to a file, overwriting if it exists. Creates parent directories as needed.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {"type": "string"},
    \\    "content": {"type": "string"}
    \\  },
    \\  "required": ["path", "content"]
    \\}
    ,
};

pub fn execute(alloc: std.mem.Allocator, args: std.json.Value) anyerror![]u8 {
    const path = mod.getString(args, "path") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'path' is required", .{});
    const content = mod.getString(args, "content") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'content' is required", .{});

    if (!mod.isAllowOutside()) {
        const inside = path_guard.isInsideCwd(alloc, path) catch true;
        if (!inside) {
            return try std.fmt.allocPrint(
                alloc,
                "Error: refusing to write outside the cwd: {s}\nRe-run with --allow-outside if intentional.",
                .{path},
            );
        }
    }

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            return try std.fmt.allocPrint(alloc, "Error creating directories for {s}: {s}", .{ path, @errorName(err) });
        };
    }

    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error opening {s} for write: {s}", .{ path, @errorName(err) });
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error writing {s}: {s}", .{ path, @errorName(err) });
    };

    return try std.fmt.allocPrint(alloc, "Wrote {d} bytes to {s}", .{ content.len, path });
}
