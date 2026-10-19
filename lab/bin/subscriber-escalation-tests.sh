#!/usr/bin/env bash
# Attempt to escalate a Subscriber to Administrator through core WordPress
# interfaces, and fail closed if any check unexpectedly succeeds.
#
# Scope: this is a negative-test harness for the local lab. It does not use
# third-party plugin vulnerabilities and does not brute force credentials.
set -uo pipefail

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

CREDENTIALS_FILE="$LAB_DIR/.lowpriv-credentials"
[ -f "$CREDENTIALS_FILE" ] || fail "missing $CREDENTIALS_FILE (see README-privesc.md)"

LOW_USER="$(sed -n 's/^LOWPRIV_USER=//p' "$CREDENTIALS_FILE" | head -1)"
LOW_PASS="$(sed -n 's/^LOWPRIV_PASS=//p' "$CREDENTIALS_FILE" | head -1)"
LOW_ID="$(cd "$LAB_DIR/wordpress" && "$LAB_DIR/bin/php" "$LAB_DIR/bin/wp-cli.phar" user get "$LOW_USER" --field=ID --path="$LAB_DIR/wordpress")"

COOKIE_JAR="$LAB_DIR/.lowpriv-cookies.txt"
ADMIN_USER="$LOW_USER"
ADMIN_PASS="$LOW_PASS"

PASS=0
FAIL=0
BLOCKED_RE='not allowed|cheatin|cannot|forbidden'

ok()   { PASS=$((PASS + 1)); printf '  [BLOCKED] %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  [UNEXPECTED] %s\n' "$*"; }
info() { printf '  [info]    %s\n' "$*"; }

echo "== Subscriber privilege-escalation tests =="
echo "target: $BASE_URL"
echo

wp_login "$TMP_DIR/dashboard.html"
echo

echo "-- 1. Administrative screens --"
declare -A PAGES=(
  [plugin-install.php]="install plugins"
  [plugins.php]="access plugins"
  [users.php]="list users"
  [user-new.php]="create users"
  [theme-editor.php]="edit themes"
  [options-general.php]="manage options"
  [update-core.php]="update core"
  [customize.php]="customize site"
  [async-upload.php]="upload files"
)
for page in "${!PAGES[@]}"; do
  body="$TMP_DIR/page.html"
  code="$(curl -sS --max-time 20 -b "$COOKIE_JAR" -o "$body" -w '%{http_code}' "$BASE_URL/wp-admin/$page")"
  if { [ "$code" = "403" ] || [ "$code" = "500" ]; } && grep -qiE "$BLOCKED_RE" "$body"; then
    ok "$page -> HTTP $code ($(grep -oiE 'not allowed[^<]*' "$body" | head -1))"
  else
    bad "$page returned HTTP $code without a capability denial"
  fi
done
echo

echo "-- 2. Role injection through profile.php --"
curl -sS --max-time 20 -b "$COOKIE_JAR" -o "$TMP_DIR/profile.html" "$BASE_URL/wp-admin/profile.php"
PROFILE_NONCE="$(nonce "$TMP_DIR/profile.html" _wpnonce)"
curl -sS --max-time 30 -b "$COOKIE_JAR" -c "$COOKIE_JAR" -o "$TMP_DIR/profile-post.html" \
  --data-urlencode 'from=profile' \
  --data-urlencode 'action=update' \
  --data-urlencode "user_id=$LOW_ID" \
  --data-urlencode "checkuser_id=$LOW_ID" \
  --data-urlencode "_wpnonce=$PROFILE_NONCE" \
  --data-urlencode '_wp_http_referer=/wp-admin/profile.php' \
  --data-urlencode 'admin_color=fresh' \
  --data-urlencode 'admin_bar_front=1' \
  --data-urlencode "nickname=$LOW_USER" \
  --data-urlencode "display_name=$LOW_USER" \
  --data-urlencode 'role=administrator' \
  --data-urlencode 'wp_capabilities[administrator]=1' \
  "$BASE_URL/wp-admin/profile.php"

ROLE="$("$LAB_DIR/bin/php" "$LAB_DIR/bin/wp-cli.phar" user get "$LOW_USER" --field=roles --path="$LAB_DIR/wordpress")"
if [ "$ROLE" = "subscriber" ]; then
  ok "role=administrator and wp_capabilities[] were ignored (role stays $ROLE)"
else
  bad "profile update changed the role to '$ROLE'"
fi
echo

echo "-- 3. REST API --"
REST_NONCE="$(grep -oE 'wp.apiFetch.createNonceMiddleware\( "[a-z0-9]+" \)' "$TMP_DIR/profile.html" | grep -oE '[a-z0-9]{8,}' | tail -1)"
info "REST nonce obtained: ${REST_NONCE:-<none>}"

rest_call() {
  local method="$1" route="$2" data="${3-}" out="$TMP_DIR/rest.json" code field
  [ -n "$data" ] || data='{}'
  if [ "$method" = "GET" ]; then
    code="$(curl -sS --max-time 20 -b "$COOKIE_JAR" -H "X-WP-Nonce: $REST_NONCE" -o "$out" -w '%{http_code}' "$BASE_URL/?rest_route=/$route")"
  else
    code="$(curl -sS --max-time 20 -X "$method" -b "$COOKIE_JAR" -H "X-WP-Nonce: $REST_NONCE" \
      -H 'Content-Type: application/json' --data "$data" -o "$out" -w '%{http_code}' "$BASE_URL/?rest_route=/$route")"
  fi
  field="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("code",""))' "$out" 2>/dev/null || true)"
  printf '%s %s -> HTTP %s %s\n' "$method" "$route" "$code" "${field:+($field)}"
  [ "$code" = "403" ] || [ "$code" = "401" ]
}

while IFS='|' read -r line data; do
  method="${line%% *}"
  route="${line#* }"
  data="${data:-{\}}"
  if rest_call "$method" "$route" "$data"; then
    ok "REST $method $route denied"
  else
    bad "REST $method $route unexpectedly allowed"
  fi
done <<EOF
POST wp/v2/users/$LOW_ID|{"roles":["administrator"]}
POST wp/v2/users/me|{"roles":["administrator"]}
POST wp/v2/users|{"username":"sub_created","email":"sub_created@example.com","password":"Str0ng-Pass-Example-1","roles":["administrator"]}
GET wp/v2/settings|
POST wp/v2/settings|{}
GET wp/v2/plugins|
GET wp/v2/themes|
POST wp/v2/posts|{}
POST wp/v2/media|{}
EOF
echo

echo "-- 4. XML-RPC --"
XML="$(mktemp)"
xmlrpc() {
  local body="$1"
  curl -sS --max-time 20 -X POST -H 'Content-Type: text/xml' --data "$body" \
    -o "$XML" -w '%{http_code}' "$BASE_URL/xmlrpc.php" >/dev/null
  cat "$XML"
}

BODY_USERS="<?xml version=\"1.0\"?><methodCall><methodName>wp.getUsers</methodName><params><param><value><int>1</int></value></param><param><value><string>$LOW_USER</string></value></param><param><value><string>$LOW_PASS</string></value></param><param><value><struct></struct></value></param></params></methodCall>"
OUT="$(xmlrpc "$BODY_USERS")"
if grep -q '<fault>' "$XML" && grep -q 'not allowed to list users' "$XML"; then
  ok "wp.getUsers denied"
else
  bad "wp.getUsers did not return the expected capability fault"
fi
: "$OUT"

BODY_UPLOAD="<?xml version=\"1.0\"?><methodCall><methodName>wp.uploadFile</methodName><params><param><value><int>1</int></value></param><param><value><string>$LOW_USER</string></value></param><param><value><string>$LOW_PASS</string></value></param><param><value><struct><member><name>name</name><value><string>probe.txt</string></value></member><member><name>type</name><value><string>text/plain</string></value></member><member><name>bits</name><value><base64>aGVsbG8=</base64></value></member></struct></value></param></params></methodCall>"
OUT="$(xmlrpc "$BODY_UPLOAD")"
if grep -q '<fault>' "$XML" && grep -q 'not allowed to upload' "$XML"; then
  ok "wp.uploadFile denied"
else
  bad "wp.uploadFile did not return the expected capability fault"
fi
: "$OUT"
echo

echo "-- 5. Stored XSS through profile fields --"
curl -sS --max-time 20 -b "$COOKIE_JAR" -o "$TMP_DIR/profile2.html" "$BASE_URL/wp-admin/profile.php"
PROFILE_NONCE2="$(nonce "$TMP_DIR/profile2.html" _wpnonce)"
curl -sS --max-time 30 -b "$COOKIE_JAR" -c "$COOKIE_JAR" -o /dev/null \
  --data-urlencode 'from=profile' \
  --data-urlencode 'action=update' \
  --data-urlencode "user_id=$LOW_ID" \
  --data-urlencode "checkuser_id=$LOW_ID" \
  --data-urlencode "_wpnonce=$PROFILE_NONCE2" \
  --data-urlencode 'admin_color=fresh' \
  --data-urlencode 'admin_bar_front=1' \
  --data-urlencode "nickname=$LOW_USER" \
  --data-urlencode "display_name=<script>alert(1)</script>" \
  --data-urlencode "description=<img src=x onerror=alert(2)>" \
  "$BASE_URL/wp-admin/profile.php"

STORED_NAME="$("$LAB_DIR/bin/php" "$LAB_DIR/bin/wp-cli.phar" user get "$LOW_USER" --field=display_name --path="$LAB_DIR/wordpress")"
STORED_DESC="$("$LAB_DIR/bin/php" "$LAB_DIR/bin/wp-cli.phar" user meta get "$LOW_ID" description --path="$LAB_DIR/wordpress" 2>/dev/null || true)"
if ! grep -qiE '<script|<img' <<<"$STORED_NAME$STORED_DESC"; then
  ok "KSES stripped HTML from display_name/description (stored: '${STORED_NAME}' / '${STORED_DESC}')"
else
  bad "HTML survived in profile fields: $STORED_NAME / $STORED_DESC"
fi

echo
echo "== Result: $PASS blocked, $FAIL unexpected =="
[ "$FAIL" -eq 0 ]

