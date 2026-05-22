const std = @import("std");

/// Is the current working directory inside a git working tree?
pub fn isGitRepo(alloc: std.mem.Allocator) bool {
    var child = std.process.Child.init(
        &.{ "git", "rev-parse", "--is-inside-work-tree" },
        alloc,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// True if there's anything staged or unstaged.
pub fn hasChanges(alloc: std.mem.Allocator) bool {
    var child = std.process.Child.init(
        &.{ "git", "status", "--porcelain" },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;

    var stdout_buf: std.ArrayListUnmanaged(u8) = .{};
    defer stdout_buf.deinit(alloc);
    var stderr_buf: std.ArrayListUnmanaged(u8) = .{};
    defer stderr_buf.deinit(alloc);
    child.collectOutput(alloc, &stdout_buf, &stderr_buf, 1 * 1024 * 1024) catch return false;
    _ = child.wait() catch return false;
    return stdout_buf.items.len > 0;
}

/// Stage all changes and commit with the provided message. Returns the
/// short commit SHA on success, or null if there was nothing to commit or
/// the commit failed.
pub fn commitAll(alloc: std.mem.Allocator, message: []const u8) !?[]u8 {
    if (!isGitRepo(alloc)) return null;
    if (!hasChanges(alloc)) return null;

    {
        var add = std.process.Child.init(&.{ "git", "add", "-A" }, alloc);
        add.stdout_behavior = .Ignore;
        add.stderr_behavior = .Ignore;
        try add.spawn();
        _ = try add.wait();
    }

    {
        var commit = std.process.Child.init(
            &.{ "git", "commit", "--no-verify", "-m", message },
            alloc,
        );
        commit.stdout_behavior = .Ignore;
        commit.stderr_behavior = .Ignore;
        try commit.spawn();
        const term = try commit.wait();
        switch (term) {
            .Exited => |c| if (c != 0) return null,
            else => return null,
        }
    }

    return try shortSha(alloc);
}

fn shortSha(alloc: std.mem.Allocator) ![]u8 {
    var child = std.process.Child.init(
        &.{ "git", "rev-parse", "--short", "HEAD" },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var stdout_buf: std.ArrayListUnmanaged(u8) = .{};
    defer stdout_buf.deinit(alloc);
    var stderr_buf: std.ArrayListUnmanaged(u8) = .{};
    defer stderr_buf.deinit(alloc);
    try child.collectOutput(alloc, &stdout_buf, &stderr_buf, 64);
    _ = try child.wait();

    return try alloc.dupe(u8, std.mem.trim(u8, stdout_buf.items, " \n\r\t"));
}

/// `git reset --soft HEAD~1` to undo the last auto-commit, preserving the
/// working tree changes.
pub fn undoLast(alloc: std.mem.Allocator) !bool {
    if (!isGitRepo(alloc)) return false;
    var child = std.process.Child.init(
        &.{ "git", "reset", "--soft", "HEAD~1" },
        alloc,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    return switch (term) {
        .Exited => |c| c == 0,
        else => false,
    };
}
