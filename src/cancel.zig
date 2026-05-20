const std = @import("std");
const builtin = @import("builtin");

var flag = std.atomic.Value(bool).init(false);

pub fn install() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSigint },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

fn onSigint(_: c_int) callconv(.C) void {
    flag.store(true, .seq_cst);
}

pub fn requested() bool {
    return flag.load(.seq_cst);
}

pub fn reset() void {
    flag.store(false, .seq_cst);
}

/// Returns true and resets the flag if cancellation was requested.
pub fn take() bool {
    return flag.swap(false, .seq_cst);
}
