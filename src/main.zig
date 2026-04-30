const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.log.err("Usage: sigexec <socket> <command...>", .{});
        return;
    }

    const addr = try net.UnixAddress.init(args[1]);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    std.log.warn("listening at {s}", .{args[1]});

    while (true) {
        const stream = try server.accept(io);
        _ = io.async(handle, .{ io, stream, args[2..] });
    }
}

fn handle(
    io: Io,
    stream: net.Stream,
    cmd_args: []const []const u8,
) void {
    defer stream.close(io);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var read_buf: [1024]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    sw.interface.writeAll("ACK!\n") catch return;
    sw.interface.flush() catch return;

    const line = sr.interface.takeDelimiterExclusive('\n') catch return;

    var dynargs: std.ArrayList([]const u8) = .empty;
    defer dynargs.deinit(alloc);
    dynargs.appendSlice(alloc, cmd_args) catch return;
    const owned_line = alloc.dupe(u8, line) catch return;
    dynargs.append(alloc, owned_line) catch return;

    var child = std.process.spawn(io, .{ .argv = dynargs.items }) catch |err| {
        std.log.err("spawn failed: {s}", .{@errorName(err)});
        return;
    };
    _ = child.wait(io) catch {};
}
