#!/usr/bin/env bash
# Start the lab WordPress instance on PHP's built-in server.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${LAB_PORT:-8899}"
PID_FILE="$LAB_DIR/php-server.pid"
LOG_FILE="$LAB_DIR/php-server.log"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "already running (pid $(cat "$PID_FILE")) on port $PORT"
  exit 0
fi

# Multiple workers avoid the single-threaded server deadlocking on loopback
# requests that WordPress makes to itself (wp-cron, loopback health checks).
PHP_CLI_SERVER_WORKERS="${PHP_CLI_SERVER_WORKERS:-6}" \
  nohup "$LAB_DIR/bin/php" -d memory_limit=256M -d error_log="$LAB_DIR/php-error.log" \
  -S "127.0.0.1:$PORT" -t "$LAB_DIR/wordpress" > "$LOG_FILE" 2>&1 &

echo $! > "$PID_FILE"
sleep 1
curl -sS -m 10 -o /dev/null -w "wordpress http://127.0.0.1:$PORT -> %{http_code}\n" "http://127.0.0.1:$PORT/"
