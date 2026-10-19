#!/usr/bin/env bash
# Bring up the Docker lab (WordPress + MariaDB) and install WordPress.
# Run from anywhere:  ./bin/setup-docker.sh
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$LAB_DIR"

PORT="${LAB_PORT:-8899}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
SITE_TITLE="${SITE_TITLE:-WP Admin RCE Lab}"
CREDENTIALS_FILE="$LAB_DIR/.admin-credentials"
ENV_FILE="$LAB_DIR/.env"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
docker compose version >/dev/null

genpass() {
  python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(28)))'
}

# Database secrets live in .env (ignored by Git), never in the compose file.
if [ ! -f "$ENV_FILE" ]; then
  umask 077
  {
    printf 'DB_PASSWORD=%s\n' "$(genpass)"
    printf 'DB_ROOT_PASSWORD=%s\n' "$(genpass)"
  } > "$ENV_FILE"
  echo "[+] wrote $ENV_FILE"
fi

if [ -f "$CREDENTIALS_FILE" ]; then
  ADMIN_USER="$(sed -n 's/^ADMIN_USER=//p' "$CREDENTIALS_FILE" | head -1)"
  ADMIN_PASS="$(sed -n 's/^ADMIN_PASS=//p' "$CREDENTIALS_FILE" | head -1)"
fi
ADMIN_PASS="${ADMIN_PASS:-}"

echo "[*] starting containers"
docker compose up -d db wordpress

echo "[*] waiting for WordPress over HTTP"
for _ in $(seq 1 60); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)"
  case "$CODE" in 200|301|302) break ;; esac
  sleep 2
done
[ "${CODE:-}" != "000" ] || { echo "WordPress did not answer on port $PORT" >&2; exit 1; }

# Make sure the shared volume is writable by www-data (uid 33) before WP-CLI
# writes wp-config.php / wp-content as that user.
docker compose exec -T -u root wordpress chown -R www-data:www-data /var/www/html 2>/dev/null || true

echo "[*] waiting for the database"
for _ in $(seq 1 60); do
  if docker compose run --rm cli db check --quiet >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if docker compose run --rm cli core is-installed >/dev/null 2>&1; then
  echo "[=] WordPress is already installed"
else
  echo "[*] installing WordPress"
  if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS="$(genpass)"
    umask 077
    printf 'ADMIN_USER=%s\nADMIN_PASS=%s\n' "$ADMIN_USER" "$ADMIN_PASS" > "$CREDENTIALS_FILE"
  fi

  # The installer argument is a throwaway; the real password arrives on stdin
  # so it never appears in the process list, logs, or shell history.
  docker compose run -T --rm cli core install \
    --url="http://127.0.0.1:$PORT" \
    --title="$SITE_TITLE" \
    --admin_user="$ADMIN_USER" \
    --admin_password="$(genpass)" \
    --admin_email="$ADMIN_EMAIL" \
    --skip-email
  printf '%s' "$ADMIN_PASS" | docker compose run -T --rm cli eval \
    '$p = trim( stream_get_contents( STDIN ) ); wp_set_password( $p, 1 );'
fi

if [ ! -f "$CREDENTIALS_FILE" ]; then
  echo "[!] $CREDENTIALS_FILE is missing and WordPress is already installed;"
  echo "    set ADMIN_PASS in the environment to run the PoC scripts."
fi

cat <<EOF

[+] Lab ready
    URL:      http://127.0.0.1:$PORT/wp-admin/
    User:     $ADMIN_USER
    Password: see $CREDENTIALS_FILE (mode 600, ignored by Git)

    PoC #1 (plugin upload):  BASE_URL=http://127.0.0.1:$PORT ./bin/rce-poc.sh
    PoC #2 (theme editor):   BASE_URL=http://127.0.0.1:$PORT ./bin/theme-editor-poc.sh

    Tear down (deletes the database and WordPress volume):
      docker compose down -v
EOF
