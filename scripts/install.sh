#!/bin/sh
# install.sh — install the sexc compiler + stdlib from a release bundle.
#
# Usage:
#   sudo ./install.sh                  # system-wide, PREFIX=/usr/local
#   PREFIX="$HOME/.local" ./install.sh # user-local, no sudo
#
# Layout produced (PREFIX defaults to /usr/local):
#   $PREFIX/bin/sexc
#   $PREFIX/include/sexc/std/*.sexc
#
# The binary locates its stdlib *relative to itself* ($PREFIX/../include/sexc/std),
# so this layout works for ANY prefix without setting an environment variable.

set -eu

PREFIX="${PREFIX:-/usr/local}"
here="$(cd "$(dirname "$0")" && pwd)"
bindir="$PREFIX/bin"
stddir="$PREFIX/include/sexc/std"

if [ ! -f "$here/sexc" ]; then
  echo "error: sexc binary not found next to this script ($here/sexc)" >&2
  exit 1
fi

mkdir -p "$bindir" "$stddir"
cp "$here/sexc" "$bindir/sexc"
chmod 755 "$bindir/sexc"
rm -f "$stddir"/*.sexc 2>/dev/null || true
cp "$here"/std/*.sexc "$stddir/"

cat <<EOF

Installed:
  binary  -> $bindir/sexc
  stdlib  -> $stddir

The binary finds its stdlib relative to itself ($bindir/../include/sexc/std),
so no environment variable is needed as long as you keep this layout.

Make sure '$bindir' is on your PATH, then try:
  sexc --help
EOF
