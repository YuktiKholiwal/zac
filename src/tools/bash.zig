const std = @import("std");
const messages = @import("../messages.zig");
const mod = @import("mod.zig");
const sandbox = @import("../sandbox.zig");

/// Fallback wall-clock cap when the model doesn't pass `timeout`. Generous
/// enough for most builds/test runs; the model can request more for known-long
/// commands. Prevents a runaway process (e.g. `while true`) from hanging the
/// agent indefinitely, since Ctrl-C does not interrupt a blocked bash read.
const DEFAULT_TIMEOUT_S: u64 = 300;

pub const def = messages.Tool{
    .name = "bash",
    .description = "Run a shell command through `/bin/sh -c`. The current working directory is the user's project. On macOS the command is wrapped in `sandbox-exec` that blocks writes to system paths (override globally with --no-sandbox). The command is killed if it runs longer than `timeout` seconds (default 300). The returned text concatenates stdout, then stderr, then the exit code if non-zero.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": {"type": "string", "description": "Shell command to execute"},
    \\    "timeout": {"type": "integer", "description": "Wall-clock limit in seconds before the process is killed (default 300)"}
    \\  },
    \\  "required": ["command"]
    \\}
    ,
};

/// Runs in a separate thread. Sleeps up to `secs`, checking `finished` so it
/// exits promptly once the command completes. If the deadline passes first, it
/// SIGKILLs the child by pid — directly, rather than via child.kill(), so it
/// can't race the main thread's child.wait(). Killing the immediate child
/// (the `sh` / `sandbox-exec` process) closes its pipes and unblocks
/// collectOutput; any grandchildren may survive, which is acceptable for a
/// guardrail.
fn watchdog(
    pid: std.posix.pid_t,
    finished: *std.atomic.Value(bool),
    timed_out: *std.atomic.Value(bool),
    secs: u64,
) void {
    var elapsed_ms: u64 = 0;
    const total_ms = secs * 1000;
    while (elapsed_ms < total_ms) {
        if (finished.load(.seq_cst)) return;
        std.time.sleep(100 * std.time.ns_per_ms);
        elapsed_ms += 100;
    }
    if (finished.load(.seq_cst)) return;
    timed_out.store(true, .seq_cst);
    std.posix.kill(pid, std.posix.SIG.KILL) catch {};
}

pub fn execute(alloc: std.mem.Allocator, args: std.json.Value) anyerror![]u8 {
    const command = mod.getString(args, "command") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'command' is required", .{});

    const timeout_s: u64 = blk: {
        if (mod.getInt(args, "timeout")) |t| {
            if (t > 0) break :blk @intCast(t);
        }
        break :blk DEFAULT_TIMEOUT_S;
    };

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

    // Arm the timeout watchdog. The deferred block guarantees the thread is
    // released and disarmed on every exit path (including errors), so it can
    // never outlive this call and kill an unrelated, pid-reused process.
    var finished = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    const wd: ?std.Thread = std.Thread.spawn(
        .{},
        watchdog,
        .{ child.id, &finished, &timed_out, timeout_s },
    ) catch null;
    defer if (wd) |t| {
        finished.store(true, .seq_cst);
        t.join();
    };

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

    if (timed_out.load(.seq_cst)) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append('\n');
        try out.writer().print("[killed: exceeded {d}s timeout]", .{timeout_s});
        return out.toOwnedSlice();
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

test "bash: fast command returns its output and is not killed" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"command\":\"printf hello\"}",
        .{},
    );
    defer parsed.deinit();
    const out = try execute(alloc, parsed.value);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "killed") == null);
}

test "bash: command exceeding timeout is killed promptly" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"command\":\"sleep 10\",\"timeout\":1}",
        .{},
    );
    defer parsed.deinit();
    var timer = try std.time.Timer.start();
    const out = try execute(alloc, parsed.value);
    defer alloc.free(out);
    const elapsed_s = timer.read() / std.time.ns_per_s;
    try std.testing.expect(std.mem.indexOf(u8, out, "killed") != null);
    // Killed near the 1s deadline, not after the full 10s sleep.
    try std.testing.expect(elapsed_s < 5);
}

test "bash: nonzero exit code is reported" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"command\":\"exit 3\"}",
        .{},
    );
    defer parsed.deinit();
    const out = try execute(alloc, parsed.value);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Exit code: 3") != null);
}
