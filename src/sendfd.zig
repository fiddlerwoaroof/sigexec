const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const posix = std.posix;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.log.err("Usage: sigexec-sendfd <socket> <file>", .{});
        return error.InvalidUsage;
    }
    const sock_path = args[1];
    const file_path = args[2];

    var file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    const addr = try net.UnixAddress.init(sock_path);
    var stream = try addr.connect(io);
    defer stream.close(io);

    var read_buf: [16]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    _ = sr.interface.takeDelimiterExclusive('\n') catch |err| {
        std.log.err("server did not ACK: {s}", .{@errorName(err)});
        return err;
    };

    try sendKeyWithFd(stream.socket.handle, file.handle);
}

fn sendKeyWithFd(sock_fd: posix.fd_t, fd: posix.fd_t) !void {
    var key: [2]u8 = "02".*;
    var iov: posix.iovec_const = .{ .base = &key, .len = key.len };

    const data_off = std.mem.alignForward(usize, @sizeOf(posix.system.cmsghdr), @alignOf(usize));
    const cmsg_len = data_off + @sizeOf(c_int);
    const cmsg_space = std.mem.alignForward(usize, cmsg_len, @alignOf(usize));

    var ctl: [64]u8 align(@alignOf(usize)) = @splat(0);
    const cmsg: *posix.system.cmsghdr = @ptrCast(@alignCast(&ctl));
    cmsg.* = .{
        .len = @intCast(cmsg_len),
        .level = posix.SOL.SOCKET,
        .type = posix.SCM.RIGHTS,
    };
    var fd_val: c_int = @intCast(fd);
    @memcpy(ctl[data_off..][0..@sizeOf(c_int)], std.mem.asBytes(&fd_val));

    var msg: posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = (&iov)[0..1],
        .iovlen = 1,
        .control = &ctl,
        .controllen = @intCast(cmsg_space),
        .flags = 0,
    };

    const flags: u32 = if (@hasDecl(posix.MSG, "NOSIGNAL")) posix.MSG.NOSIGNAL else 0;
    while (true) {
        const rc = posix.system.sendmsg(sock_fd, &msg, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |e| {
                std.log.err("sendmsg failed: {s}", .{@tagName(e)});
                return error.SendFailed;
            },
        }
    }
}
