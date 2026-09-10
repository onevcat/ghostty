//! Display-only VT export, adapted from onevcat/Prowl PR #788.
//! The caller must hold the terminal state lock throughout this operation.
const std = @import("std");
const Terminal = @import("Terminal.zig");
const TerminalFormatter = @import("formatter.zig").TerminalFormatter;

/// The owned, sentinel-terminated buffer excludes scrollback and inactive screen
/// contents. It is not a full checkpoint: formatter omissions remain omissions.
pub fn alloc(allocator: std.mem.Allocator, t: *Terminal) ![:0]u8 {
    var formatter: TerminalFormatter = .init(t, .{
        .emit = .vt,
        .unwrap = false,
        .trim = false,
        .background = t.colors.background.get(),
        .foreground = t.colors.foreground.get(),
        .palette = &t.colors.palette.current,
    });
    formatter.content = .{ .selection = .init(
        t.screens.active.pages.getTopLeft(.active),
        t.screens.active.pages.getBottomRight(.active).?,
        false,
    ) };
    // Full extras restore tabstops after the cursor, moving the replay cursor.
    // Keep the spike's display-specific subset rather than a full checkpoint.
    formatter.extra = .styles;
    formatter.extra.modes = true;
    formatter.extra.screen.cursor = true;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    // An allocating writer can fail only when it cannot grow its buffer.
    formatter.format(&writer.writer) catch return error.OutOfMemory;
    return try writer.toOwnedSliceSentinel(0);
}

test "display snapshot styled round trip preserves cursor" {
    const testing = std.testing;
    var host = try Terminal.init(testing.allocator, .{ .cols = 81, .rows = 25 });
    defer host.deinit(testing.allocator);
    var source = host.vtStream();
    defer source.deinit();
    try source.nextSlice("\x1b[38;2;12;34;56m\x1b[4m你好 e\xcc\x81 🌍\x1b[0m\x1b[9;5H");

    const frame = try alloc(testing.allocator, &host);
    defer testing.allocator.free(frame);
    try testing.expectEqual(@as(u8, 0), frame[frame.len]);
    try testing.expect(std.mem.indexOf(u8, frame, "你好") != null);

    var client = try Terminal.init(testing.allocator, .{ .cols = 81, .rows = 25 });
    defer client.deinit(testing.allocator);
    var receiver = client.vtStream();
    defer receiver.deinit();
    try receiver.nextSlice(frame);
    try testing.expectEqual(host.screens.active.cursor.x, client.screens.active.cursor.x);
    try testing.expectEqual(host.screens.active.cursor.y, client.screens.active.cursor.y);
    const replay = try alloc(testing.allocator, &client);
    defer testing.allocator.free(replay);
    try testing.expectEqualStrings(frame, replay);
}

test "display snapshot replaces cleared content and switches screens" {
    const testing = std.testing;
    var host = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 4 });
    defer host.deinit(testing.allocator);
    var source = host.vtStream();
    defer source.deinit();
    var client = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 4 });
    defer client.deinit(testing.allocator);
    var receiver = client.vtStream();
    defer receiver.deinit();

    const updates = [_][]const u8{
        "OLD-PROCESS\r\nsecond line",
        "\x1b[2J\x1b[Hresult",
        "\x1b[?1049hALTERNATE",
        "\x1b[?1049l",
        "\x1b[2J\x1b[H",
    };
    for (updates, 0..) |update, i| {
        try source.nextSlice(update);
        const frame = try alloc(testing.allocator, &host);
        defer testing.allocator.free(frame);
        if (i > 0) try testing.expect(std.mem.indexOf(u8, frame, "OLD-PROCESS") == null);
        // Each frame replaces the display; it is not an append-only log.
        try receiver.nextSlice("\x1b[?1049l\x1b[0m\x1b[2J\x1b[H");
        try receiver.nextSlice(frame);
        const replay = try alloc(testing.allocator, &client);
        defer testing.allocator.free(replay);
        try testing.expectEqualStrings(frame, replay);
    }
}

test "display snapshot excludes scrollback and handles allocation failure" {
    const testing = std.testing;
    var host = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 2 });
    defer host.deinit(testing.allocator);
    var source = host.vtStream();
    defer source.deinit();
    try source.nextSlice("HISTORY-ONLY\r\nline two\r\nCURRENT");
    const frame = try alloc(testing.allocator, &host);
    defer testing.allocator.free(frame);
    try testing.expect(std.mem.indexOf(u8, frame, "HISTORY-ONLY") == null);
    try testing.expect(std.mem.indexOf(u8, frame, "CURRENT") != null);
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, t: *Terminal) !void {
            const bytes = try alloc(allocator, t);
            defer allocator.free(bytes);
        }
    }.run, .{&host});
}
