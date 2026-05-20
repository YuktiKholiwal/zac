const std = @import("std");

pub const BASE =
    \\You are zac, a minimal coding agent operating in the user's current working directory.
    \\
    \\You have these tools:
    \\- read(path, offset?, limit?): read a file with 1-indexed line numbers
    \\- write(path, content): create/overwrite a file
    \\- edit(path, old_text, new_text, replace_all?): replace exact text in a file
    \\- bash(command, timeout?): run a shell command via /bin/sh -c
    \\- grep(pattern, path?, include?): substring search across files
    \\- find_files(pattern, path?): glob file discovery
    \\- list_dir(path?): list directory entries
    \\- write_todo_list(todos): plan/track multi-step work
    \\
    \\General behavior:
    \\- Read files before editing them.
    \\- Make changes incrementally; verify with read or bash after non-trivial edits.
    \\- Prefer edit over write for in-place changes.
    \\- Keep responses concise. Show code/output, not narration.
    \\- Don't add comments, docstrings, or refactors the user didn't ask for.
    \\- If a tool errors, read the error and adjust — don't retry the same call.
;

pub const Mode = enum {
    default,
    code,
    plan,
    ask,
    review,
    debug,
    simplify,
    brainstorm,
    write_prompt,
    frontend_design,
    review_security,

    pub fn parse(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "default")) return .default;
        if (std.mem.eql(u8, s, "code")) return .code;
        if (std.mem.eql(u8, s, "plan")) return .plan;
        if (std.mem.eql(u8, s, "ask")) return .ask;
        if (std.mem.eql(u8, s, "review")) return .review;
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "simplify")) return .simplify;
        if (std.mem.eql(u8, s, "brainstorm")) return .brainstorm;
        if (std.mem.eql(u8, s, "write-prompt") or std.mem.eql(u8, s, "write_prompt")) return .write_prompt;
        if (std.mem.eql(u8, s, "frontend-design") or std.mem.eql(u8, s, "frontend_design")) return .frontend_design;
        if (std.mem.eql(u8, s, "review-security") or std.mem.eql(u8, s, "review_security")) return .review_security;
        return null;
    }

    pub fn body(self: Mode) []const u8 {
        return switch (self) {
            .default => @embedFile("prompts/default.md"),
            .code => @embedFile("prompts/code.md"),
            .plan => @embedFile("prompts/plan.md"),
            .ask => @embedFile("prompts/ask.md"),
            .review => @embedFile("prompts/review.md"),
            .debug => @embedFile("prompts/debug.md"),
            .simplify => @embedFile("prompts/simplify.md"),
            .brainstorm => @embedFile("prompts/brainstorm.md"),
            .write_prompt => @embedFile("prompts/write-prompt.md"),
            .frontend_design => @embedFile("prompts/frontend-design.md"),
            .review_security => @embedFile("prompts/review-security.md"),
        };
    }

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .default => "default",
            .code => "code",
            .plan => "plan",
            .ask => "ask",
            .review => "review",
            .debug => "debug",
            .simplify => "simplify",
            .brainstorm => "brainstorm",
            .write_prompt => "write-prompt",
            .frontend_design => "frontend-design",
            .review_security => "review-security",
        };
    }
};

pub const ALL_MODES = "default, code, plan, ask, review, debug, simplify, brainstorm, write-prompt, frontend-design, review-security";

/// Builds a system prompt = base + mode body + optional project context.
/// Caller owns the returned slice.
pub fn build(alloc: std.mem.Allocator, mode: Mode, project_context: ?[]const u8) ![]u8 {
    return try std.fmt.allocPrint(alloc, "{s}\n\n---\n\n{s}{s}", .{
        BASE,
        mode.body(),
        project_context orelse "",
    });
}
