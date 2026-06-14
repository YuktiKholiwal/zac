const std = @import("std");

/// All functions take an optional `cwd`: null means the process's current
/// directory (the normal case from main), and a path lets tests drive a
/// throwaway repo without chdir'ing the whole process.

/// Is `cwd` inside a git working tree?
pub fn isGitRepo(alloc: std.mem.Allocator, cwd: ?[]const u8) bool {
    var child = std.process.Child.init(
        &.{ "git", "rev-parse", "--is-inside-work-tree" },
        alloc,
    );
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
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
pub fn hasChanges(alloc: std.mem.Allocator, cwd: ?[]const u8) bool {
    var child = std.process.Child.init(
        &.{ "git", "status", "--porcelain" },
        alloc,
    );
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    // collectOutput requires both pipes. Capture stderr too even if we don't
    // look at it — leaving it as .Ignore makes the polling loop wait forever.
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
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
pub fn commitAll(alloc: std.mem.Allocator, cwd: ?[]const u8, message: []const u8) !?[]u8 {
    if (!isGitRepo(alloc, cwd)) return null;
    if (!hasChanges(alloc, cwd)) return null;

    {
        var add = std.process.Child.init(&.{ "git", "add", "-A" }, alloc);
        add.cwd = cwd;
        add.stdin_behavior = .Ignore;
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
        commit.cwd = cwd;
        commit.stdin_behavior = .Ignore;
        commit.stdout_behavior = .Ignore;
        commit.stderr_behavior = .Ignore;
        try commit.spawn();
        const term = try commit.wait();
        switch (term) {
            .Exited => |c| if (c != 0) return null,
            else => return null,
        }
    }

    return try shortSha(alloc, cwd);
}

fn shortSha(alloc: std.mem.Allocator, cwd: ?[]const u8) ![]u8 {
    var child = std.process.Child.init(
        &.{ "git", "rev-parse", "--short", "HEAD" },
        alloc,
    );
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
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
pub fn undoLast(alloc: std.mem.Allocator, cwd: ?[]const u8) !bool {
    if (!isGitRepo(alloc, cwd)) return false;
    var child = std.process.Child.init(
        &.{ "git", "reset", "--soft", "HEAD~1" },
        alloc,
    );
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    return switch (term) {
        .Exited => |c| c == 0,
        else => false,
    };
}

// ──────────────────────────────────────────────────────────────────────────
// Tests

/// Run a git command in `dir` for test setup, ignoring output. Asserts success.
fn git(alloc: std.mem.Allocator, dir: []const u8, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, alloc);
    child.cwd = dir;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = try child.wait();
}

test "autogit: commit then undo round-trips in a throwaway repo" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buf);

    try git(alloc, dir, &.{ "git", "init", "-q" });
    try git(alloc, dir, &.{ "git", "config", "user.email", "t@t.test" });
    try git(alloc, dir, &.{ "git", "config", "user.name", "t" });
    try git(alloc, dir, &.{ "git", "config", "commit.gpgsign", "false" });

    try std.testing.expect(isGitRepo(alloc, dir));

    // Nothing to commit yet.
    try std.testing.expect((try commitAll(alloc, dir, "empty")) == null);

    // First change → commits, returns a short sha.
    {
        const f = try tmp.dir.createFile("a.txt", .{});
        defer f.close();
        try f.writeAll("one");
    }
    const sha1 = (try commitAll(alloc, dir, "add a.txt")) orelse return error.ExpectedCommit;
    defer alloc.free(sha1);
    try std.testing.expect(sha1.len >= 4 and sha1.len <= 12);
    try std.testing.expect(!hasChanges(alloc, dir)); // clean after commit

    // Second change → second commit.
    {
        const f = try tmp.dir.createFile("a.txt", .{});
        defer f.close();
        try f.writeAll("two");
    }
    const sha2 = (try commitAll(alloc, dir, "edit a.txt")) orelse return error.ExpectedCommit;
    defer alloc.free(sha2);
    try std.testing.expect(!std.mem.eql(u8, sha1, sha2));

    // Undo the second commit; soft reset preserves the working-tree change,
    // so the repo is dirty again.
    try std.testing.expect(try undoLast(alloc, dir));
    try std.testing.expect(hasChanges(alloc, dir));
}
