const std = @import("std");

/// Returns true if `path` resolves to a location within the current working
/// directory (or a subpath of it). Used to gate write/edit on potentially
/// dangerous paths like /etc/foo, ../../something.
pub fn isInsideCwd(alloc: std.mem.Allocator, path: []const u8) !bool {
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);

    const abs = if (std.fs.path.isAbsolute(path))
        try alloc.dupe(u8, path)
    else
        try std.fs.path.join(alloc, &.{ cwd, path });
    defer alloc.free(abs);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = std.fs.cwd().realpath(abs, &buf) catch |err| switch (err) {
        // For paths that don't yet exist (e.g. a `write` creating a new file),
        // resolve the parent directory instead.
        error.FileNotFound => {
            const parent = std.fs.path.dirname(abs) orelse return false;
            const parent_resolved = std.fs.cwd().realpath(parent, &buf) catch return false;
            return std.mem.startsWith(u8, parent_resolved, cwd) and
                (parent_resolved.len == cwd.len or parent_resolved[cwd.len] == '/');
        },
        else => return err,
    };

    return std.mem.startsWith(u8, resolved, cwd) and
        (resolved.len == cwd.len or resolved[cwd.len] == '/');
}
