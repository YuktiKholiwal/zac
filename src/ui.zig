const std = @import("std");
const builtin = @import("builtin");

// ──── ANSI codes ────────────────────────────────────────────────────────────
// `var` so init() can blank them out for --no-color / non-TTY output.

pub var RESET: []const u8 = "\x1b[0m";
pub var BOLD: []const u8 = "\x1b[1m";
pub var DIM: []const u8 = "\x1b[2m";
pub var ITALIC: []const u8 = "\x1b[3m";

pub var RED: []const u8 = "\x1b[31m";
pub var GREEN: []const u8 = "\x1b[32m";
pub var YELLOW: []const u8 = "\x1b[33m";
pub var BLUE: []const u8 = "\x1b[34m";
pub var MAGENTA: []const u8 = "\x1b[35m";
pub var CYAN: []const u8 = "\x1b[36m";

var color_enabled: bool = true;

pub fn init(no_color_flag: bool) void {
    const enabled = !no_color_flag and std.io.getStdOut().isTty();
    color_enabled = enabled;
    if (enabled) return;
    RESET = "";
    BOLD = "";
    DIM = "";
    ITALIC = "";
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

// ──── Terminal width detection ─────────────────────────────────────────────

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

const TIOCGWINSZ: c_ulong = switch (builtin.os.tag) {
    .linux => 0x5413,
    .macos, .ios, .tvos, .watchos => 0x40087468,
    else => 0x5413,
};

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

pub fn termCols() u16 {
    var ws: Winsize = undefined;
    if (ioctl(1, TIOCGWINSZ, &ws) != 0) return 80;
    if (ws.ws_col < 20) return 80;
    return ws.ws_col;
}

// ──── Tool icons + mode colors ─────────────────────────────────────────────

pub fn toolIcon(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "read")) return "▸";
    if (std.mem.eql(u8, name, "write")) return "▣";
    if (std.mem.eql(u8, name, "edit")) return "✎";
    if (std.mem.eql(u8, name, "bash")) return "→";
    if (std.mem.eql(u8, name, "grep")) return "⌕";
    if (std.mem.eql(u8, name, "find")) return "⊞";
    if (std.mem.eql(u8, name, "ls")) return "⊟";
    if (std.mem.eql(u8, name, "plan")) return "☑";
    return "•";
}

pub fn modeColor(mode: []const u8) []const u8 {
    if (std.mem.eql(u8, mode, "code")) return GREEN;
    if (std.mem.eql(u8, mode, "plan")) return BLUE;
    if (std.mem.eql(u8, mode, "ask")) return CYAN;
    if (std.mem.eql(u8, mode, "review") or std.mem.eql(u8, mode, "review-security")) return YELLOW;
    if (std.mem.eql(u8, mode, "debug")) return MAGENTA;
    return DIM;
}

// ──── Out-of-band ──────────────────────────────────────────────────────────

pub fn setTitle(writer: anytype, title: []const u8) !void {
    if (!color_enabled) return;
    try writer.print("\x1b]0;{s}\x07", .{title});
}

pub fn bell(writer: anytype) !void {
    if (!color_enabled) return;
    try writer.writeAll("\x07");
}

pub fn link(writer: anytype, url: []const u8, text: []const u8) !void {
    if (!color_enabled) {
        try writer.writeAll(text);
        return;
    }
    try writer.print("\x1b]8;;{s}\x1b\\{s}\x1b]8;;\x1b\\", .{ url, text });
}

pub fn filePath(writer: anytype, alloc: std.mem.Allocator, path: []const u8) !void {
    if (!color_enabled) {
        try writer.writeAll(path);
        return;
    }
    const abs = if (std.fs.path.isAbsolute(path))
        try alloc.dupe(u8, path)
    else blk: {
        const cwd = std.process.getCwdAlloc(alloc) catch {
            try writer.print("{s}{s}{s}", .{ CYAN, path, RESET });
            return;
        };
        defer alloc.free(cwd);
        break :blk try std.fs.path.join(alloc, &.{ cwd, path });
    };
    defer alloc.free(abs);
    const url = try std.fmt.allocPrint(alloc, "file://{s}", .{abs});
    defer alloc.free(url);
    try writer.writeAll(CYAN);
    try link(writer, url, path);
    try writer.writeAll(RESET);
}

// ──── Line-buffered renderer ───────────────────────────────────────────────

/// Buffers streaming text chunks until a complete line is available, then
/// renders that line through a one-shot markdown formatter. This avoids the
/// edge cases of per-character streaming state.
pub const LineRenderer = struct {
    alloc: std.mem.Allocator,
    line_buf: std.ArrayList(u8),
    in_code_block: bool = false,
    code_lang: ?[]u8 = null,
    cols: u16,

    pub fn init(alloc: std.mem.Allocator) LineRenderer {
        return .{
            .alloc = alloc,
            .line_buf = std.ArrayList(u8).init(alloc),
            .cols = termCols(),
        };
    }

    pub fn deinit(self: *LineRenderer) void {
        if (self.code_lang) |l| self.alloc.free(l);
        self.line_buf.deinit();
    }

    /// Append a chunk of streamed text. Emits complete lines as they arrive.
    pub fn feed(self: *LineRenderer, writer: anytype, chunk: []const u8) !void {
        for (chunk) |c| {
            if (c == '\n') {
                try self.renderLine(writer, self.line_buf.items);
                try writer.writeByte('\n');
                self.line_buf.clearRetainingCapacity();
            } else {
                try self.line_buf.append(c);
            }
        }
    }

    /// Flush any partial line at end of turn.
    pub fn flush(self: *LineRenderer, writer: anytype) !void {
        if (self.line_buf.items.len > 0) {
            try self.renderLine(writer, self.line_buf.items);
            try writer.writeByte('\n');
            self.line_buf.clearRetainingCapacity();
        }
    }

    fn renderLine(self: *LineRenderer, writer: anytype, line: []const u8) !void {
        // Fenced code block toggles
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (self.in_code_block) {
                self.in_code_block = false;
                if (self.code_lang) |l| {
                    self.alloc.free(l);
                    self.code_lang = null;
                }
            } else {
                self.in_code_block = true;
                const lang_raw = std.mem.trim(u8, trimmed[3..], " \t");
                self.code_lang = if (lang_raw.len > 0)
                    try self.alloc.dupe(u8, lang_raw)
                else
                    null;
            }
            return;
        }

        // Inside code block: dim left bar, no markdown parsing
        if (self.in_code_block) {
            const lang = self.code_lang orelse "";
            try writer.print("{s}{s: >4}{s} {s}│{s} ", .{ DIM, lang, RESET, DIM, RESET });
            try writer.writeAll(line);
            return;
        }

        // Headers: # … ###### at line start
        var rest = line;
        var leading_hashes: usize = 0;
        while (leading_hashes < rest.len and rest[leading_hashes] == '#') leading_hashes += 1;
        if (leading_hashes > 0 and leading_hashes <= 6 and leading_hashes < rest.len and rest[leading_hashes] == ' ') {
            rest = rest[leading_hashes + 1 ..];
            try writer.print("{s}", .{BOLD});
            try renderInline(writer, rest, self.cols);
            try writer.print("{s}", .{RESET});
            return;
        }

        // Blockquote: > …
        if (rest.len > 1 and rest[0] == '>' and rest[1] == ' ') {
            try writer.print("{s}│{s} ", .{ DIM, RESET });
            try renderInline(writer, rest[2..], self.cols -| 2);
            return;
        }

        // List bullet: - or * or 1. at line start
        var trimmed_leading: usize = 0;
        while (trimmed_leading < rest.len and rest[trimmed_leading] == ' ') trimmed_leading += 1;
        const after_indent = rest[trimmed_leading..];
        if (after_indent.len >= 2 and (after_indent[0] == '-' or after_indent[0] == '*') and after_indent[1] == ' ') {
            try writer.writeByteNTimes(' ', trimmed_leading);
            try writer.print("{s}•{s} ", .{ DIM, RESET });
            try renderInline(writer, after_indent[2..], self.cols -| @as(u16, @intCast(trimmed_leading + 2)));
            return;
        }

        // Default: inline markdown on the whole line
        try renderInline(writer, rest, self.cols);
    }
};

// ──── Inline markdown + word-wrap ──────────────────────────────────────────

/// Single-pass inline renderer: emits **bold**, *italic*, `code`, and word-
/// wraps the result. Word-wrap accounts for ANSI escapes being zero-width.
fn renderInline(writer: anytype, line: []const u8, max_cols: u16) !void {
    // First pass: produce the styled line into a buffer.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var buf = std.ArrayList(u8).init(arena.allocator());
    const bw = buf.writer();

    var i: usize = 0;
    var in_bold = false;
    var in_italic = false;
    var in_inline_code = false;
    while (i < line.len) {
        const c = line[i];
        // ** for bold
        if (c == '*' and i + 1 < line.len and line[i + 1] == '*') {
            if (in_bold) {
                try bw.writeAll(RESET);
                in_bold = false;
            } else {
                try bw.writeAll(BOLD);
                in_bold = true;
            }
            i += 2;
            continue;
        }
        // ` for inline code
        if (c == '`') {
            if (in_inline_code) {
                try bw.writeAll(RESET);
                in_inline_code = false;
            } else {
                try bw.print("{s}{s}", .{ DIM, CYAN });
                in_inline_code = true;
            }
            i += 1;
            continue;
        }
        // single * for italic (only if not adjacent to another *, and surrounded by non-space-ish)
        if (c == '*' and !in_inline_code) {
            if (in_italic) {
                try bw.writeAll(RESET);
                in_italic = false;
            } else {
                try bw.writeAll(ITALIC);
                in_italic = true;
            }
            i += 1;
            continue;
        }
        try bw.writeByte(c);
        i += 1;
    }
    if (in_bold or in_italic or in_inline_code) try bw.writeAll(RESET);

    // Second pass: word-wrap. ANSI escapes are zero-width.
    try wrap(writer, buf.items, max_cols);
}

fn wrap(writer: anytype, styled: []const u8, max_cols: u16) !void {
    if (max_cols < 20) {
        // Too narrow to wrap meaningfully; just emit raw.
        try writer.writeAll(styled);
        return;
    }
    // Walk styled, tracking visual width. Find word breaks (spaces).
    var line_start: usize = 0;
    var last_break: ?usize = null;
    var visual: u16 = 0;
    var i: usize = 0;
    while (i < styled.len) {
        // Skip ANSI escape sequences (\x1b[...m or \x1b]...\x1b\\ or \x07)
        if (styled[i] == '\x1b') {
            const esc_end = skipEscape(styled, i);
            i = esc_end;
            continue;
        }
        if (styled[i] == ' ') {
            last_break = i;
        }
        if (visual >= max_cols) {
            if (last_break) |b| {
                try writer.writeAll(styled[line_start..b]);
                try writer.writeByte('\n');
                line_start = b + 1;
                last_break = null;
                visual = 0;
                i = line_start;
                continue;
            }
            // No word boundary in range — hard wrap.
            try writer.writeAll(styled[line_start..i]);
            try writer.writeByte('\n');
            line_start = i;
            visual = 0;
            continue;
        }
        visual += 1;
        i += 1;
    }
    try writer.writeAll(styled[line_start..]);
}

fn skipEscape(s: []const u8, start: usize) usize {
    if (start >= s.len or s[start] != '\x1b') return start + 1;
    if (start + 1 >= s.len) return s.len;
    const next = s[start + 1];
    if (next == '[') {
        // CSI: ESC [ ... letter
        var j: usize = start + 2;
        while (j < s.len) : (j += 1) {
            const ch = s[j];
            if ((ch >= 0x40 and ch <= 0x7E)) return j + 1;
        }
        return s.len;
    }
    if (next == ']') {
        // OSC: ESC ] ... BEL or ESC \\
        var j: usize = start + 2;
        while (j < s.len) : (j += 1) {
            if (s[j] == '\x07') return j + 1;
            if (s[j] == '\x1b' and j + 1 < s.len and s[j + 1] == '\\') return j + 2;
        }
        return s.len;
    }
    return start + 2;
}

// ──── Tool call rendering with spinner ─────────────────────────────────────

/// Prints a "running…" line that the caller can later overwrite via
/// `toolCallFinish`. Returns the column-1 reset needed to overwrite.
pub fn toolCallStart(
    writer: anytype,
    alloc: std.mem.Allocator,
    name: []const u8,
    file_path_opt: ?[]const u8,
    summary_str: []const u8,
) !void {
    try writer.print("\n{s}  {s} {s}{s}{s}  ", .{ DIM, toolIcon(name), BOLD, name, RESET });
    if (file_path_opt) |fp| {
        try filePath(writer, alloc, fp);
    } else {
        try writer.print("{s}{s}{s}", .{ DIM, summary_str, RESET });
    }
    try writer.print(" {s}…{s}", .{ DIM, RESET });
    // No newline so toolCallFinish can \r overwrite.
}

/// Overwrite the "running…" line with the final status and indented result.
pub fn toolCallFinish(
    writer: anytype,
    alloc: std.mem.Allocator,
    name: []const u8,
    file_path_opt: ?[]const u8,
    summary_str: []const u8,
    result: []const u8,
    is_edit: bool,
    duration_ms: u64,
) !void {
    // \r to start of line, then \x1b[K to clear to end of line.
    if (color_enabled) try writer.writeAll("\r\x1b[K");
    try writer.print("  {s}{s}{s} {s}{s}{s}  ", .{ GREEN, toolIcon(name), RESET, BOLD, name, RESET });
    if (file_path_opt) |fp| {
        try filePath(writer, alloc, fp);
    } else {
        try writer.print("{s}{s}{s}", .{ DIM, summary_str, RESET });
    }
    try writer.print(" {s}{d}ms{s}\n", .{ DIM, duration_ms, RESET });
    try toolResultIndented(writer, result, is_edit);
}

fn toolResultIndented(writer: anytype, result: []const u8, is_edit: bool) !void {
    const max_lines: usize = 8;
    var line_no: usize = 0;
    var emitted: usize = 0;
    var it = std.mem.splitScalar(u8, result, '\n');
    var first = true;
    while (it.next()) |line| {
        line_no += 1;
        if (line.len == 0 and !first) continue;
        if (emitted >= max_lines) {
            try writer.print("  {s}└─ … {d} more lines{s}\n", .{ DIM, line_no - max_lines, RESET });
            return;
        }
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

pub fn banner(writer: anytype, model: []const u8, mode: []const u8) !void {
    const mc = modeColor(mode);
    try writer.print("{s}zac{s} · {s} · {s}{s} mode{s}\n", .{ BOLD, RESET, model, mc, mode, RESET });
    try writer.print("{s}{s}{s}\n", .{ DIM, "─" ** 40, RESET });
}

pub fn turnDivider(
    writer: anytype,
    turn: u64,
    prompt_tokens: u64,
    completion_tokens: u64,
    duration_ms: u64,
) !void {
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
    try writer.print("\n  {s}{s}┌─ permission ─────────────────────────────────{s}\n", .{ BOLD, YELLOW, RESET });
    try writer.print("  {s}{s}│{s}  tool:  {s}{s}{s}\n", .{ BOLD, YELLOW, RESET, BOLD, tool, RESET });
    const trimmed = if (preview.len > 60) preview[0..60] else preview;
    try writer.print("  {s}{s}│{s}  input: {s}{s}{s}\n", .{ BOLD, YELLOW, RESET, DIM, trimmed, RESET });
    try writer.print("  {s}{s}└──────────────────────────────────────────────{s}\n", .{ BOLD, YELLOW, RESET });
    try writer.print("  {s}[y]{s}es  {s}[t]{s}rust tool  {s}[p]{s}attern '{s}'  {s}[N]{s}o: ", .{
        BOLD, RESET, BOLD, RESET, BOLD, RESET, pattern, BOLD, RESET,
    });
}
