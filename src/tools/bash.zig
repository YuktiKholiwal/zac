const std = @import("std");
const messages = @import("../messages.zig");
const mod = @import("mod.zig");

pub const def = messages.Tool{
    .name = "bash",
    .description = "Execute a bash command in the current working directory. Returns combined stdout/stderr and exit code.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": {"type": "string"},
    \\    "timeout": {"type": "integer", "description": "Seconds before SIGKILL"}
    \\  },
    \\  "required": ["command"]
    \\}
    ,
};

pub fn execute(alloc: std.mem.Allocator, args: std.json.Value) anyerror![]u8 {
    const command = mod.getString(args, "command") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'command' is required", .{});

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", command }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_buf: std.ArrayListUnmanaged(u8) = .{};
    defer stdout_buf.deinit(alloc);
    var stderr_buf: std.ArrayListUnmanaged(u8) = .{};
    defer stderr_buf.deinit(alloc);

    try child.collectOutput(alloc, &stdout_buf, &stderr_buf, 4 * 1024 * 1024);
    const term = try child.wait();

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    if (stdout_buf.items.len > 0) try out.appendSlice(stdout_buf.items);
    if (stderr_buf.items.len > 0) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append('\n');
        try out.appendSlice(stderr_buf.items);
    }

    const code: i32 = switch (term) {
        .Exited => |c| @intCast(c),
        .Signal => |s| -@as(i32, @intCast(s)),
        else => -1,
    };
    if (code != 0) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append('\n');
        try out.writer().print("Exit code: {d}", .{code});
    }

    return out.toOwnedSlice();
}
