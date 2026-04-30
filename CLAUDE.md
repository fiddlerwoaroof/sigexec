# sigexec — quick reference for Claude Code

A small Unix-socket-driven command runner. Each connection sends one line; the
server writes `ACK!`, reads the line, and spawns the configured command with
the line appended as the last argument.

## Build & test

```sh
nix build                  # builds result/bin/sigexec
nix run .#do-test          # runs test.zsh end-to-end (expects: ACK! / it: first / ACK! / it: second / ACK! / it: third)
```

`zig build` works inside `nix develop -c …` (the dev shell pins Zig 0.16):

```sh
nix develop -c zig build                              # native, debug
nix develop -c zig build -Dtarget=x86_64-linux-gnu    # cross-compile
nix develop -c zig build test                         # test step (no unit tests yet)
```

## Manual smoke test

```sh
./result/bin/sigexec /tmp/sigexec.sock /usr/bin/echo "it:" &
echo first  | socat - unix-connect:/tmp/sigexec.sock   # → "ACK!" over the socket; server prints "it: first"
echo second | socat - unix-connect:/tmp/sigexec.sock
echo third  | socat - unix-connect:/tmp/sigexec.sock
```

## Cross-compile matrix

`.github/workflows/ci.yml` builds for these targets after the native `nix build`:

```
aarch64-linux-gnu   aarch64-linux-musl   aarch64-macos-none
x86-linux-gnu       x86_64-linux-gnu     x86_64-linux-musl   x86_64-macos-none
```

Note: Zig 0.16 calls 32-bit x86 `x86`, **not** `i386` — the workflow uses
`-Dtarget=x86-linux-gnu`.

## Key Zig 0.16 stdlib paths used here

The 0.16 stdlib reorganized many things. Things that bit during the port:

| What                                | 0.16                                                                                       |
|-------------------------------------|--------------------------------------------------------------------------------------------|
| Main entry point                    | `pub fn main(init: std.process.Init) !void`                                                |
| Get the Io / arena                  | `init.io`, `init.arena.allocator()`                                                        |
| Get argv                            | `init.minimal.args.toSlice(arena)`                                                         |
| Networking namespace                | `std.Io.net` (lowercase n) — `std.net` is **gone**                                         |
| Unix socket address                 | `std.Io.net.UnixAddress.init(path)` — returns `InitError!UnixAddress` (use `try`)          |
| Listen                              | `addr.listen(io, .{})` → `Server`                                                          |
| Accept                              | `server.accept(io)` → `Stream` directly (no `Connection` wrapper)                          |
| Stream methods                      | `stream.{close,reader,writer}(io, …)` — all take `io`                                      |
| Reader/Writer wrappers              | wrapper struct with an `.interface` field (e.g. `sw.interface.writeAll(…)`, `flush()`)     |
| Read a line                         | `reader.takeDelimiterExclusive('\n')` (replaces `readUntilDelimiterOrEof`)                 |
| Concurrent task                     | `io.async(handle, .{ args… })` (replaces `async`/`await`/`@Frame`)                         |
| Spawn child process                 | `std.process.spawn(io, .{ .argv = … })` → `Child`; then `child.wait(io)`                   |
| `std.process.Child`                 | now just a *handle* to a running process; construction options are `std.process.SpawnOptions` |
| ArrayList                           | unmanaged: `var x: std.ArrayList(T) = .empty;` then `x.append(allocator, item)` etc.       |
| `build.zig.zon` `.name`             | enum literal (`.sigexec`), **not** a string                                                |
| `flake.nix` optimize flag           | `--release=safe` (replaces `-Drelease-safe`)                                               |

## Web session bootstrap

`.claude/hooks/session-start.sh` installs `nix-bin`, `socat`, `zsh`, configures
`/etc/nix/nix.conf` (flakes + `sandbox = false`, since the harness lacks
unprivileged user namespaces), and warms `nix build` so the first explicit
build is fast. Triggered from `.claude/settings.json`.
