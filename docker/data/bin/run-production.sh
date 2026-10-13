#!/bin/bash
#
# Heresy: production entrypoint for Ampache. The code lives in the image; only config/ and the
# Heresy: logs are persistent volumes. Installs the database on first run (when DB_* is set)
# Heresy: and applies pending migrations on every start, then hands off to supervisord (apache).

set -e

APP_DIR=/var/www/html
CONFIG_DIR="$APP_DIR/config"
CONFIG_FILE="$CONFIG_DIR/ampache.cfg.php"

echo "=> Preparing Ampache"
mkdir -p /var/log/supervisor /var/log/ampache "$CONFIG_DIR"

# Heresy: the config volume hides the image's config/ folder, so refresh the .dist templates from
# Heresy: the image on every start - the installer and config upgrades read them.
cp -f /usr/local/share/ampache/config-dist/*.dist "$CONFIG_DIR/"

wait_for_db() {
    echo "=> Waiting for database ${DB_HOST}:${DB_PORT:-3306}"
    for _ in $(seq 1 60); do
        if php -r '$h=getenv("DB_HOST");$p=(int)(getenv("DB_PORT")?:3306);exit(@fsockopen($h,$p,$e,$s,2)?0:1);'; then
            return 0
        fi
        sleep 2
    done
    echo "=> Database not reachable, continuing anyway"
}

if [ ! -f "$CONFIG_FILE" ] && [ -n "$DB_HOST" ] && [ -n "$DB_NAME" ] && [ -n "$DB_USER" ]; then
    DB_PORT="${DB_PORT:-3306}"
    APP_DB_USER="${AMPACHE_DB_USER:-$DB_USER}"
    APP_DB_PASSWORD="${AMPACHE_DB_PASSWORD:-$DB_PASSWORD}"

    wait_for_db

    echo "=> No config found - installing Ampache database '${DB_NAME}' on ${DB_HOST}"
    if php "$APP_DIR/bin/installer" install \
        --dbhost "$DB_HOST" \
        --dbport "$DB_PORT" \
        --dbname "$DB_NAME" \
        --dbuser "$DB_USER" \
        --dbpassword "$DB_PASSWORD" \
        --ampachedbuser "$APP_DB_USER" \
        --ampachedbpassword "$APP_DB_PASSWORD" \
        --force; then

        php "$APP_DIR/bin/cli" admin:updateDatabase -e || true

        if [ -f "$CONFIG_FILE" ] && [ -n "$AMPACHE_ADMIN_USER" ] && [ -n "$AMPACHE_ADMIN_PASSWORD" ]; then
            echo "=> Creating admin user '$AMPACHE_ADMIN_USER'"
            php "$APP_DIR/bin/cli" admin:addUser "$AMPACHE_ADMIN_USER" \
                -p "$AMPACHE_ADMIN_PASSWORD" \
                -e "${AMPACHE_ADMIN_EMAIL:-admin@example.com}" \
                -l 100 || true
        fi
    else
        echo "=> Automatic install failed - finish the setup in the web installer"
    fi
elif [ -f "$CONFIG_FILE" ] && [ "${AMPACHE_AUTO_UPDATE_DB:-1}" = "1" ]; then
    # Heresy: after a redeploy with newer code, bring the schema up to date
    [ -n "$DB_HOST" ] && wait_for_db
    echo "=> Applying pending database migrations"
    php "$APP_DIR/bin/cli" admin:updateDatabase -e || true
fi

chown -R www-data:www-data /var/log/ampache "$CONFIG_DIR" 2>/dev/null || true

echo "=> Starting services"
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
