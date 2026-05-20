const std = @import("std");
const messages = @import("messages.zig");
const gateway = @import("gateway.zig");
const tools = @import("tools/mod.zig");
const agent = @import("agent.zig");
const prompt = @import("prompt.zig");
const env = @import("env.zig");
const cancel = @import("cancel.zig");
const permission_mod = @import("permission.zig");
const session = @import("session.zig");
const context = @import("context.zig");
const compaction = @import("compaction.zig");
const sse_mod = @import("sse.zig");
const sandbox = @import("sandbox.zig");
const ui = @import("ui.zig");

test {
    _ = @import("sse.zig");
    _ = @import("env.zig");
    _ = @import("gitignore.zig");
    _ = @import("tools/find_files.zig");
    _ = @import("messages.zig");
    _ = @import("permission.zig");
    _ = @import("gateway.zig");
    _ = @import("path_guard.zig");
    _ = @import("session.zig");
}

const DEFAULT_BASE_URL = "https://ai-gateway.vercel.sh/v1";
const DEFAULT_MODEL = "anthropic/claude-sonnet-4-5";

const Args = struct {
    one_shot: ?[]const u8 = null,
    continue_session: bool = false,
    yolo: bool = false,
    mode: prompt.Mode = .code,
    allow_outside: bool = false,
    no_sandbox: bool = false,
    no_color: bool = false,
    show_help: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    const stdin = std.io.getStdIn().reader();

    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);

    const args = parseArgs(argv) catch |err| {
        try stderr.print("argument error: {s}\n", .{@errorName(err)});
        try printHelp(stderr);
        return;
    };
    if (args.show_help) {
        try printHelp(stdout);
        return;
    }

    cancel.install();
    ui.init(args.no_color);

    var perm = permission_mod.Permission.init(alloc, args.yolo);
    defer perm.deinit();

    var env_file = env.load(alloc, ".env") catch |err| blk: {
        try stderr.print("warning: failed to read .env: {s}\n", .{@errorName(err)});
        break :blk env.EnvFile{
            .arena = std.heap.ArenaAllocator.init(alloc),
            .map = std.StringHashMap([]const u8).init(alloc),
        };
    };
    defer env_file.deinit();

    var cfg = loadConfig(alloc, &env_file) catch |err| {
        try stderr.print("Config error: {s}\n", .{@errorName(err)});
        try stderr.writeAll("Set AI_GATEWAY_API_KEY in .env or environment.\n");
        return;
    };
    cfg.allow_outside = args.allow_outside;
    tools.setAllowOutside(args.allow_outside);
    sandbox.setEnabled(!args.no_sandbox);
    defer freeConfig(alloc, cfg);

    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var current_mode = args.mode;

    var total_prompt_tokens: u64 = 0;
    var total_completion_tokens: u64 = 0;
    var turn_count: u64 = 0;

    const project_context = context.load(alloc) catch null;
    defer if (project_context) |c| alloc.free(c);
    if (project_context != null) {
        try stderr.writeAll("[loaded project context]\n");
    }

    var msgs: std.ArrayList(messages.Message) = if (args.continue_session) blk: {
        const loaded = session.load(alloc) catch |err| {
            try stderr.print("Could not load prior session: {s}. Starting fresh.\n", .{@errorName(err)});
            break :blk try freshMessages(alloc, current_mode, project_context);
        };
        break :blk loaded;
    } else try freshMessages(alloc, current_mode, project_context);
    defer freeMessages(alloc, &msgs);

    const tool_defs = try tools.definitions(alloc);
    defer alloc.free(tool_defs);

    // One-shot mode: run a single user prompt and exit.
    if (args.one_shot) |p| {
        try msgs.append(.{ .role = .user, .content = try alloc.dupe(u8, p) });
        _ = agent.run(alloc, &client, cfg, &perm, &msgs, tool_defs, stdout) catch |err| blk: {
            try stderr.print("\n[agent error: {s}]\n", .{@errorName(err)});
            break :blk std.mem.zeroes(sse_mod.Usage);
        };
        session.save(alloc, msgs.items) catch |err| {
            try stderr.print("warning: could not save session: {s}\n", .{@errorName(err)});
        };
        return;
    }

    try ui.banner(stdout, cfg.model, current_mode.name());
    try updateTitle(stdout, cfg.model, current_mode.name(), 0);
    try stdout.writeAll("Type your message. \\ at end of line = continue. /help for commands. Ctrl-D to quit.\n\n");

    var line_buf = std.ArrayList(u8).init(alloc);
    defer line_buf.deinit();
    var input_buf = std.ArrayList(u8).init(alloc);
    defer input_buf.deinit();

    while (true) {
        const input = readUserInput(stdin, stdout, &line_buf, &input_buf) catch |err| switch (err) {
            error.EndOfStream => {
                try stdout.writeAll("\n");
                session.save(alloc, msgs.items) catch {};
                return;
            },
            else => {
                // SIGINT during a blocking stdin read surfaces as an I/O error
                // on macOS rather than a clean interruption — distinguish via
                // the cancel flag. Any other error is fatal: continuing would
                // re-enter the same broken read and spam errors forever.
                if (cancel.take()) {
                    try stderr.writeAll("\n[Ctrl-C — use /exit or Ctrl-D to quit]\n");
                    continue;
                }
                try stderr.print("\n[input error: {s} — exiting]\n", .{@errorName(err)});
                session.save(alloc, msgs.items) catch {};
                return;
            },
        } orelse continue;

        if (cancel.take()) {
            try stderr.writeAll("[Ctrl-C — use /exit or Ctrl-D to quit]\n");
            continue;
        }

        const slash_ctx = SlashCtx{
            .total_prompt_tokens = total_prompt_tokens,
            .total_completion_tokens = total_completion_tokens,
            .turn_count = turn_count,
            .client = &client,
        };
        if (try handleSlash(alloc, input, &msgs, &current_mode, &cfg, project_context, slash_ctx, stdout, stderr)) |should_exit| {
            if (should_exit) return;
            continue;
        }

        try msgs.append(.{
            .role = .user,
            .content = try alloc.dupe(u8, input),
        });

        var timer = std.time.Timer.start() catch null;
        const turn_usage = agent.run(alloc, &client, cfg, &perm, &msgs, tool_defs, stdout) catch |err| blk: {
            try stderr.print("\n[agent error: {s}]\n", .{@errorName(err)});
            break :blk std.mem.zeroes(sse_mod.Usage);
        };
        const duration_ms: u64 = if (timer) |*t| t.read() / std.time.ns_per_ms else 0;
        cancel.reset();
        total_prompt_tokens += turn_usage.prompt_tokens;
        total_completion_tokens += turn_usage.completion_tokens;
        turn_count += 1;
        session.save(alloc, msgs.items) catch {};

        _ = compaction.maybeCompact(alloc, &client, cfg, &msgs, turn_usage.prompt_tokens, stderr, false) catch |err| {
            try stderr.print("[compaction error: {s}]\n", .{@errorName(err)});
        };

        try ui.turnDivider(
            stdout,
            turn_count,
            turn_usage.prompt_tokens,
            turn_usage.completion_tokens,
            duration_ms,
        );
        try updateTitle(stdout, cfg.model, current_mode.name(), total_prompt_tokens + total_completion_tokens);
    }
}

fn updateTitle(stdout: anytype, model: []const u8, mode: []const u8, total_tokens: u64) !void {
    var buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "zac · {s} · {s} · {d} tok", .{ model, mode, total_tokens }) catch return;
    try ui.setTitle(stdout, title);
}

fn parseArgs(argv: [][:0]u8) !Args {
    var out = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            out.show_help = true;
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--continue")) {
            out.continue_session = true;
        } else if (std.mem.eql(u8, a, "--yolo")) {
            out.yolo = true;
        } else if (std.mem.eql(u8, a, "--allow-outside")) {
            out.allow_outside = true;
        } else if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--prompt")) {
            i += 1;
            if (i >= argv.len) return error.MissingPromptValue;
            out.one_shot = argv[i];
        } else if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--mode")) {
            i += 1;
            if (i >= argv.len) return error.MissingModeValue;
            out.mode = prompt.Mode.parse(argv[i]) orelse return error.UnknownMode;
        } else if (std.mem.eql(u8, a, "--no-sandbox")) {
            out.no_sandbox = true;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            out.no_color = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownArg;
        } else {
            // Bare positional argument → treat as one-shot prompt.
            if (out.one_shot != null) return error.MultiplePrompts;
            out.one_shot = a;
        }
    }
    return out;
}

fn printHelp(w: anytype) !void {
    try w.writeAll(
        \\Usage: zac [options] [prompt]
        \\
        \\If a bare prompt is given (e.g. zac "explain this codebase"), it runs
        \\as a one-shot turn and exits, equivalent to -p "...".
        \\
        \\Options:
        \\  -p, --prompt "..."    Run one turn non-interactively and exit
        \\  -c, --continue        Continue the previous session
        \\  -m, --mode <name>     System prompt mode: code (default), plan, ask, review
        \\      --yolo            Auto-allow every tool call (skip permission prompts)
        \\      --allow-outside   Permit write/edit to paths outside the cwd
        \\      --no-sandbox      Disable bash sandboxing (macOS, on by default)
        \\      --no-color        Disable ANSI styling (also auto-off when not a TTY)
        \\  -h, --help            Show this help
        \\
        \\In-REPL commands:
        \\  /prompt <name>        Switch system prompt mode mid-session
        \\  /model <name>         Switch model mid-session
        \\  /reasoning on|off     Toggle visible reasoning stream
        \\  /usage                Show cumulative token totals for the session
        \\  /compact              Manually compact conversation history
        \\  /reset                Clear history
        \\  /help                 Show in-REPL help
        \\  /exit, /quit          Exit (Ctrl-D also works)
        \\
        \\Config (priority: shell env > .env > defaults):
        \\  AI_GATEWAY_API_KEY    Required
        \\  AI_GATEWAY_BASE_URL   Optional (default: https://ai-gateway.vercel.sh/v1)
        \\  AI_GATEWAY_MODEL      Optional (default: anthropic/claude-sonnet-4-5)
        \\
    );
}

fn freshMessages(
    alloc: std.mem.Allocator,
    mode: prompt.Mode,
    project_context: ?[]const u8,
) !std.ArrayList(messages.Message) {
    var msgs = std.ArrayList(messages.Message).init(alloc);
    const sys = try prompt.build(alloc, mode, project_context);
    try msgs.append(.{ .role = .system, .content = sys });
    return msgs;
}

/// Returns null if not a slash command. Otherwise returns whether to exit.
const SlashCtx = struct {
    total_prompt_tokens: u64,
    total_completion_tokens: u64,
    turn_count: u64,
    client: *std.http.Client,
};

fn handleSlash(
    alloc: std.mem.Allocator,
    input: []const u8,
    msgs: *std.ArrayList(messages.Message),
    current_mode: *prompt.Mode,
    cfg: *gateway.Config,
    project_context: ?[]const u8,
    ctx: SlashCtx,
    stdout: anytype,
    stderr: anytype,
) !?bool {
    if (input.len == 0 or input[0] != '/') return null;

    if (std.mem.eql(u8, input, "/exit") or std.mem.eql(u8, input, "/quit")) {
        session.save(alloc, msgs.items) catch {};
        return true;
    }

    if (std.mem.eql(u8, input, "/help")) {
        try printHelp(stdout);
        return false;
    }

    if (std.mem.eql(u8, input, "/reset")) {
        freeMessages(alloc, msgs);
        msgs.* = try freshMessages(alloc, current_mode.*, project_context);
        try stdout.writeAll("[history cleared]\n\n");
        return false;
    }

    if (std.mem.startsWith(u8, input, "/prompt")) {
        const rest = std.mem.trim(u8, input[7..], " \t");
        if (rest.len == 0) {
            try stdout.print("current mode: {s}. available: {s}\n", .{ current_mode.name(), prompt.ALL_MODES });
            return false;
        }
        const new_mode = prompt.Mode.parse(rest) orelse {
            try stderr.print("unknown mode '{s}'. available: {s}\n", .{ rest, prompt.ALL_MODES });
            return false;
        };
        current_mode.* = new_mode;
        if (msgs.items.len > 0 and msgs.items[0].role == .system) {
            alloc.free(msgs.items[0].content);
            msgs.items[0].content = try prompt.build(alloc, new_mode, project_context);
        }
        try stdout.print("[mode switched to {s}]\n\n", .{new_mode.name()});
        return false;
    }

    if (std.mem.startsWith(u8, input, "/reasoning")) {
        const rest = std.mem.trim(u8, input[10..], " \t");
        if (std.mem.eql(u8, rest, "on")) {
            cfg.show_reasoning = true;
            try stdout.writeAll("[reasoning visible]\n\n");
        } else if (std.mem.eql(u8, rest, "off")) {
            cfg.show_reasoning = false;
            try stdout.writeAll("[reasoning hidden]\n\n");
        } else {
            try stdout.print("/reasoning is {s}. use /reasoning on|off\n", .{if (cfg.show_reasoning) "on" else "off"});
        }
        return false;
    }

    if (std.mem.eql(u8, input, "/usage")) {
        try stdout.print(
            "turns: {d}    cumulative tokens — in: {d}    out: {d}    total: {d}\n",
            .{
                ctx.turn_count,
                ctx.total_prompt_tokens,
                ctx.total_completion_tokens,
                ctx.total_prompt_tokens + ctx.total_completion_tokens,
            },
        );
        return false;
    }

    if (std.mem.eql(u8, input, "/compact")) {
        const did = compaction.maybeCompact(alloc, ctx.client, cfg.*, msgs, 0, stderr, true) catch |err| blk: {
            try stderr.print("[compaction error: {s}]\n", .{@errorName(err)});
            break :blk false;
        };
        if (!did) try stdout.writeAll("[nothing to compact]\n");
        return false;
    }

    if (std.mem.startsWith(u8, input, "/model")) {
        const rest = std.mem.trim(u8, input[6..], " \t");
        if (rest.len == 0) {
            try stdout.print("current model: {s}\n", .{cfg.model});
            return false;
        }
        const new_model = try alloc.dupe(u8, rest);
        alloc.free(cfg.model);
        cfg.model = new_model;
        try stdout.print("[model switched to {s}]\n\n", .{cfg.model});
        return false;
    }

    try stderr.print("unknown command: {s}. /help for list.\n", .{input});
    return false;
}

/// Reads one logical message from stdin. Lines ending with '\\' continue.
fn readUserInput(
    stdin: anytype,
    stdout: anytype,
    line_buf: *std.ArrayList(u8),
    input_buf: *std.ArrayList(u8),
) !?[]const u8 {
    input_buf.clearRetainingCapacity();
    var first = true;
    while (true) {
        try stdout.writeAll(if (first) "> " else "... ");
        first = false;
        line_buf.clearRetainingCapacity();
        try stdin.streamUntilDelimiter(line_buf.writer(), '\n', null);

        var line = line_buf.items;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (line.len > 0 and line[line.len - 1] == '\\') {
            try input_buf.appendSlice(line[0 .. line.len - 1]);
            try input_buf.append('\n');
            continue;
        }
        try input_buf.appendSlice(line);
        break;
    }

    const trimmed = std.mem.trim(u8, input_buf.items, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn loadConfig(alloc: std.mem.Allocator, env_file: *const env.EnvFile) !gateway.Config {
    const api_key = try resolveOwned(alloc, env_file, "AI_GATEWAY_API_KEY", null) orelse
        return error.MissingApiKey;
    errdefer alloc.free(api_key);

    const base_url = (try resolveOwned(alloc, env_file, "AI_GATEWAY_BASE_URL", DEFAULT_BASE_URL)).?;
    errdefer alloc.free(base_url);

    const model = (try resolveOwned(alloc, env_file, "AI_GATEWAY_MODEL", DEFAULT_MODEL)).?;

    return .{
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
    };
}

fn resolveOwned(
    alloc: std.mem.Allocator,
    env_file: *const env.EnvFile,
    key: []const u8,
    default: ?[]const u8,
) !?[]u8 {
    if (std.process.getEnvVarOwned(alloc, key)) |v| {
        return v;
    } else |_| {}
    if (env_file.get(key)) |v| {
        return try alloc.dupe(u8, v);
    }
    if (default) |d| {
        return try alloc.dupe(u8, d);
    }
    return null;
}

fn freeConfig(alloc: std.mem.Allocator, cfg: gateway.Config) void {
    alloc.free(cfg.api_key);
    alloc.free(cfg.base_url);
    alloc.free(cfg.model);
}

fn freeMessages(alloc: std.mem.Allocator, msgs: *std.ArrayList(messages.Message)) void {
    for (msgs.items) |m| {
        alloc.free(m.content);
        if (m.tool_call_id) |id| alloc.free(id);
        for (m.tool_calls) |c| {
            alloc.free(c.id);
            alloc.free(c.name);
            alloc.free(c.arguments);
        }
        if (m.tool_calls.len > 0) alloc.free(m.tool_calls);
    }
    msgs.deinit();
}
