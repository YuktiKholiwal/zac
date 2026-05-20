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

/// POSTs to {base_url}/chat/completions with stream=true.
/// Caller owns the returned Stream and must call deinit().
pub fn chatStream(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    cfg: Config,
    msgs: []const messages.Message,
    tools: []const messages.Tool,
) !Stream {
    const body = try buildRequestBody(alloc, cfg, msgs, tools);
    defer alloc.free(body);

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

    if (req.response.status != .ok) {
        // Drain body for error context, then bail.
        var err_buf: [4096]u8 = undefined;
        const n = req.reader().read(&err_buf) catch 0;
        std.log.err("gateway returned {d}: {s}", .{
            @intFromEnum(req.response.status),
            err_buf[0..n],
        });
        return error.GatewayHttpError;
    }

    return .{ .client = client, .req = req };
}

fn buildRequestBody(
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
