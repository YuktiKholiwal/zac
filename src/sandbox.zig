const std = @import("std");
const builtin = @import("builtin");

/// A small sandbox profile for macOS sandbox-exec: deny writes to system paths
/// while leaving the rest permissive enough that typical dev tooling (cargo,
/// npm, pip, git) still works. Not a complete jail — it's a guardrail against
/// the model running `rm -rf /usr/local/...` style commands.
const MACOS_PROFILE =
    \\(version 1)
    \\(allow default)
    \\(deny file-write* (subpath "/etc"))
    \\(deny file-write* (subpath "/usr"))
    \\(deny file-write* (subpath "/System"))
    \\(deny file-write* (subpath "/Library"))
    \\(deny file-write* (subpath "/private/etc"))
    \\(deny file-write* (subpath "/bin"))
    \\(deny file-write* (subpath "/sbin"))
    \\(deny file-write* (subpath "/Applications"))
;

var sandbox_enabled: bool = false;

pub fn setEnabled(v: bool) void {
    sandbox_enabled = v;
}

pub fn isAvailable() bool {
    return builtin.target.os.tag == .macos;
}

/// Returns the argv prefix to wrap a `/bin/sh -c "..."` invocation in.
/// On non-macOS or when disabled, returns null and bash.zig falls back to the
/// direct spawn.
pub fn wrapArgv(alloc: std.mem.Allocator, command: []const u8) !?[][]const u8 {
    if (!sandbox_enabled or !isAvailable()) return null;

    var argv = try alloc.alloc([]const u8, 6);
    argv[0] = try alloc.dupe(u8, "sandbox-exec");
    argv[1] = try alloc.dupe(u8, "-p");
    argv[2] = try alloc.dupe(u8, MACOS_PROFILE);
    argv[3] = try alloc.dupe(u8, "/bin/sh");
    argv[4] = try alloc.dupe(u8, "-c");
    argv[5] = try alloc.dupe(u8, command);
    return argv;
}

pub fn freeArgv(alloc: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |a| alloc.free(a);
    alloc.free(argv);
}
