const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const posix = std.posix;

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

    var write_buf: [64]u8 = undefined;
    var sw = stream.writer(io, &write_buf);
    sw.interface.writeAll("ACK!\n") catch return;
    sw.interface.flush() catch return;

    var key: [2]u8 = undefined;
    var passed_fd: ?posix.fd_t = null;
    recvKey(stream.socket.handle, &key, &passed_fd) catch |err| {
        if (passed_fd) |fd| closeFd(fd);
        std.log.err("recv key failed: {s}", .{@errorName(err)});
        return;
    };

    if (std.mem.eql(u8, &key, "01")) {
        if (passed_fd) |fd| {
            closeFd(fd);
            std.log.err("unexpected fd with message key 01", .{});
            return;
        }
        var read_buf: [1024]u8 = undefined;
        var sr = stream.reader(io, &read_buf);
        const line = sr.interface.takeDelimiterExclusive('\n') catch return;
        runWithLine(io, alloc, cmd_args, line);
    } else if (std.mem.eql(u8, &key, "02")) {
        const fd = passed_fd orelse {
            std.log.err("message key 02 missing file descriptor", .{});
            return;
        };
        defer closeFd(fd);
        runWithStdin(io, cmd_args, fd);
    } else {
        if (passed_fd) |fd| closeFd(fd);
        std.log.err("unknown message key: {s}", .{&key});
    }
}

fn runWithLine(
    io: Io,
    alloc: std.mem.Allocator,
    cmd_args: []const []const u8,
    line: []const u8,
) void {
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

fn runWithStdin(io: Io, cmd_args: []const []const u8, fd: posix.fd_t) void {
    var child = std.process.spawn(io, .{
        .argv = cmd_args,
        .stdin = .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } } },
    }) catch |err| {
        std.log.err("spawn failed: {s}", .{@errorName(err)});
        return;
    };
    _ = child.wait(io) catch {};
}

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

/// Reads exactly `key.len` bytes from `sock_fd` using `recvmsg(2)` so an
/// `SCM_RIGHTS` ancillary message carried by the same `sendmsg` call can be
/// captured. If exactly one fd was passed, it is stored in `out_fd`; any
/// other count (zero with no key-02, or more than one) is closed and
/// reported as an error.
fn recvKey(sock_fd: posix.fd_t, key: *[2]u8, out_fd: *?posix.fd_t) !void {
    var iov: posix.iovec = .{ .base = key[0..].ptr, .len = key.len };
    var ctl_buf: [64]u8 align(@alignOf(usize)) = undefined;
    var msg: posix.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = (&iov)[0..1],
        .iovlen = 1,
        .control = &ctl_buf,
        .controllen = ctl_buf.len,
        .flags = undefined,
    };

    const cloexec: u32 = if (@hasDecl(posix.MSG, "CMSG_CLOEXEC")) posix.MSG.CMSG_CLOEXEC else 0;

    var got: usize = 0;
    while (true) {
        const rc = posix.system.recvmsg(sock_fd, &msg, cloexec);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.RecvFailed,
        }
        const n: usize = @intCast(rc);
        if (n == 0) return error.EndOfStream;
        got = n;
        break;
    }

    try parseControlForFd(&msg, out_fd);

    while (got < key.len) {
        var iov2: posix.iovec = .{ .base = key[got..].ptr, .len = key.len - got };
        var msg2: posix.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = (&iov2)[0..1],
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = undefined,
        };
        const rc = posix.system.recvmsg(sock_fd, &msg2, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.RecvFailed,
        }
        const n: usize = @intCast(rc);
        if (n == 0) return error.EndOfStream;
        got += n;
    }
}

/// Walks every `cmsghdr` in `msg.control`, collecting fds from any
/// `SCM_RIGHTS` messages. Errors out (and closes every collected fd) if the
/// kernel truncated the control buffer, the cmsg layout is malformed, or
/// anything other than exactly one fd was sent.
fn parseControlForFd(msg: *const posix.msghdr, out_fd: *?posix.fd_t) !void {
    const ctl_len: usize = @intCast(msg.controllen);
    if (ctl_len == 0) return;
    const ctl_ptr = msg.control orelse return;

    if ((msg.flags & posix.MSG.CTRUNC) != 0) return error.ControlTruncated;

    const base: [*]const u8 = @ptrCast(ctl_ptr);
    const hdr_size = @sizeOf(posix.system.cmsghdr);
    const data_off = std.mem.alignForward(usize, hdr_size, @alignOf(usize));

    var fds: [4]posix.fd_t = undefined;
    var n_fds: usize = 0;
    var off: usize = 0;
    while (off + hdr_size <= ctl_len) {
        const cmsg: *const posix.system.cmsghdr = @ptrCast(@alignCast(base + off));
        const cmsg_len: usize = @intCast(cmsg.len);
        if (cmsg_len < data_off or off + cmsg_len > ctl_len) {
            closeCollected(&fds, n_fds);
            return error.MalformedCmsg;
        }

        if (cmsg.level == posix.SOL.SOCKET and cmsg.type == posix.SCM.RIGHTS) {
            const payload_len = cmsg_len - data_off;
            if (payload_len % @sizeOf(c_int) != 0) {
                closeCollected(&fds, n_fds);
                return error.MalformedCmsg;
            }
            const cmsg_n_fds = payload_len / @sizeOf(c_int);
            var i: usize = 0;
            while (i < cmsg_n_fds) : (i += 1) {
                var fd_val: c_int = undefined;
                @memcpy(
                    std.mem.asBytes(&fd_val),
                    (base + off + data_off + i * @sizeOf(c_int))[0..@sizeOf(c_int)],
                );
                const fd: posix.fd_t = @intCast(fd_val);
                if (n_fds < fds.len) {
                    fds[n_fds] = fd;
                } else {
                    closeFd(fd);
                }
                n_fds += 1;
            }
        }
        off = std.mem.alignForward(usize, off + cmsg_len, @alignOf(usize));
    }

    if (n_fds == 1) {
        out_fd.* = fds[0];
        return;
    }
    if (n_fds > 1) {
        closeCollected(&fds, @min(n_fds, fds.len));
        return error.TooManyFds;
    }
}

fn closeCollected(fds: *const [4]posix.fd_t, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) closeFd(fds[i]);
}
