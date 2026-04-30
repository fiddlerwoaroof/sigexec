
# set -x
set -eu -o pipefail

sock_dir="$(mktemp -d)"
socket="${sock_dir}/it.sock"

nix run . -- "$socket" echo it: 2>/dev/null &
last="$!"

cleanup() {
  rm -rf "$sock_dir"
  kill "$last"
}
trap "cleanup" EXIT INT HUP

while ! [[ -S "$socket" ]]; do
  sleep 5
done

printf '01%s\n' first  | socat - unix-connect:"$socket"
printf '01%s\n' second | socat - unix-connect:"$socket"
printf '01%s\n' third  | socat - unix-connect:"$socket"

## Expected Output

# % ./test.zsh
# ACK!
# it: first
# ACK!
# it: second
# ACK!
# it: third
