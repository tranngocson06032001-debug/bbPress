#!/usr/bin/env bash
# Docker-free fallback: install WordPress with a static PHP binary and the
# official SQLite Database Integration drop-in. This is how the sandbox lab was
# built when no Docker daemon/root was available.
#
# All state stays inside this directory; nothing is installed system-wide.
set -euo pipefail

LAB_DIR="${LAB_DIR:-/workspace/lab}"
PORT="${LAB_PORT:-8899}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
PHP_VERSION="${PHP_VERSION:-8.4.23}"
SITE_TITLE="${SITE_TITLE:-WP Admin RCE Lab}"
CREDENTIALS_FILE="$LAB_DIR/.admin-credentials"

genpass() {
  python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(28)))'
}

if [ -f "$CREDENTIALS_FILE" ]; then
  ADMIN_USER="$(sed -n 's/^ADMIN_USER=//p' "$CREDENTIALS_FILE" | head -1)"
  ADMIN_PASS="$(sed -n 's/^ADMIN_PASS=//p' "$CREDENTIALS_FILE" | head -1)"
fi
ADMIN_PASS="${ADMIN_PASS:-}"

DL="$LAB_DIR/downloads"
mkdir -p "$DL" "$LAB_DIR/bin"

if [ ! -x "$LAB_DIR/bin/php" ]; then
  echo "[*] downloading static PHP $PHP_VERSION"
  curl -fsSL --retry 3 -o "$DL/php.tar.gz" \
    "https://dl.static-php.dev/static-php-cli/common/php-${PHP_VERSION}-cli-linux-x86_64.tar.gz"
  tar xzf "$DL/php.tar.gz" -C "$LAB_DIR/bin"
fi

if [ ! -f "$LAB_DIR/bin/wp-cli.phar" ]; then
  echo "[*] downloading WP-CLI"
  curl -fsSL --retry 3 -o "$LAB_DIR/bin/wp-cli.phar" \
    "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
fi

if [ ! -d "$LAB_DIR/wordpress/wp-includes" ]; then
  echo "[*] downloading WordPress"
  curl -fsSL --retry 3 -o "$DL/latest.zip" "https://wordpress.org/latest.zip"
  unzip -q "$DL/latest.zip" -d "$LAB_DIR"
fi

if [ ! -d "$LAB_DIR/wordpress/wp-content/plugins/sqlite-database-integration" ]; then
  echo "[*] downloading SQLite Database Integration"
  curl -fsSL --retry 3 -o "$DL/sqlite-database-integration.zip" \
    "https://downloads.wordpress.org/plugin/sqlite-database-integration.zip"
  unzip -q "$DL/sqlite-database-integration.zip" -d "$LAB_DIR/wordpress/wp-content/plugins"
fi

if [ ! -f "$LAB_DIR/wordpress/wp-content/db.php" ]; then
  cp "$LAB_DIR/wordpress/wp-content/plugins/sqlite-database-integration/db.copy" \
     "$LAB_DIR/wordpress/wp-content/db.php"
fi

if [ ! -f "$LAB_DIR/wordpress/wp-config.php" ]; then
  echo "[*] writing wp-config.php"
  python3 - "$LAB_DIR/wordpress/wp-config.php" "$PORT" "$LAB_DIR" <<'PY'
import secrets, string, sys

path, port, lab_dir = sys.argv[1], sys.argv[2], sys.argv[3]
chars = string.ascii_letters + string.digits + "!@#$%^&*()-_[]{}<>~`+=,.;:/?|"
salts = "\n".join(
    "define( '%s', '%s' );" % (name, "".join(secrets.choice(chars) for _ in range(64)))
    for name in ("AUTH_KEY", "SECURE_AUTH_KEY", "LOGGED_IN_KEY", "NONCE_KEY",
                 "AUTH_SALT", "SECURE_AUTH_SALT", "LOGGED_IN_SALT", "NONCE_SALT")
)
config = """<?php
/** Local lab WordPress configuration (SQLite drop-in, throwaway instance). */
define( 'DB_NAME', 'wordpress' );
define( 'DB_USER', 'wordpress' );
define( 'DB_PASSWORD', 'wordpress' );
define( 'DB_HOST', 'localhost' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

%s

$table_prefix = 'wp_';

define( 'WP_HOME', 'http://127.0.0.1:%s' );
define( 'WP_SITEURL', 'http://127.0.0.1:%s' );
define( 'WP_DEBUG', true );
define( 'WP_DEBUG_LOG', '%s/wp-debug.log' );
define( 'WP_DEBUG_DISPLAY', false );
define( 'FS_METHOD', 'direct' );

define( 'DISALLOW_FILE_EDIT', false ); // lab: Theme/Plugin editor enabled
define( 'DISALLOW_FILE_MODS', false ); // lab: plugin/theme installs enabled
define( 'AUTOMATIC_UPDATER_DISABLED', true );
define( 'WP_AUTO_UPDATE_CORE', false );

if ( ! defined( 'ABSPATH' ) ) {
\tdefine( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
""" % (salts, port, port, lab_dir)
open(path, "w").write(config)
PY
fi

"$LAB_DIR/bin/start-server.sh"

WP=( "$LAB_DIR/bin/php" "$LAB_DIR/bin/wp-cli.phar" "--path=$LAB_DIR/wordpress" )
if ! "${WP[@]}" core is-installed >/dev/null 2>&1; then
  echo "[*] installing WordPress"
  if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS="$(genpass)"
    umask 077
    printf 'ADMIN_USER=%s\nADMIN_PASS=%s\n' "$ADMIN_USER" "$ADMIN_PASS" > "$CREDENTIALS_FILE"
    echo "[+] wrote $CREDENTIALS_FILE"
  fi

  # The installer argument is a throwaway; the real password arrives on stdin
  # so it never appears in the process list, logs, or shell history.
  "${WP[@]}" core install \
    --url="http://127.0.0.1:$PORT" \
    --title="$SITE_TITLE" \
    --admin_user="$ADMIN_USER" \
    --admin_password="$(genpass)" \
    --admin_email="$ADMIN_EMAIL" \
    --skip-email
  printf '%s' "$ADMIN_PASS" | "${WP[@]}" eval \
    '$p = trim( stream_get_contents( STDIN ) ); wp_set_password( $p, 1 );'
fi

if [ ! -f "$CREDENTIALS_FILE" ]; then
  echo "[!] $CREDENTIALS_FILE is missing and WordPress is already installed;"
  echo "    set ADMIN_PASS in the environment to run the PoC scripts."
fi

echo
echo "[+] Lab ready at http://127.0.0.1:$PORT/wp-admin/ (user: $ADMIN_USER)"
echo "    Password: see $CREDENTIALS_FILE (mode 600, ignored by Git)"
echo "    ./bin/rce-poc.sh              # plugin-upload RCE chain"
echo "    ./bin/theme-editor-poc.sh     # theme-editor RCE chain"
