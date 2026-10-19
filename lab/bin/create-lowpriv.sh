#!/usr/bin/env bash
# Create the low-privilege Subscriber account used by the escalation tests.
# Idempotent: reuses .lowpriv-credentials when present.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CREDENTIALS_FILE="$LAB_DIR/.lowpriv-credentials"
PHP="$LAB_DIR/bin/php"
WPCLI="$LAB_DIR/bin/wp-cli.phar"

if [ -f "$CREDENTIALS_FILE" ]; then
  echo "[=] $CREDENTIALS_FILE already exists"
  exit 0
fi

PASS="$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24)))')"

printf '%s' "$PASS" | "$PHP" "$WPCLI" --path="$LAB_DIR/wordpress" eval '
  $p = trim( stream_get_contents( STDIN ) );
  $id = wp_insert_user( array(
    "user_login"   => "lowpriv",
    "user_email"   => "lowpriv@example.com",
    "user_pass"    => $p,
    "role"         => "subscriber",
    "display_name" => "Low Priv",
  ) );
  echo is_wp_error( $id ) ? $id->get_error_message() : "created $id";
'

umask 077
printf 'LOWPRIV_USER=lowpriv\nLOWPRIV_PASS=%s\n' "$PASS" > "$CREDENTIALS_FILE"
chmod 600 "$CREDENTIALS_FILE"
echo
echo "[+] subscriber 'lowpriv' ready; credentials in $CREDENTIALS_FILE"
