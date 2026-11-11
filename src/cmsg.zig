//! `SCM_RIGHTS` control-message layout (the `CMSG_*` macros), resolved at
//! comptime for the target.
//!
//! The macros are not portable. Linux (glibc and musl) aligns headers and
//! data to `size_t`. Darwin's <sys/socket.h> aligns to 4 bytes
//! (`__DARWIN_ALIGN32`) over a 12-byte `struct cmsghdr`, so the data starts
//! at offset 12, not 16. Using the Linux arithmetic on Darwin puts the fd at
//! the wrong offset and makes `cmsg_len` disagree with the control length,
//! which XNU rejects with EINVAL.

const std = @import("std");
const builtin = @import("builtin");

pub const Header = std.posix.system.cmsghdr;

/// Alignment of a header, its data, and the next header.
pub const alignment: usize = if (builtin.os.tag.isDarwin()) 4 else @alignOf(usize);

pub fn alignUp(n: usize) usize {
    return std.mem.alignForward(usize, n, alignment);
}

/// Offset of the data from the start of a header: `CMSG_DATA` / `CMSG_LEN(0)`.
pub const data_offset: usize = alignUp(@sizeOf(Header));

/// `CMSG_LEN(n)`: the value for `Header.len` with `n` bytes of data.
pub fn len(n: usize) usize {
    return data_offset + n;
}

/// `CMSG_SPACE(n)`: bytes a message with `n` bytes of data occupies.
pub fn space(n: usize) usize {
    return data_offset + alignUp(n);
}

comptime {
    if (builtin.os.tag.isDarwin()) {
        // xnu bsd/sys/socket.h: 12-byte header,
        // CMSG_LEN(sizeof(int)) == CMSG_SPACE(sizeof(int)) == 16.
        if (@sizeOf(Header) != 12) @compileError("unexpected Darwin cmsghdr size");
        if (data_offset != 12) @compileError("unexpected Darwin CMSG_DATA offset");
        if (space(@sizeOf(c_int)) != 16) @compileError("unexpected Darwin CMSG_SPACE");
    }
}
