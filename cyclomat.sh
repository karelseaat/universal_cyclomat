#!/usr/bin/env bash
# Wrapper: build the cyclomat binary if stale, then run it with all args forwarded.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

BINARY="$SCRIPT_DIR/cyclomat"
SRC="$SCRIPT_DIR/src/cyclomat.nim"

# Build when the binary is missing or the source is newer than the binary.
if [[ ! -x "$BINARY" || "$SRC" -nt "$BINARY" ]]; then
  make -C "$SCRIPT_DIR" build
fi

exec "$BINARY" "$@"
