//! Read-only plain text capture. The caller holds the terminal state lock.
const std = @import("std");
const Terminal = @import("Terminal.zig");
const TerminalFormatter = @import("formatter.zig").TerminalFormatter;

pub const Result = struct {
    text: [:0]u8,
    truncated: bool,
};

/// Select at most max_rows physical rows before formatting. A fixed writer
/// bounds UTF-8 output even for cells containing very long grapheme clusters.
/// Output plus scratch use at most 2 * (max_bytes + 1) bytes. Oversize captures
/// fail rather than returning invalid UTF-8 or a silently partial final line.
pub fn capture(allocator: std.mem.Allocator, t: *Terminal, active_only: bool, max_rows: usize, max_bytes: usize) !Result {
    if (max_rows == 0 or max_rows > 10000 or max_bytes == 0 or max_bytes > 2 * 1024 * 1024)
        return error.InvalidLimit;
    const pages = &t.screens.active.pages;
    const tag: @import("point.zig").Tag = if (active_only) .active else .screen;
    const end = pages.getBottomRight(tag) orelse return error.NoScreen;
    const top = pages.getTopLeft(tag);
    var start = switch (end.upOverflow(max_rows - 1)) {
        .offset => |pin| pin,
        .overflow => |overflow| overflow.end,
    };
    start.x = 0;
    if (start.before(top)) start = top;
    const truncated = top.node != start.node or top.y != start.y;
    // ACTIVE must be a complete replacement, never a silently clipped screen.
    if (active_only and truncated) return error.LimitExceeded;
    var formatter: TerminalFormatter = .init(t, .{ .emit = .plain, .unwrap = true, .trim = false });
    formatter.extra = .none;
    formatter.content = .{ .selection = .init(start, end, false) };
    const scratch = try allocator.alloc(u8, max_bytes);
    defer allocator.free(scratch);
    var writer = std.Io.Writer.fixed(scratch);
    formatter.format(&writer) catch return error.LimitExceeded;
    return .{ .text = try allocator.dupeZ(u8, writer.buffered()), .truncated = truncated };
}

test "bounded text keeps recent rows without changing viewport" {
    const a = std.testing.allocator;
    var t = try Terminal.init(a, .{ .cols = 40, .rows = 2 });
    defer t.deinit(a);
    var stream = t.vtStream();
    defer stream.deinit();
    try stream.nextSlice("OLD\r\nSECOND\r\nLATEST");
    const before = t.screens.active.pages.getTopLeft(.viewport);
    const result = try capture(a, &t, false, 2, 4096);
    defer a.free(result.text);
    try std.testing.expect(result.truncated);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "OLD") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "LATEST") != null);
    const after = t.screens.active.pages.getTopLeft(.viewport);
    try std.testing.expectEqual(before.node, after.node);
    try std.testing.expectEqual(before.y, after.y);
}

test "bounded text enforces limits and handles allocation failures" {
    const a = std.testing.allocator;
    var t = try Terminal.init(a, .{ .cols = 40, .rows = 2 });
    defer t.deinit(a);
    var stream = t.vtStream();
    defer stream.deinit();
    try stream.nextSlice("你好 e\xcc\x81");
    try std.testing.expectError(error.LimitExceeded, capture(a, &t, true, 1, 4096));
    try std.testing.expectError(error.LimitExceeded, capture(a, &t, true, 2, 1));
    try std.testing.expectError(error.InvalidLimit, capture(a, &t, false, 0, 4096));
    const result = try capture(a, &t, true, 2, 4096);
    defer a.free(result.text);
    try std.testing.expect(!result.truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.text));
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(alloc: std.mem.Allocator, terminal: *Terminal) !void {
            const value = try capture(alloc, terminal, false, 2, 4096);
            defer alloc.free(value.text);
        }
    }.run, .{&t});
}
