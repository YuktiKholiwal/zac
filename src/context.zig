const std = @import("std");

/// Files we look for in the current working directory, in priority order.
/// First match wins; we don't concatenate multiple files because they often
/// duplicate each other (AGENTS.md is usually a symlink to CLAUDE.md).
const CANDIDATES = [_][]const u8{
    "AGENTS.md",
    "CLAUDE.md",
    ".zac/AGENTS.md",
    ".cursor/rules",
};

const MAX_BYTES: usize = 256 * 1024;

/// Returns a wrapped context string ready to append to the system prompt,
/// or null if no context file was found. Caller owns the returned slice.
pub fn load(alloc: std.mem.Allocator) !?[]u8 {
    for (CANDIDATES) |path| {
        const file = std.fs.cwd().openFile(path, .{}) catch continue;
        defer file.close();

        const body = file.readToEndAlloc(alloc, MAX_BYTES) catch continue;
        defer alloc.free(body);

        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) continue;

        return try std.fmt.allocPrint(
            alloc,
            "\n\n---\n\n# Project context (from {s})\n\n{s}\n",
            .{ path, trimmed },
        );
    }
    return null;
}
