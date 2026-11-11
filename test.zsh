# set -x
set -eu -o pipefail

sock_dir="$(mktemp -d)"
socket="${sock_dir}/it.sock"
fd_socket="${sock_dir}/fd.sock"
fd_out="${sock_dir}/fd.out"
: > "$fd_out"

sigexec "$socket" echo it: 2>/dev/null &
last="$!"

# Key 02 server: each passed fd becomes the child's stdin.
sigexec "$fd_socket" tee -a "$fd_out" >/dev/null 2>&1 &
fd_server="$!"

cleanup() {
  kill "$last" "$fd_server" 2>/dev/null || true
  rm -rf "$sock_dir"
}
trap "cleanup" EXIT INT HUP

while ! [[ -S "$socket" && -S "$fd_socket" ]]; do
  sleep 0.1
done

printf '01%s\n' first  | socat - unix-connect:"$socket"
printf '01%s\n' second | socat - unix-connect:"$socket"
printf '01%s\n' third  | socat - unix-connect:"$socket"

# Wait (up to ~5s) for an exact line from the key 02 server; fail otherwise.
expect_fd_line() {
  local i
  for i in {1..50}; do
    if grep -qxF -- "$1" "$fd_out"; then
      print -- "$1"
      return 0
    fi
    sleep 0.1
  done
  print -u2 -- "FAIL: key 02 server never printed: $1"
  exit 1
}

# Key 02 via sigexec-sendfd (exercises our sender and receiver).
print 'fd: sendfd' > "${sock_dir}/sendfd.in"
sigexec-sendfd "$fd_socket" "${sock_dir}/sendfd.in"
expect_fd_line 'fd: sendfd'

# Key 02 via Python, whose sendmsg uses the platform's own CMSG_* macros
# (an independent check of our receiver's layout).
print 'fd: python' > "${sock_dir}/python.in"
python3 -I -c '
import array, os, socket, sys
fd = os.open(sys.argv[2], os.O_RDONLY)
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.recv(64)
s.sendmsg([b"02"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]).tobytes())])
' "$fd_socket" "${sock_dir}/python.in"
expect_fd_line 'fd: python'

## Expected Output

# % ./test.zsh
# ACK!
# it: first
# ACK!
# it: second
# ACK!
# it: third
# fd: sendfd
# fd: python
