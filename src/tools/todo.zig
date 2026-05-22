const std = @import("std");
const messages = @import("../messages.zig");
const mod = @import("mod.zig");

pub const def = messages.Tool{
    .name = "plan",
    .description = "Record a checklist of the multi-step work you intend to do. Each call REPLACES the prior plan; always send the complete list. Use this to break a complex request into visible steps and mark them as you go.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "todos": {
    \\      "type": "array",
    \\      "items": {
    \\        "type": "object",
    \\        "properties": {
    \\          "content": {"type": "string", "description": "What needs to be done"},
    \\          "status": {"type": "string", "enum": ["pending", "in_progress", "completed"]}
    \\        },
    \\        "required": ["content", "status"]
    \\      }
    \\    }
    \\  },
    \\  "required": ["todos"]
    \\}
    ,
};

pub fn execute(alloc: std.mem.Allocator, args: std.json.Value) anyerror![]u8 {
    if (args != .object) return try std.fmt.allocPrint(alloc, "Error: args must be object", .{});
    const todos = args.object.get("todos") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'todos' is required", .{});
    if (todos != .array) return try std.fmt.allocPrint(alloc, "Error: 'todos' must be an array", .{});

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("Plan recorded:\n");
    for (todos.array.items, 1..) |item, idx| {
        if (item != .object) continue;
        const content = mod.getString(item, "content") orelse continue;
        const status = mod.getString(item, "status") orelse "pending";
        const marker: []const u8 = if (std.mem.eql(u8, status, "completed"))
            "[x]"
        else if (std.mem.eql(u8, status, "in_progress"))
            "[>]"
        else
            "[ ]";
        try w.print("  {d}. {s} {s}\n", .{ idx, marker, content });
    }

    return out.toOwnedSlice();
}
