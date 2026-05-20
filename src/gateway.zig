const std = @import("std");
const messages = @import("messages.zig");

pub const Config = struct {
    /// e.g. "https://ai-gateway.vercel.sh/v1"
    base_url: []u8,
    api_key: []u8,
    /// e.g. "anthropic/claude-sonnet-4-5" or "openai/gpt-4o"
    model: []u8,
    max_tokens: u32 = 4096,
    temperature: f32 = 0.7,
    /// Whether to print streamed reasoning tokens dim. Toggled by /reasoning.
    show_reasoning: bool = true,
    /// If true, write/edit may target paths outside the cwd. Set by --allow-outside.
    allow_outside: bool = false,
};

pub const Stream = struct {
    client: *std.http.Client,
    req: std.http.Client.Request,

    pub fn deinit(self: *Stream) void {
        self.req.deinit();
    }

    pub fn reader(self: *Stream) std.http.Client.Request.Reader {
        return self.req.reader();
    }
};

/// POSTs to {base_url}/chat/completions with stream=true. Retries once on a
/// 5xx response after a brief backoff. Caller owns the returned Stream and
/// must call deinit().
pub fn chatStream(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    cfg: Config,
    msgs: []const messages.Message,
    tools: []const messages.Tool,
) !Stream {
    const body = try buildRequestBody(alloc, cfg, msgs, tools);
    defer alloc.free(body);

    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        const result = try chatOnce(alloc, client, cfg, body);
        switch (result) {
            .ok => |s| return s,
            .retryable => |status| {
                if (attempt >= 1) {
                    std.log.err("gateway returned {d} after retry; giving up.", .{status});
                    return error.GatewayHttpError;
                }
                std.log.warn("gateway returned {d}; retrying in 1s...", .{status});
                std.time.sleep(1 * std.time.ns_per_s);
            },
            .fatal => return error.GatewayHttpError,
        }
    }
}

const Attempt = union(enum) {
    ok: Stream,
    retryable: u16,
    fatal: void,
};

fn chatOnce(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    cfg: Config,
    body: []const u8,
) !Attempt {
    const url_str = try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{cfg.base_url});
    defer alloc.free(url_str);
    const uri = try std.Uri.parse(url_str);

    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{cfg.api_key});
    defer alloc.free(auth);

    var server_header_buf: [16 * 1024]u8 = undefined;
    var req = try client.open(.POST, uri, .{
        .server_header_buffer = &server_header_buf,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth },
            .{ .name = "accept", .value = "text/event-stream" },
        },
    });
    errdefer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    try req.send();
    try req.writeAll(body);
    try req.finish();
    try req.wait();

    const status = @intFromEnum(req.response.status);
    if (req.response.status == .ok) {
        return .{ .ok = .{ .client = client, .req = req } };
    }

    var err_buf: [4096]u8 = undefined;
    const n = req.reader().read(&err_buf) catch 0;
    std.log.err("gateway returned {d}: {s}", .{ status, err_buf[0..n] });
    req.deinit();

    if (status >= 500 and status < 600) return .{ .retryable = status };
    return .{ .fatal = {} };
}

pub fn buildRequestBody(
    alloc: std.mem.Allocator,
    cfg: Config,
    msgs: []const messages.Message,
    tools: []const messages.Tool,
) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();

    var jws = std.json.writeStream(buf.writer(), .{});
    try jws.beginObject();

    try jws.objectField("model");
    try jws.write(cfg.model);

    try jws.objectField("stream");
    try jws.write(true);

    try jws.objectField("stream_options");
    try jws.beginObject();
    try jws.objectField("include_usage");
    try jws.write(true);
    try jws.endObject();

    try jws.objectField("max_tokens");
    try jws.write(cfg.max_tokens);

    try jws.objectField("temperature");
    try jws.write(cfg.temperature);

    try jws.objectField("messages");
    try jws.write(msgs);

    if (tools.len > 0) {
        try jws.objectField("tools");
        try jws.write(tools);
    }

    try jws.endObject();

    return buf.toOwnedSlice();
}

test "gateway: request body has required fields" {
    const alloc = std.testing.allocator;
    const key = try alloc.dupe(u8, "k");
    defer alloc.free(key);
    const url = try alloc.dupe(u8, "u");
    defer alloc.free(url);
    const model = try alloc.dupe(u8, "anthropic/claude-sonnet-4-5");
    defer alloc.free(model);

    const cfg = Config{
        .api_key = key,
        .base_url = url,
        .model = model,
    };
    const msgs = [_]messages.Message{
        .{ .role = .user, .content = "hi" },
    };
    const body = try buildRequestBody(alloc, cfg, &msgs, &.{});
    defer alloc.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"anthropic/claude-sonnet-4-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"include_usage\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"messages\"") != null);
    // No tools array when tools slice is empty.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
}

test "gateway: request body includes tools when given" {
    const alloc = std.testing.allocator;
    const key = try alloc.dupe(u8, "k");
    defer alloc.free(key);
    const url = try alloc.dupe(u8, "u");
    defer alloc.free(url);
    const model = try alloc.dupe(u8, "openai/gpt-4o");
    defer alloc.free(model);
    const cfg = Config{ .api_key = key, .base_url = url, .model = model };
    const msgs = [_]messages.Message{.{ .role = .user, .content = "hi" }};
    const tools = [_]messages.Tool{
        .{ .name = "read", .description = "r", .parameters_json = "{}" },
    };
    const body = try buildRequestBody(alloc, cfg, &msgs, &tools);
    defer alloc.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"read\"") != null);
}
