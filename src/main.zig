const std = @import("std");
const Io = std.Io;
const net = std.net;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.log.err("Usage: sigexec <socket> <command...>", .{});
        return;
    }

    const addr = net.Address.initUnix(args[1]) catch unreachable;
    var server = try addr.listen(.{});
    defer server.deinit();

    std.log.warn("listening at {f}", .{server.listen_address});

    while (true) {
        const conn = try server.accept();
        _ = io.async(handle, .{ io, arena, conn, args[2..] });
    }
}

fn handle(
    io: Io,
    arena: std.mem.Allocator,
    conn: net.Server.Connection,
    cmd_args: []const []const u8,
) void {
    defer conn.stream.close();

    var read_buf: [1024]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    var sr = conn.stream.reader(io, &read_buf);
    var sw = conn.stream.writer(io, &write_buf);

    sw.interface.writeAll("ACK!\n") catch return;
    sw.interface.flush() catch return;

    const line = sr.interface.takeDelimiterExclusive('\n') catch return;

    var dynargs: std.ArrayList([]const u8) = .empty;
    defer dynargs.deinit(arena);
    dynargs.appendSlice(arena, cmd_args) catch return;
    const owned_line = arena.dupe(u8, line) catch return;
    dynargs.append(arena, owned_line) catch return;

    var proc = std.process.Child.init(dynargs.items, arena);
    _ = proc.spawn() catch |err| {
        std.log.err("spawn failed: {s}", .{@errorName(err)});
    };
}
