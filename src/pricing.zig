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

/// Estimate the cost of the next turn given the current conversation size.
/// Returns input-only cost; we don't predict output length.
pub fn projectInputCost(model: []const u8, prompt_bytes: usize) f32 {
    const price = lookup(model) orelse return -1.0; // unknown
    // OpenAI-style rough rule: ~4 bytes per token for English/code mix.
    const tokens: f32 = @as(f32, @floatFromInt(prompt_bytes)) / 4.0;
    return tokens / 1_000_000.0 * price.input_per_m;
}

/// Compute total bytes across all message contents — proxy for prompt size.
pub fn promptBytes(msgs_content_lens: []const usize) usize {
    var total: usize = 0;
    for (msgs_content_lens) |n| total += n;
    return total;
}
