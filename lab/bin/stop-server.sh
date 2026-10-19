#!/usr/bin/env bash
# Stop the lab WordPress PHP server using its PID file (never pkill patterns,
# which can match the calling shell's own command line).
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PID_FILE="$LAB_DIR/php-server.pid"

if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE")"
  kill "$PID" 2>/dev/null || true
  # Reap any forked built-in-server workers that outlived the master.
  for CHILD in $(pgrep -P "$PID" 2>/dev/null || true); do
    kill "$CHILD" 2>/dev/null || true
  done
  rm -f "$PID_FILE"
  echo "stopped pid $PID"
else
  echo "no pid file"
fi
