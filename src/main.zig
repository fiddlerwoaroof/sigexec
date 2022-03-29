const std = @import("std");
const net = std.net;

// pub const io_mode = .evented;

pub fn main() anyerror!void {
    var allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.log.error("Usage: sigexec <socket> <command...>", .{});
        return;
    }

    var server = net.StreamServer.init(.{});
    defer server.deinit();

    try server.listen(net.Address.initUnix(args[1]) catch unreachable);
    std.log.warn("listening at {}\n", .{server.listen_address});

    while (true) {
        const client = try allocator.create(Client);
        client.* = Client{
            .conn = try server.accept(),
            .handle_frame = async client.handle(allocator, args[2..]),
        };
    }
}

fn nextLine(reader: anytype, buffer: []u8) !?[]const u8 {
    var line = (try reader.readUntilDelimiterOrEof(
        buffer,
        '\n',
    )) orelse return null;
    // trim annoying windows-only carriage return character
    return line;
}

const Client = struct {
    conn: net.StreamServer.Connection,
    handle_frame: @Frame(handle),
    fn handle(self: *Client, allocator: std.mem.Allocator, args: []const []u8) !void {
        var dynargs = std.ArrayList([]const u8).init(allocator);
        defer dynargs.deinit();

        try dynargs.appendSlice(args);

        try self.conn.stream.writer().writeAll("ACK!");

        var buffer: [1024]u8 = undefined;
        var nl = (try nextLine(self.conn.stream.reader(), &buffer)).?;
        try dynargs.append(nl);

        const proc = try std.ChildProcess.init(dynargs.toOwnedSlice(), allocator);
        _ = try nosuspend proc.spawn();
    }
};
