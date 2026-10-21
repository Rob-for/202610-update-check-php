#!/usr/bin/env bash
# update-check.sh – werkt de server bij en meldt daarna JA of NEE
#
# Gebruik (rechtstreeks van GitHub):
#   curl -fsSL https://raw.githubusercontent.com/Rob-for/202610-update-check-php/main/update-check.sh | sudo bash
# of lokaal:
#   sudo bash update-check.sh
#
# Logbestand: /var/log/update-check.log
# Werkt op Debian/Ubuntu (apt) en Fedora/RHEL/Rocky/Alma (dnf).
#
# Exitcodes: 0 = JA, 2 = JA met aandachtspunten, 1 = NEE

# Alles zit in main(), zodat bash het hele script eerst inleest.
# Zo kan 'curl ... | sudo bash' veilig: apt/dpkg kunnen het script niet van stdin 'opeten'.
main() {
set -u

if [ "$(id -u)" -ne 0 ]; then
  echo "Start dit script als root (met sudo)."
  exit 1
fi

exec </dev/null

LOG=/var/log/update-check.log

# Instellingen per server (mail e.d.) – staan NIET in de publieke repo
CONF=/etc/update-check.conf
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

RUNLOG=$(mktemp)
exec > >(tee -a "$LOG" "$RUNLOG") 2>&1

PROBLEMEN=()
WAARSCHUWINGEN=()
INFO=()
probleem()     { PROBLEMEN+=("$1"); }
waarschuwing() { WAARSCHUWINGEN+=("$1"); }

echo
echo "=== update-check $(date '+%F %T') op $(hostname) ==="

# ---------------------------------------------------------------
# 1. Alles bijwerken
# ---------------------------------------------------------------
if command -v apt-get >/dev/null; then
  PM=apt
  export DEBIAN_FRONTEND=noninteractive
  # Bij gewijzigde configbestanden: jouw versie behouden
  APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

  echo ">> Pakketlijsten ophalen..."
  apt-get update || probleem "apt-get update mislukt (netwerk- of repository-fout)"

  echo ">> Pakketten bijwerken..."
  apt-get "${APT_OPTS[@]}" upgrade --with-new-pkgs || probleem "apt-get upgrade mislukt"
  apt-get "${APT_OPTS[@]}" autoremove || waarschuwing "autoremove mislukt"
elif command -v dnf >/dev/null; then
  PM=dnf
  echo ">> Pakketten bijwerken..."
  dnf -y upgrade --refresh || probleem "dnf upgrade mislukt"
  dnf -y autoremove || waarschuwing "autoremove mislukt"
else
  echo "Geen apt of dnf gevonden; deze distributie wordt niet ondersteund."
  exit 1
fi

# ---------------------------------------------------------------
# 2. Controleren of alles echt bijgewerkt is
# ---------------------------------------------------------------
echo ">> Controleren op achtergebleven updates..."
if [ "$PM" = apt ]; then
  # Simuleer nog een upgrade om te zien wat er (nog) openstaat
  SIM=$(LC_ALL=C apt-get -s upgrade --with-new-pkgs 2>/dev/null)
  blok() { echo "$SIM" | awk -v kop="$1" '$0 ~ kop {f=1; next} f && /^  / {print; next} {f=0}' | xargs; }
  OPEN=$(echo "$SIM" | grep -c '^Inst ' || true)
  FASE=$(blok "deferred due to phasing")
  KEPT=$(blok "have been kept back")
  HELD=$(apt-mark showhold 2>/dev/null | xargs)

  [ "$OPEN" -gt 0 ] && probleem "$OPEN update(s) staan nog open ondanks de upgrade"
  if [ -n "$KEPT" ]; then
    KEPT_ECHT=$(for k in $KEPT; do echo " $HELD " | grep -q " $k " || echo "$k"; done | xargs)
    [ -n "$KEPT_ECHT" ] && probleem "Tegengehouden door afhankelijkheden (los op met: apt full-upgrade): $KEPT_ECHT"
  fi
  [ -n "$HELD" ] && waarschuwing "Bewust vastgehouden met apt-mark hold, niet bijgewerkt: $HELD"
  [ -n "$FASE" ] && INFO+=("Uitgesteld door Ubuntu phased updates (normaal, volgt vanzelf): $FASE")
  if [ -n "$(dpkg --audit 2>/dev/null)" ]; then
    probleem "dpkg meldt half-geïnstalleerde pakketten (oplossen met: dpkg --configure -a)"
  fi
  if [ -f /var/run/reboot-required ]; then
    waarschuwing "Herstart nodig voor: $(cat /var/run/reboot-required.pkgs 2>/dev/null | sort -u | tr '\n' ' ')"
  fi
else
  dnf -q check-update >/dev/null 2>&1
  [ $? -eq 100 ] && probleem "Er staan nog updates open (zie: dnf check-update)"
  if command -v needs-restarting >/dev/null; then
    needs-restarting -r >/dev/null 2>&1 || waarschuwing "Herstart nodig (nieuwe kernel of systeembibliotheken)"
  fi
fi

# ---------------------------------------------------------------
# 3. PHP-versies controleren
# ---------------------------------------------------------------
# Einde beveiligingsupdates per versie (bron: php.net/supported-versions).
# Werk deze lijst af en toe bij als er nieuwe versies uitkomen.
php_eol() {
  case "$1" in
    8.2) echo 2026-12-31 ;;
    8.3) echo 2027-12-31 ;;
    8.4) echo 2028-12-31 ;;
    8.5) echo 2029-12-31 ;;
    [0-7].*|8.0|8.1) echo verlopen ;;
    *) echo onbekend ;;
  esac
}

check_php() {
  local v="$1" waar="$2" eol dagen
  eol=$(php_eol "$v")
  case "$eol" in
    verlopen) probleem "PHP $v ($waar) krijgt geen beveiligingsupdates meer – upgraden" ;;
    onbekend) echo "   PHP $v ($waar): nieuwer dan dit script kent, vermoedelijk ok" ;;
    *)
      dagen=$(( ( $(date -d "$eol" +%s) - $(date +%s) ) / 86400 ))
      if [ "$dagen" -lt 0 ]; then
        probleem "PHP $v ($waar) is sinds $eol einde levensduur – upgraden"
      elif [ "$dagen" -lt 120 ]; then
        waarschuwing "PHP $v ($waar) stopt over $dagen dagen met updates ($eol) – upgrade plannen"
      else
        echo "   PHP $v ($waar): ondersteund tot $eol"
      fi ;;
  esac
}

# PHP2Shell (CVE-2026-109618 / CVE-2026-109619, oktober 2026)
# Eerste upstream-versies MET de fix. Verwacht per 21-10-2026 16:00 –
# controleer na de release op https://www.php.net/archive/2026.php
PHP2SHELL_CVE='CVE-2026-10961[89]'
php2shell_fix() {
  case "$1" in
    8.2) echo 8.2.35 ;;
    8.3) echo 8.3.36 ;;
    8.4) echo 8.4.27 ;;
    8.5) echo 8.5.12 ;;
    *)   echo geen ;;
  esac
}
versie_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }  # $1 >= $2

# $1 = volledige versie (8.2.32), $2 = waar, $3 = "ja" als de distro-changelog de CVE noemt
check_php2shell() {
  local full="$1" waar="$2" backport="${3:-nee}" fix
  fix=$(php2shell_fix "${full%.*}")
  if [ "$backport" = ja ]; then
    echo "   PHP2Shell: PHP $full ($waar) gepatcht (distro-update)"
  elif [ "$fix" != geen ] && versie_ge "$full" "$fix"; then
    echo "   PHP2Shell: PHP $full ($waar) gepatcht"
  elif [ "$fix" = geen ]; then
    probleem "PHP2Shell: PHP $full ($waar) is KWETSBAAR en krijgt geen upstream-fix – upgraden of offline halen"
  else
    probleem "PHP2Shell: PHP $full ($waar) is KWETSBAAR – fix zit in $fix of een distro-update"
  fi
}

echo ">> PHP controleren..."
PHP_GEVONDEN=0
PHP_VERSIES=$(
  {
    if command -v php >/dev/null; then
      php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION, "\n";' 2>/dev/null
    fi
    if [ "$PM" = apt ]; then
      # Alle geïnstalleerde PHP-versies (ook php-fpm die de webserver gebruikt)
      dpkg-query -W -f='${Status} ${Package}\n' 'php*' 2>/dev/null \
        | awk '/install ok installed/ && $4 ~ /^php[0-9]+\.[0-9]+(-|$)/ {sub(/^php/,"",$4); sub(/-.*/,"",$4); print $4}'
    fi
  } | sort -u | xargs
)

for v in $PHP_VERSIES; do
  PHP_GEVONDEN=1
  check_php "$v" "server"

  # PHP2Shell: kijk eerst of de distro de fix heeft (changelog), anders naar het versienummer
  full=""; backport=nee
  if [ "$PM" = apt ]; then
    pkgv=$(dpkg-query -W -f='${Version}' "php$v-common" 2>/dev/null)
    full=$(echo "$pkgv" | sed -E 's/^[0-9]+://; s/[-+~].*//')
    cl="/usr/share/doc/php$v-common/changelog.Debian.gz"
    [ -f "$cl" ] && zgrep -qE "$PHP2SHELL_CVE" "$cl" && backport=ja
  else
    full=$(php -r 'echo PHP_VERSION;' 2>/dev/null)
    rpm -q --changelog php-common 2>/dev/null | grep -qE "$PHP2SHELL_CVE" && backport=ja
  fi
  [ -n "$full" ] || full=$(php -r 'echo PHP_VERSION;' 2>/dev/null)
  [ -n "$full" ] && check_php2shell "$full" "server" "$backport"
done

# PHP in draaiende Docker-containers (officiële images volgen upstream-versies)
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  for c in $(docker ps --format '{{.Names}}'); do
    full=$(docker exec "$c" php -r 'echo PHP_VERSION;' 2>/dev/null) || continue
    [ -n "$full" ] || continue
    PHP_GEVONDEN=1
    v=$(echo "$full" | cut -d. -f1,2)
    check_php "$v" "container $c"
    check_php2shell "$(echo "$full" | sed -E 's/[-+~].*//')" "container $c"
  done
  DOCKER_INFO=1
else
  DOCKER_INFO=0
fi
[ "$PHP_GEVONDEN" -eq 0 ] && echo "   Geen PHP gevonden."

# Draaien PHP-FPM / Apache nog met oude PHP in het geheugen? Dan herstarten.
if [ "$PHP_GEVONDEN" -eq 1 ] && [ "${HERSTART_PHP:-ja}" = ja ]; then
  NIEUWSTE=$(stat -c %Y /usr/sbin/php-fpm* /usr/bin/php[0-9]* /usr/lib/php/*/*.so \
    /usr/lib/apache2/modules/libphp*.so /usr/lib64/httpd/modules/libphp*.so /usr/lib64/php/modules/*.so \
    2>/dev/null | sort -n | tail -1)
  if [ -n "$NIEUWSTE" ]; then
    for svc in $(systemctl list-units --type=service --state=running --no-legend --plain \
                  'php*-fpm*' 'apache2*' 'httpd*' 2>/dev/null | awk '{print $1}'); do
      gestart=$(systemctl show -p ExecMainStartTimestamp --value "$svc" 2>/dev/null)
      gestart=$(date -d "$gestart" +%s 2>/dev/null || echo 0)
      if [ "$gestart" -lt "$NIEUWSTE" ]; then
        echo "   $svc draait nog met oude PHP – herstarten..."
        systemctl try-restart "$svc" && echo "   $svc herstart" \
          || probleem "$svc kon niet herstart worden – draait mogelijk nog kwetsbare PHP"
      fi
    done
  fi
fi

# ---------------------------------------------------------------
# 4. Algemene gezondheid
# ---------------------------------------------------------------
echo ">> Services en schijfruimte controleren..."
FAILED=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[ -n "${FAILED// /}" ] && waarschuwing "Mislukte services: $FAILED"

# Snelle check op webshells: .php-bestanden in upload-mappen horen daar niet
if [ -d /var/www ]; then
  WS=$(timeout 60 find /var/www -type f -iname '*.php*' -path '*/uploads/*' 2>/dev/null | head -5 | xargs)
  [ -n "$WS" ] && waarschuwing "PHP-bestanden in upload-map (mogelijk webshell, controleren!): $WS"
fi

ROOTVOL=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ "${ROOTVOL:-0}" -ge 90 ] && waarschuwing "Schijf / is ${ROOTVOL}% vol"

# ---------------------------------------------------------------
# 5. Resultaat
# ---------------------------------------------------------------
if [ ${#PROBLEMEN[@]} -gt 0 ]; then
  STATUS="NEE"; RC=1
elif [ ${#WAARSCHUWINGEN[@]} -gt 0 ]; then
  STATUS="JA, met aandachtspunten"; RC=2
else
  STATUS="JA"; RC=0
fi

SAMENVATTING=$(
  echo "Server:  $(hostname) ($(hostname -I 2>/dev/null | awk '{print $1}'))"
  echo "Tijd:    $(date '+%F %T')"
  echo
  for p in ${PROBLEMEN[@]+"${PROBLEMEN[@]}"}; do echo "  [X] $p"; done
  for w in ${WAARSCHUWINGEN[@]+"${WAARSCHUWINGEN[@]}"}; do echo "  [!] $w"; done
  for i in ${INFO[@]+"${INFO[@]}"}; do echo "  [i] $i"; done
  [ "$DOCKER_INFO" -eq 1 ] && echo "  [i] Docker-containers worden niet door dit script bijgewerkt (docker compose pull && docker compose up -d)"
  echo
  echo "  Alles OK?  >>>  $STATUS  <<<"
)

echo
echo "================ RESULTAAT ================"
echo "$SAMENVATTING"
echo "==========================================="
echo "Log: $LOG"

stuur_mail
rm -f "$RUNLOG"
exit $RC
}

# ---------------------------------------------------------------
# Mail met het resultaat (instellingen in /etc/update-check.conf)
# ---------------------------------------------------------------
stuur_mail() {
  [ -n "${MAIL_TO:-}" ] || return 0
  if [ "${MAIL_BIJ:-altijd}" = problemen ] && [ "$RC" -eq 0 ]; then
    echo "Geen mail: alles OK en MAIL_BIJ=problemen."
    return 0
  fi

  local van="${MAIL_FROM:-update-check@$(hostname -f 2>/dev/null || hostname)}"
  local bericht
  bericht=$(mktemp)
  {
    echo "From: update-check $(hostname) <$van>"
    echo "To: $MAIL_TO"
    echo "Subject: [update-check] $(hostname): $STATUS"
    echo "Date: $(LC_ALL=C date -R)"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo
  } > "$bericht"
  # Body: voortgangsregels (\r) en kleurcodes eruit, regels max 900 tekens (SMTP-limiet)
  {
    echo "$SAMENVATTING"
    echo
    echo "------------------ volledige uitvoer ------------------"
    cat "$RUNLOG"
  } | tr '\r' '\n' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | fold -w 900 >> "$bericht"

  if [ -n "${SMTP_URL:-}" ]; then
    local opts=(-sS --crlf --noproxy '*' --url "${SMTP_URL%/}/$(hostname -f 2>/dev/null || hostname)" --mail-from "$van" --mail-rcpt "$MAIL_TO" --upload-file "$bericht")
    [ "${SMTP_TLS:-ja}" = ja ] && opts+=(--ssl-reqd)
    [ -n "${SMTP_USER:-}" ] && opts+=(--user "$SMTP_USER:${SMTP_PASS:-}")
    if curl "${opts[@]}"; then
      echo "Mail verstuurd naar $MAIL_TO"
    else
      echo "[!] Mail versturen via $SMTP_URL mislukt"
    fi
  elif command -v sendmail >/dev/null; then
    sendmail -t < "$bericht" && echo "Mail verstuurd naar $MAIL_TO (via sendmail)" \
      || echo "[!] Mail versturen via sendmail mislukt"
  else
    echo "[!] Geen SMTP_URL in $CONF en geen sendmail gevonden: mail niet verstuurd"
  fi
  rm -f "$bericht"
}

main "$@"
