const std = @import("std");
const messages = @import("../messages.zig");
const mod = @import("mod.zig");
const path_guard = @import("../path_guard.zig");

pub const def = messages.Tool{
    .name = "write",
    .description = "Save the given content to a file. Replaces any existing content at the path; creates missing parent directories. Refuses paths outside the working directory unless --allow-outside was set.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {"type": "string", "description": "Where to write the file"},
    \\    "content": {"type": "string", "description": "Full file contents"}
    \\  },
    \\  "required": ["path", "content"]
    \\}
    ,
};

pub fn execute(alloc: std.mem.Allocator, args: std.json.Value) anyerror![]u8 {
    const path = mod.getString(args, "path") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'path' is required", .{});
    const content = mod.getString(args, "content") orelse
        return try std.fmt.allocPrint(alloc, "Error: 'content' is required", .{});

    if (!mod.isAllowOutside()) {
        const inside = path_guard.isInsideCwd(alloc, path) catch true;
        if (!inside) {
            return try std.fmt.allocPrint(
                alloc,
                "Error: refusing to write outside the cwd: {s}\nRe-run with --allow-outside if intentional.",
                .{path},
            );
        }
    }

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            return try std.fmt.allocPrint(alloc, "Error creating directories for {s}: {s}", .{ path, @errorName(err) });
        };
    }

    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error opening {s} for write: {s}", .{ path, @errorName(err) });
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error writing {s}: {s}", .{ path, @errorName(err) });
    };

    return try std.fmt.allocPrint(alloc, "Wrote {d} bytes to {s}", .{ content.len, path });
}

fn runJson(alloc: std.mem.Allocator, json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    return execute(alloc, parsed.value);
}

test "write: creates a file with the given content" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_abs = try tmp.dir.realpath(".", &buf);
    const fpath = try std.fs.path.join(alloc, &.{ dir_abs, "out.txt" });
    defer alloc.free(fpath);

    const json = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\",\"content\":\"hello world\"}}", .{fpath});
    defer alloc.free(json);
    const res = try runJson(alloc, json);
    defer alloc.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "Wrote") != null);

    const written = try tmp.dir.readFileAlloc(alloc, "out.txt", 1024);
    defer alloc.free(written);
    try std.testing.expectEqualStrings("hello world", written);
}

test "write: refuses a path outside the cwd" {
    const alloc = std.testing.allocator;
    const res = try runJson(alloc, "{\"path\":\"/tmp/zac_should_refuse.txt\",\"content\":\"x\"}");
    defer alloc.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "refusing to write outside") != null);
}
