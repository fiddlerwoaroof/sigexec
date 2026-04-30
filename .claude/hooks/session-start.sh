#!/usr/bin/env bash
# Claude Code on the web session-start hook for fiddlerwoaroof/sigexec.
#
# Installs the toolchain needed to build and test this project:
#   - nix (with flakes + nix-command experimental features)
#   - socat, zsh (used by test.zsh and the manual smoke test)
#
# Then warms `nix build` so the first interactive build is fast.
#
# Idempotent: safe to re-run. Only runs in the remote (web) environment.

set -euo pipefail

# Only run in the remote environment.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

# Install nix, socat, zsh.
if ! command -v nix >/dev/null 2>&1 || ! command -v socat >/dev/null 2>&1 || ! command -v zsh >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  # Tolerate failures fetching third-party PPAs the harness image carries —
  # the base Ubuntu repos still have the packages we need.
  $SUDO apt-get update -qq || true
  $SUDO apt-get install -y -qq nix-bin socat zsh
fi

# Enable flakes + nix-command, disable sandbox (no privileged user namespace
# in the harness container). Idempotent overwrite.
$SUDO mkdir -p /etc/nix
$SUDO tee /etc/nix/nix.conf >/dev/null <<'EOF'
experimental-features = nix-command flakes
sandbox = false
EOF

# Warm nix build (downloads nixpkgs + zig-0.16.0 + deps; produces ./result).
# Skip if the result symlink is already valid.
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"
if [ ! -L result ] || [ ! -x result/bin/sigexec ]; then
  nix build --no-link --print-out-paths .#default >/dev/null
  nix build .#default >/dev/null
fi
