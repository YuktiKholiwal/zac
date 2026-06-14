const std = @import("std");

/// Rough per-million-token pricing for the most-used models routed via the
/// Vercel AI Gateway. These are the prompt (input) prices; completion (output)
/// is typically 3-5× higher but we only estimate input cost since output size
/// is unknown ahead of the call.
///
/// Numbers are best-effort approximations as of late 2025. They are NOT a
/// source of truth — the Gateway is — but they're good enough for the user
/// to spot a "this turn will cost $0.05" vs "this turn will cost $5.00."
const Price = struct {
    prefix: []const u8,
    input_per_m: f32,
    output_per_m: f32,
};

const TABLE = [_]Price{
    .{ .prefix = "anthropic/claude-opus", .input_per_m = 15.0, .output_per_m = 75.0 },
    .{ .prefix = "anthropic/claude-sonnet", .input_per_m = 3.0, .output_per_m = 15.0 },
    .{ .prefix = "anthropic/claude-haiku", .input_per_m = 1.0, .output_per_m = 5.0 },
    .{ .prefix = "openai/gpt-4o", .input_per_m = 2.5, .output_per_m = 10.0 },
    .{ .prefix = "openai/gpt-4", .input_per_m = 5.0, .output_per_m = 15.0 },
    .{ .prefix = "openai/o1", .input_per_m = 15.0, .output_per_m = 60.0 },
    .{ .prefix = "openai/o3", .input_per_m = 15.0, .output_per_m = 60.0 },
    .{ .prefix = "google/gemini-2.0", .input_per_m = 0.15, .output_per_m = 0.6 },
    .{ .prefix = "google/gemini", .input_per_m = 1.25, .output_per_m = 5.0 },
};

fn lookup(model: []const u8) ?Price {
    for (TABLE) |p| {
        if (std.mem.startsWith(u8, model, p.prefix)) return p;
    }
    return null;
}

/// Starting guess before we've seen a real (bytes, tokens) sample: the usual
/// OpenAI rule of ~4 bytes per token for an English/code mix.
pub const DEFAULT_BYTES_PER_TOKEN: f32 = 4.0;

/// Derive an actual bytes-per-token ratio from a turn's real usage so the next
/// projection is calibrated to this model + this conversation rather than a
/// fixed guess. Returns null for unusable samples (no tokens, or a ratio so far
/// outside the plausible 1–20 band that it's noise from a tiny/odd turn).
pub fn calibrate(prompt_bytes: usize, prompt_tokens: u64) ?f32 {
    if (prompt_tokens == 0) return null;
    const ratio = @as(f32, @floatFromInt(prompt_bytes)) / @as(f32, @floatFromInt(prompt_tokens));
    if (ratio < 1.0 or ratio > 20.0) return null;
    return ratio;
}

/// Estimate the input cost of the next turn given the current conversation size
/// and a bytes-per-token ratio (use DEFAULT_BYTES_PER_TOKEN until calibrated).
/// Returns input-only cost; we don't predict output length. -1 for unknown model.
pub fn projectInputCost(model: []const u8, prompt_bytes: usize, bytes_per_token: f32) f32 {
    const price = lookup(model) orelse return -1.0;
    const bpt = if (bytes_per_token > 0) bytes_per_token else DEFAULT_BYTES_PER_TOKEN;
    const tokens: f32 = @as(f32, @floatFromInt(prompt_bytes)) / bpt;
    return tokens / 1_000_000.0 * price.input_per_m;
}

/// Compute total bytes across all message contents — proxy for prompt size.
pub fn promptBytes(msgs_content_lens: []const usize) usize {
    var total: usize = 0;
    for (msgs_content_lens) |n| total += n;
    return total;
}

test "pricing: calibrate rejects unusable samples, accepts plausible ones" {
    try std.testing.expect(calibrate(1000, 0) == null); // no tokens
    try std.testing.expect(calibrate(100, 1000) == null); // 0.1 b/tok — implausible
    try std.testing.expect(calibrate(1_000_000, 10) == null); // 100k b/tok — implausible
    const r = calibrate(4000, 1000).?; // exactly 4.0
    try std.testing.expect(@abs(r - 4.0) < 0.001);
}

test "pricing: calibrated ratio changes the estimate; unknown model is -1" {
    const bytes: usize = 3_000_000; // 3 MB of prompt
    // sonnet input is $3/M tokens. At 4 b/tok → 750k tok → $2.25.
    const at_default = projectInputCost("anthropic/claude-sonnet-4-5", bytes, DEFAULT_BYTES_PER_TOKEN);
    try std.testing.expect(@abs(at_default - 2.25) < 0.01);
    // At a denser 3 b/tok → 1M tok → $3.00.
    const at_dense = projectInputCost("anthropic/claude-sonnet-4-5", bytes, 3.0);
    try std.testing.expect(at_dense > at_default);
    // Unknown model.
    try std.testing.expect(projectInputCost("acme/who-knows", bytes, 4.0) < 0);
    // Zero/negative ratio falls back to the default rather than dividing by zero.
    const at_zero = projectInputCost("anthropic/claude-sonnet-4-5", bytes, 0);
    try std.testing.expect(@abs(at_zero - at_default) < 0.001);
}
