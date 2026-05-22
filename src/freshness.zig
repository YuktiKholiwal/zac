const std = @import("std");

/// Tracks the mtime of every file the agent has read. Before each turn we ask:
/// has any of them changed on disk since we last looked? If so, the model is
/// working from a stale snapshot and needs to be re-grounded.
pub const FreshnessTracker = struct {
    alloc: std.mem.Allocator,
    seen: std.StringHashMap(i128),
    /// Snapshot of file contents at the last `observe` call. Used by the
    /// diff-aware re-read path so we can return only what changed.
    last_content: std.StringHashMap([]u8),

    pub fn init(alloc: std.mem.Allocator) FreshnessTracker {
        return .{
            .alloc = alloc,
            .seen = std.StringHashMap(i128).init(alloc),
            .last_content = std.StringHashMap([]u8).init(alloc),
        };
    }

    pub fn deinit(self: *FreshnessTracker) void {
        var it = self.seen.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.seen.deinit();
        var cit = self.last_content.iterator();
        while (cit.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.last_content.deinit();
    }

    /// Returns the previously-recorded content for `path`, or null if this is
    /// the first read of that file this session.
    pub fn previousContent(self: *const FreshnessTracker, path: []const u8) ?[]const u8 {
        return self.last_content.get(path);
    }

    /// Records that this is now the file the agent has seen for `path`.
    /// Replaces any prior snapshot.
    pub fn recordContent(self: *FreshnessTracker, path: []const u8, content: []const u8) !void {
        const dup = try self.alloc.dupe(u8, content);
        const gop = try self.last_content.getOrPut(path);
        if (gop.found_existing) {
            self.alloc.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.alloc.dupe(u8, path);
        }
        gop.value_ptr.* = dup;
    }

    /// Record that the agent has just looked at this file. Stores its current
    /// mtime so we can detect future changes.
    pub fn observe(self: *FreshnessTracker, path: []const u8) !void {
        const mtime = readMtime(path) catch return;
        const gop = try self.seen.getOrPut(path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.alloc.dupe(u8, path);
        }
        gop.value_ptr.* = mtime;
    }

    /// Snapshot of every tracked path. Caller borrows; do not free.
    pub fn allPaths(self: *const FreshnessTracker, alloc: std.mem.Allocator) ![][]const u8 {
        var out = try alloc.alloc([]const u8, self.seen.count());
        var i: usize = 0;
        var it = self.seen.keyIterator();
        while (it.next()) |k| : (i += 1) {
            out[i] = k.*;
        }
        return out;
    }

    /// Returns the list of tracked paths whose mtime no longer matches what
    /// we recorded. Caller owns the returned slice (and the inner []u8s).
    /// Also updates our stored mtimes for the changed files.
    pub fn pollChanged(self: *FreshnessTracker, alloc: std.mem.Allocator) ![][]u8 {
        var changed = std.ArrayList([]u8).init(alloc);
        errdefer {
            for (changed.items) |p| alloc.free(p);
            changed.deinit();
        }

        var it = self.seen.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const current = readMtime(path) catch continue;
            if (current != entry.value_ptr.*) {
                try changed.append(try alloc.dupe(u8, path));
                entry.value_ptr.* = current;
            }
        }

        return changed.toOwnedSlice();
    }
};

fn readMtime(path: []const u8) !i128 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return stat.mtime;
}
