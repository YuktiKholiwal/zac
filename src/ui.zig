const std = @import("std");

/// Set once at startup. When false, all ANSI helpers emit plain ASCII.
var color_enabled: bool = true;

// ──── ANSI codes ────────────────────────────────────────────────────────────
// These are `var` so init() can blank them all out at once when colors are
// disabled. Every render path uses these directly.

pub var RESET: []const u8 = "\x1b[0m";
pub var BOLD: []const u8 = "\x1b[1m";
pub var DIM: []const u8 = "\x1b[2m";
pub var ITALIC: []const u8 = "\x1b[3m";
pub var UNDERLINE: []const u8 = "\x1b[4m";

pub var RED: []const u8 = "\x1b[31m";
pub var GREEN: []const u8 = "\x1b[32m";
pub var YELLOW: []const u8 = "\x1b[33m";
pub var BLUE: []const u8 = "\x1b[34m";
pub var MAGENTA: []const u8 = "\x1b[35m";
pub var CYAN: []const u8 = "\x1b[36m";

pub fn init(no_color_flag: bool) void {
    const enabled = !no_color_flag and std.io.getStdOut().isTty();
    color_enabled = enabled;
    if (enabled) return;
    RESET = "";
    BOLD = "";
    DIM = "";
    ITALIC = "";
    UNDERLINE = "";
    RED = "";
    GREEN = "";
    YELLOW = "";
    BLUE = "";
    MAGENTA = "";
    CYAN = "";
}

pub fn isColor() bool {
    return color_enabled;
}

fn esc(code: []const u8) []const u8 {
    return if (color_enabled) code else "";
}

// ──── Tool icons ────────────────────────────────────────────────────────────

pub fn toolIcon(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "read")) return "▸";
    if (std.mem.eql(u8, name, "write")) return "▣";
    if (std.mem.eql(u8, name, "edit")) return "✎";
    if (std.mem.eql(u8, name, "bash")) return "→";
    if (std.mem.eql(u8, name, "grep")) return "⌕";
    if (std.mem.eql(u8, name, "find_files")) return "⊞";
    if (std.mem.eql(u8, name, "list_dir")) return "⊟";
    if (std.mem.eql(u8, name, "write_todo_list")) return "☑";
    return "•";
}

pub fn modeColor(mode: []const u8) []const u8 {
    if (std.mem.eql(u8, mode, "code")) return esc(GREEN);
    if (std.mem.eql(u8, mode, "plan")) return esc(BLUE);
    if (std.mem.eql(u8, mode, "ask")) return esc(CYAN);
    if (std.mem.eql(u8, mode, "review") or std.mem.eql(u8, mode, "review-security")) return esc(YELLOW);
    if (std.mem.eql(u8, mode, "debug")) return esc(MAGENTA);
    return esc(DIM);
}

// ──── Out-of-band ──────────────────────────────────────────────────────────

/// Set the terminal title bar. No-op when not a TTY.
pub fn setTitle(writer: anytype, title: []const u8) !void {
    if (!color_enabled) return;
    try writer.print("\x1b]0;{s}\x07", .{title});
}

/// Soft bell (\a). Many terminals flash or play a sound; useful for drawing
/// attention to a permission prompt.
pub fn bell(writer: anytype) !void {
    if (!color_enabled) return;
    try writer.writeAll("\x07");
}

/// OSC 8 hyperlink. text is displayed; clicking opens url in supporting
/// terminals (iTerm2, Kitty, Wezterm, recent Terminal.app).
pub fn link(writer: anytype, url: []const u8, text: []const u8) !void {
    if (!color_enabled) {
        try writer.writeAll(text);
        return;
    }
    try writer.print("\x1b]8;;{s}\x1b\\{s}\x1b]8;;\x1b\\", .{ url, text });
}

/// Best-effort file:// hyperlink for a path. Falls back to plain text.
pub fn filePath(writer: anytype, alloc: std.mem.Allocator, path: []const u8) !void {
    if (!color_enabled) {
        try writer.print("{s}{s}{s}", .{ "", path, "" });
        return;
    }
    const abs = if (std.fs.path.isAbsolute(path))
        try alloc.dupe(u8, path)
    else blk: {
        const cwd = std.process.getCwdAlloc(alloc) catch break :blk try alloc.dupe(u8, path);
        defer alloc.free(cwd);
        break :blk try std.fs.path.join(alloc, &.{ cwd, path });
    };
    defer alloc.free(abs);
    const url = try std.fmt.allocPrint(alloc, "file://{s}", .{abs});
    defer alloc.free(url);
    try writer.print("{s}", .{esc(CYAN)});
    try link(writer, url, path);
    try writer.print("{s}", .{esc(RESET)});
}

// ──── Streaming markdown renderer ──────────────────────────────────────────

pub const MdState = struct {
    at_line_start: bool = true,
    in_bold: bool = false,
    in_italic: bool = false,
    in_inline_code: bool = false,
    in_code_block: bool = false,
    pending_star: bool = false,
    backtick_run: u8 = 0,
    line_buf: [256]u8 = undefined,
    line_len: usize = 0,

    pub fn reset(self: *MdState) void {
        self.* = .{};
    }
};

/// Streams a chunk through a simple markdown renderer. Tracks state across
/// calls. Only the subset that's worth handling for terminal output:
///   **bold**, *italic*, `inline code`, headers at line start (#),
///   fenced code blocks (```lang).
pub fn renderMarkdown(writer: anytype, st: *MdState, chunk: []const u8) !void {
    if (!color_enabled) {
        try writer.writeAll(chunk);
        return;
    }

    var i: usize = 0;
    while (i < chunk.len) : (i += 1) {
        const c = chunk[i];

        // Newline always resets line state.
        if (c == '\n') {
            // Close any inline styles dangling at end of line so they don't
            // bleed into prompts or future content.
            if (st.in_bold) {
                try writer.writeAll(RESET);
                st.in_bold = false;
            }
            if (st.in_italic) {
                try writer.writeAll(RESET);
                st.in_italic = false;
            }
            if (st.in_inline_code) {
                try writer.writeAll(RESET);
                st.in_inline_code = false;
            }
            try writer.writeByte('\n');
            st.at_line_start = true;
            st.pending_star = false;
            st.backtick_run = 0;
            st.line_len = 0;
            continue;
        }

        // Code block fence: ``` at line start (or after whitespace at line start)
        if (st.at_line_start and c == '`') {
            st.backtick_run += 1;
            if (st.backtick_run == 3) {
                st.backtick_run = 0;
                if (st.in_code_block) {
                    try writer.print("{s}", .{RESET});
                    st.in_code_block = false;
                    // skip rest of line (closing fence has no language).
                    while (i + 1 < chunk.len and chunk[i + 1] != '\n') : (i += 1) {}
                } else {
                    st.in_code_block = true;
                    // Read language token after the fence.
                    var lang: []const u8 = "";
                    var j = i + 1;
                    while (j < chunk.len and chunk[j] != '\n') : (j += 1) {}
                    if (j > i + 1) lang = chunk[i + 1 .. j];
                    i = if (j == chunk.len) j - 1 else j - 1;
                    try writer.print("{s}{s:>4}{s} {s}│{s} ", .{ DIM, lang, RESET, DIM, RESET });
                }
                continue;
            }
            // Could still be backtick literal or inline code; handle below if not fence.
        } else if (st.backtick_run > 0 and c != '`') {
            // Was building toward fence but interrupted. Emit accumulated.
            var k: u8 = 0;
            while (k < st.backtick_run) : (k += 1) {
                if (st.in_inline_code) {
                    try writer.writeAll(RESET);
                    st.in_inline_code = false;
                } else {
                    try writer.print("{s}{s}", .{ DIM, CYAN });
                    try writer.writeByte('`');
                    st.in_inline_code = true;
                }
            }
            st.backtick_run = 0;
        }

        // Inside code block: just emit, with a left bar at line start.
        if (st.in_code_block) {
            if (st.at_line_start) {
                try writer.print("{s}     │{s} ", .{ DIM, RESET });
                st.at_line_start = false;
            }
            try writer.writeByte(c);
            continue;
        }

        // Header: # at line start (any depth).
        if (st.at_line_start and c == '#') {
            try writer.print("{s}", .{BOLD});
            try writer.writeByte(c);
            // Continue eating # then space; the bold will close at \n via the
            // logic above.
            st.in_bold = true;
            st.at_line_start = false;
            continue;
        }

        // Inline code with single `.
        if (c == '`') {
            if (st.in_inline_code) {
                try writer.writeAll(RESET);
                st.in_inline_code = false;
            } else {
                try writer.print("{s}{s}", .{ DIM, CYAN });
                try writer.writeByte(c);
                st.in_inline_code = true;
                st.at_line_start = false;
                continue;
            }
            st.at_line_start = false;
            try writer.writeByte(c);
            continue;
        }

        // Bold/italic with *.
        if (c == '*') {
            if (st.pending_star) {
                // `**` → toggle bold.
                st.pending_star = false;
                if (st.in_bold) {
                    try writer.writeAll(RESET);
                    st.in_bold = false;
                } else {
                    try writer.writeAll(BOLD);
                    st.in_bold = true;
                }
                st.at_line_start = false;
                continue;
            }
            // Could be `*` (italic) or first of `**` — wait for next char.
            st.pending_star = true;
            continue;
        }

        // Drain a pending lone `*` as italic toggle.
        if (st.pending_star) {
            st.pending_star = false;
            if (st.in_italic) {
                try writer.writeAll(RESET);
                st.in_italic = false;
            } else {
                try writer.writeAll(ITALIC);
                st.in_italic = true;
            }
        }

        try writer.writeByte(c);
        st.at_line_start = false;
    }
}

// ──── Tool call rendering ──────────────────────────────────────────────────

/// Print a single tool-call header line. file_path may be null.
pub fn toolCall(
    writer: anytype,
    alloc: std.mem.Allocator,
    name: []const u8,
    file_path_opt: ?[]const u8,
    summary_str: []const u8,
) !void {
    try writer.print("\n{s}  {s} {s}{s}{s}  ", .{
        DIM,
        toolIcon(name),
        BOLD,
        name,
        RESET,
    });
    if (file_path_opt) |fp| {
        try filePath(writer, alloc, fp);
    } else {
        try writer.print("{s}{s}{s}", .{ DIM, summary_str, RESET });
    }
    try writer.writeAll("\n");
}

/// Print a tool result indented under the call. Truncates to max_lines and
/// applies diff coloring (lines starting with + or - inside an edit result).
pub fn toolResult(
    writer: anytype,
    result: []const u8,
    is_edit: bool,
) !void {
    const max_lines: usize = 8;
    var line_no: usize = 0;
    var emitted: usize = 0;
    var it = std.mem.splitScalar(u8, result, '\n');
    var first = true;
    while (it.next()) |line| {
        line_no += 1;
        if (line_no > 1 and emitted >= max_lines) {
            try writer.print("  {s}└─ … {d} more lines{s}\n", .{ DIM, line_no - max_lines, RESET });
            return;
        }
        if (line.len == 0 and !first) continue;
        const prefix: []const u8 = if (first) "  └─ " else "     ";
        first = false;
        if (is_edit and line.len > 0) {
            const c0 = line[0];
            if (c0 == '+') {
                try writer.print("{s}{s}{s}{s}{s}\n", .{ DIM, prefix, GREEN, line, RESET });
                emitted += 1;
                continue;
            } else if (c0 == '-' and !(line.len >= 3 and std.mem.eql(u8, line[0..3], "---"))) {
                try writer.print("{s}{s}{s}{s}{s}\n", .{ DIM, prefix, RED, line, RESET });
                emitted += 1;
                continue;
            }
        }
        try writer.print("{s}{s}{s}{s}\n", .{ DIM, prefix, line, RESET });
        emitted += 1;
    }
}

// ──── Sections ─────────────────────────────────────────────────────────────

pub fn banner(
    writer: anytype,
    model: []const u8,
    mode: []const u8,
) !void {
    const mc = modeColor(mode);
    try writer.print("{s}zac{s} · {s} · {s}{s} mode{s}\n", .{
        BOLD,         RESET,
        model,        mc,
        mode,         RESET,
    });
    try writer.print("{s}{s}{s}\n", .{
        DIM,
        "─" ** 40,
        RESET,
    });
}

pub fn turnDivider(
    writer: anytype,
    turn: u64,
    prompt_tokens: u64,
    completion_tokens: u64,
    duration_ms: u64,
) !void {
    if (!color_enabled) {
        try writer.print("\n[turn {d} · in:{d} out:{d} · {d}ms]\n\n", .{
            turn, prompt_tokens, completion_tokens, duration_ms,
        });
        return;
    }
    try writer.print("\n{s}─── turn {d} · in:{d} out:{d} · {d}ms ───{s}\n\n", .{
        DIM, turn, prompt_tokens, completion_tokens, duration_ms, RESET,
    });
}

// ──── Permission box ───────────────────────────────────────────────────────

pub fn permissionBox(
    writer: anytype,
    tool: []const u8,
    preview: []const u8,
    pattern: []const u8,
) !void {
    if (!color_enabled) {
        try writer.print("\n[permission] {s}: {s}\n", .{ tool, preview });
        try writer.print("Allow? [y]es / [a]lways / [p]attern '{s}' / [N]o: ", .{pattern});
        return;
    }
    try writer.print("\n  {s}{s}┌─ permission ─────────────────────────────────{s}\n", .{ BOLD, YELLOW, RESET });
    try writer.print("  {s}{s}│{s}  tool:  {s}{s}{s}\n", .{ BOLD, YELLOW, RESET, BOLD, tool, RESET });
    const trimmed = if (preview.len > 60) preview[0..60] else preview;
    try writer.print("  {s}{s}│{s}  input: {s}{s}{s}\n", .{ BOLD, YELLOW, RESET, DIM, trimmed, RESET });
    try writer.print("  {s}{s}└──────────────────────────────────────────────{s}\n", .{ BOLD, YELLOW, RESET });
    try writer.print("  {s}[y]{s}es  {s}[a]{s}lways  {s}[p]{s}attern '{s}'  {s}[N]{s}o: ", .{
        BOLD, RESET, BOLD, RESET, BOLD, RESET, pattern, BOLD, RESET,
    });
}
