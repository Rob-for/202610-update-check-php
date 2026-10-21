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
exec > >(tee -a "$LOG") 2>&1

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

echo ">> PHP controleren..."
PHP_GEVONDEN=0
{
  if command -v php >/dev/null; then
    php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION, "\n";' 2>/dev/null
  fi
  if [ "$PM" = apt ]; then
    # Alle geïnstalleerde PHP-versies (ook php-fpm die de webserver gebruikt)
    dpkg-query -W -f='${Status} ${Package}\n' 'php*' 2>/dev/null \
      | awk '/install ok installed/ && $4 ~ /^php[0-9]+\.[0-9]+(-|$)/ {sub(/^php/,"",$4); sub(/-.*/,"",$4); print $4}'
  fi
} | sort -u > /tmp/update-check-php.$$

while read -r v; do
  [ -n "$v" ] || continue
  PHP_GEVONDEN=1
  check_php "$v" "server"
done < /tmp/update-check-php.$$
rm -f /tmp/update-check-php.$$

# PHP in draaiende Docker-containers
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  for c in $(docker ps --format '{{.Names}}'); do
    v=$(docker exec "$c" php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null) || continue
    [ -n "$v" ] || continue
    PHP_GEVONDEN=1
    check_php "$v" "container $c"
  done
  DOCKER_INFO=1
else
  DOCKER_INFO=0
fi
[ "$PHP_GEVONDEN" -eq 0 ] && echo "   Geen PHP gevonden."

# ---------------------------------------------------------------
# 4. Algemene gezondheid
# ---------------------------------------------------------------
echo ">> Services en schijfruimte controleren..."
FAILED=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[ -n "${FAILED// /}" ] && waarschuwing "Mislukte services: $FAILED"

ROOTVOL=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ "${ROOTVOL:-0}" -ge 90 ] && waarschuwing "Schijf / is ${ROOTVOL}% vol"

# ---------------------------------------------------------------
# 5. Resultaat
# ---------------------------------------------------------------
echo
echo "================ RESULTAAT ================"
for p in ${PROBLEMEN[@]+"${PROBLEMEN[@]}"}; do echo "  [X] $p"; done
for w in ${WAARSCHUWINGEN[@]+"${WAARSCHUWINGEN[@]}"}; do echo "  [!] $w"; done
for i in ${INFO[@]+"${INFO[@]}"}; do echo "  [i] $i"; done
[ "$DOCKER_INFO" -eq 1 ] && echo "  [i] Docker-containers worden niet door dit script bijgewerkt (docker compose pull && docker compose up -d)"
echo

if [ ${#PROBLEMEN[@]} -gt 0 ]; then
  echo "  Alles OK?  >>>  NEE  <<<"
  RC=1
elif [ ${#WAARSCHUWINGEN[@]} -gt 0 ]; then
  echo "  Alles OK?  >>>  JA, met aandachtspunten (zie [!] hierboven)  <<<"
  RC=2
else
  echo "  Alles OK?  >>>  JA  <<<"
  RC=0
fi
echo "==========================================="
echo "Log: $LOG"
exit $RC
}

main "$@"