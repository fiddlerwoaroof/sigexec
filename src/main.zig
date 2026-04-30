const std = @import("std");
const Io = std.Io;
const Net = std.Net;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.log.err("Usage: sigexec <socket> <command...>", .{});
        return;
    }

    const addr = Net.Address.initUnix(args[1]) catch unreachable;
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    std.log.warn("listening at {s}", .{args[1]});

    while (true) {
        const conn = try server.accept(io);
        _ = io.async(handle, .{ io, conn, args[2..] });
    }
}

fn handle(
    io: Io,
    conn: Net.Server.Connection,
    cmd_args: []const []const u8,
) void {
    defer conn.stream.close(io);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var read_buf: [1024]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    var sr = conn.stream.reader(io, &read_buf);
    var sw = conn.stream.writer(io, &write_buf);

    sw.interface.writeAll("ACK!\n") catch return;
    sw.interface.flush() catch return;

    const line = sr.interface.takeDelimiterExclusive('\n') catch return;

    var dynargs: std.ArrayList([]const u8) = .empty;
    defer dynargs.deinit(alloc);
    dynargs.appendSlice(alloc, cmd_args) catch return;
    const owned_line = alloc.dupe(u8, line) catch return;
    dynargs.append(alloc, owned_line) catch return;

    var proc = std.process.Child.init(dynargs.items, alloc);
    _ = proc.spawn() catch |err| {
        std.log.err("spawn failed: {s}", .{@errorName(err)});
    };
}
