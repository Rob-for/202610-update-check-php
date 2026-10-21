#!/usr/bin/env bash
# installeer.sh – installeert of werkt Updatebeheer bij (webpagina + runner) op een Debian/Ubuntu-LXC.
#
# Eerste installatie (database en gebruiker moeten al bestaan, zie database.sql):
#   curl -fsSL https://raw.githubusercontent.com/Rob-for/202610-update-check-php/main/beheer/installeer.sh \
#     | DB_HOST=mysql.rotteveel DB_WACHTWOORD='...' bash
#   Optioneel: DB_NAAM (standaard updatebeheer), DB_GEBRUIKER (standaard updatebeheer), DB_POORT (3306)
#
# Bijwerken naar de nieuwste versie (instellingen blijven behouden):
#   curl -fsSL https://raw.githubusercontent.com/Rob-for/202610-update-check-php/main/beheer/installeer.sh | bash

main() {
set -euo pipefail
exec </dev/null

[ "$(id -u)" -eq 0 ] || { echo "Start als root."; exit 1; }

APP=/opt/updatebeheer
CONFDIR=/etc/updatebeheer
CONF=$CONFDIR/config.php
BRON=${BRON:-https://codeload.github.com/Rob-for/202610-update-check-php/tar.gz/refs/heads/main}

if [ ! -f "$CONF" ] && [ -z "${DB_HOST:-}" ]; then
  echo "Eerste installatie: geef de databasegegevens mee, bijvoorbeeld:"
  echo "  curl -fsSL .../beheer/installeer.sh | DB_HOST=mysql.rotteveel DB_WACHTWOORD='geheim' bash"
  exit 1
fi

echo ">> Pakketten installeren..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq apache2 libapache2-mod-php php-cli php-mysql sshpass openssh-client curl ca-certificates >/dev/null

echo ">> Nieuwste versie ophalen..."
TMP=$(mktemp -d)
if [ -d "$BRON" ]; then
  cp -r "$BRON" "$TMP/beheer"
else
  curl -fsSL "$BRON" | tar -xz -C "$TMP"
  mv "$TMP"/*/beheer "$TMP/beheer"
fi
mkdir -p "$APP"
rm -rf "$APP/public"
cp -r "$TMP/beheer/public" "$TMP/beheer/lib.php" "$TMP/beheer/runner.php" "$APP/"
rm -rf "$TMP"
chown -R root:root "$APP"
chmod -R a+rX "$APP"

if [ ! -f "$CONF" ]; then
  echo ">> Configuratie aanmaken in $CONF..."
  mkdir -p "$CONFDIR"
  SLEUTEL=$(head -c 32 /dev/urandom | base64)
  DB_HOST="$DB_HOST" DB_POORT="${DB_POORT:-3306}" DB_NAAM="${DB_NAAM:-updatebeheer}" \
  DB_GEBRUIKER="${DB_GEBRUIKER:-updatebeheer}" DB_WACHTWOORD="${DB_WACHTWOORD:-}" SLEUTEL="$SLEUTEL" \
  php -r '
    $c = [
      "db_host"       => getenv("DB_HOST"),
      "db_poort"      => (int)getenv("DB_POORT"),
      "db_naam"       => getenv("DB_NAAM"),
      "db_gebruiker"  => getenv("DB_GEBRUIKER"),
      "db_wachtwoord" => getenv("DB_WACHTWOORD"),
      "sleutel"       => getenv("SLEUTEL"),
      "tijdzone"      => "Europe/Amsterdam",
    ];
    echo "<?php\n// Updatebeheer – NIET delen. De sleutel ontsleutelt de serverwachtwoorden in de database.\nreturn " . var_export($c, true) . ";\n";
  ' > "$CONF"
  echo "   Bewaar een kopie van $CONF: zonder de sleutel zijn opgeslagen wachtwoorden niet meer te lezen."
fi
chown root:www-data "$CONFDIR" "$CONF"
chmod 750 "$CONFDIR"; chmod 640 "$CONF"

echo ">> Database controleren..."
if ! php "$APP/runner.php" --migreer; then
  echo "Kan niet verbinden met de database. Controleer $CONF en of de MySQL-gebruiker vanaf dit IP mag inloggen."
  exit 1
fi
php "$APP/runner.php" --importeer

echo ">> Apache instellen (alleen bereikbaar vanaf het lokale netwerk)..."
cat > /etc/apache2/sites-available/updatebeheer.conf <<'EOF'
<VirtualHost *:80>
    DocumentRoot /opt/updatebeheer/public
    <Directory /opt/updatebeheer/public>
        Require ip 127.0.0.1 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 fc00::/7
        AllowOverride None
        Options -Indexes
        DirectoryIndex index.php
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/updatebeheer-error.log
    CustomLog ${APACHE_LOG_DIR}/updatebeheer-access.log combined
</VirtualHost>
EOF
a2dissite -q 000-default >/dev/null 2>&1 || true
a2ensite -q updatebeheer >/dev/null
systemctl reload apache2 2>/dev/null || systemctl restart apache2

echo ">> Runner inplannen (elke minuut)..."
cat > /etc/cron.d/updatebeheer <<'EOF'
# Updatebeheer: wachtrij en planning verwerken
* * * * * root /usr/bin/php /opt/updatebeheer/runner.php >> /var/log/updatebeheer.log 2>&1
EOF
cat > /etc/logrotate.d/updatebeheer <<'EOF'
/var/log/updatebeheer.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
EOF
mkdir -p /root/.ssh && chmod 700 /root/.ssh

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo
echo "Klaar! Open in je browser:  http://${IP:-<ip-van-deze-lxc>}/"
}

main "$@"
