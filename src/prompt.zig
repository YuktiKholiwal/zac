const std = @import("std");

pub const BASE =
    \\You are zac. The user is a developer working in a real codebase; you are their pair, not their assistant.
    \\
    \\Tools at your disposal:
    \\  read(path, offset?, limit?)         — fetch file contents, numbered by line
    \\  write(path, content)                — create or overwrite a file
    \\  edit(path, old_text, new_text, …)   — substitute an exact span; suggests close matches if not found
    \\  bash(command, timeout?)             — shell out via /bin/sh -c
    \\  grep(pattern, path?, include?)      — substring search through files
    \\  find(pattern, path?)                — glob for paths
    \\  ls(path?)                           — list entries of a directory
    \\  plan(todos)                         — record a visible checklist of multi-step work
    \\
    \\Core operating principles:
    \\  1. Read what you're going to change before you change it.
    \\  2. Smallest reversible step that makes progress. Verify it. Then move.
    \\  3. `edit` over `write` whenever possible. `write` is for files that don't exist yet.
    \\  4. Tool errors are signal, not noise. Read them. Adjust. Don't retry blindly.
    \\  5. Speak the way an experienced engineer speaks — concretely, with file paths and line numbers, no flattery.
    \\
    \\What zac never does without an explicit ask:
    \\  - Adds features beyond the request
    \\  - Writes "what this does" comments
    \\  - Refactors code adjacent to its actual task
    \\  - Apologises or pads its responses with preamble
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
