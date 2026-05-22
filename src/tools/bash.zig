const std = @import("std");
const messages = @import("../messages.zig");
const mod = @import("mod.zig");
const sandbox = @import("../sandbox.zig");

pub const def = messages.Tool{
    .name = "bash",
    .description = "Run a shell command through `/bin/sh -c`. The current working directory is the user's project. On macOS the command is wrapped in `sandbox-exec` that blocks writes to system paths (override globally with --no-sandbox). The returned text concatenates stdout, then stderr, then the exit code if non-zero.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": {"type": "string", "description": "Shell command to execute"},
    \\    "timeout": {"type": "integer", "description": "Wall-clock limit in seconds (after which the process is killed)"}
    \\  },
    \\  "required": ["command"]
    \\}
    ,
};

pub fn execute(alloc: std.mem.Allocator, args: std.json.Value) anyerror![]u8 {
    const command = mod.getString(args, "command") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'command' is required", .{});

    const sb_argv = try sandbox.wrapArgv(alloc, command);
    defer if (sb_argv) |a| sandbox.freeArgv(alloc, a);

    const argv: []const []const u8 = if (sb_argv) |a|
        a
    else
        &.{ "/bin/sh", "-c", command };

    var child = std.process.Child.init(argv, alloc);
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
