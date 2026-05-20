const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn jsonStringify(self: Role, jws: anytype) !void {
        try jws.write(@tagName(self));
    }
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,

    pub fn jsonStringify(self: ToolCall, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("type");
        try jws.write("function");
        try jws.objectField("function");
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("arguments");
        try jws.write(self.arguments);
        try jws.endObject();
        try jws.endObject();
    }
};

pub const Message = struct {
    role: Role,
    content: []const u8 = "",
    tool_calls: []const ToolCall = &.{},
    tool_call_id: ?[]const u8 = null,

    pub fn jsonStringify(self: Message, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("role");
        try jws.write(self.role);

        switch (self.role) {
            .tool => {
                try jws.objectField("tool_call_id");
                try jws.write(self.tool_call_id.?);
                try jws.objectField("content");
                try jws.write(self.content);
            },
            .assistant => {
                try jws.objectField("content");
                try jws.write(self.content);
                if (self.tool_calls.len > 0) {
                    try jws.objectField("tool_calls");
                    try jws.write(self.tool_calls);
                }
            },
            else => {
                try jws.objectField("content");
                try jws.write(self.content);
            },
        }
        try jws.endObject();
    }
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,

    pub fn jsonStringify(self: Tool, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("type");
        try jws.write("function");
        try jws.objectField("function");
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("description");
        try jws.write(self.description);
        try jws.objectField("parameters");
        try jws.print("{s}", .{self.parameters_json});
        try jws.endObject();
        try jws.endObject();
    }
};

pub const OwnedToolCall = struct {
    id: std.ArrayList(u8),
    name: std.ArrayList(u8),
    arguments: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator) OwnedToolCall {
        return .{
            .id = std.ArrayList(u8).init(alloc),
            .name = std.ArrayList(u8).init(alloc),
            .arguments = std.ArrayList(u8).init(alloc),
        };
    }

    pub fn deinit(self: *OwnedToolCall) void {
        self.id.deinit();
        self.name.deinit();
        self.arguments.deinit();
    }

    pub fn view(self: *const OwnedToolCall) ToolCall {
        return .{
            .id = self.id.items,
            .name = self.name.items,
            .arguments = self.arguments.items,
        };
    }
};
