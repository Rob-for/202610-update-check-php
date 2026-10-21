#!/usr/bin/env bash
# update-check.sh – werkt een Linux-server volledig bij en meldt daarna JA of NEE
#
# Eerste keer (Pushover-sleutels worden onthouden in /etc/update-check.conf):
#   curl -fsSL https://raw.githubusercontent.com/Rob-for/202610-update-check-php/main/update-check.sh | PUSHOVER_USER=xxx PUSHOVER_TOKEN=yyy bash
# Daarna is dit genoeg:
#   curl -fsSL https://raw.githubusercontent.com/Rob-for/202610-update-check-php/main/update-check.sh | bash
# (Geen root? Zet 'sudo' voor 'PUSHOVER_USER=...' of voor 'bash'.)
#
# Werkt op Debian/Ubuntu (apt) en Fedora/RHEL/Rocky/Alma (dnf).
# Exitcodes: 0 = JA, 2 = JA met aandachtspunten, 1 = NEE

# Alles zit in main(), zodat bash het hele script eerst inleest.
# Zo is 'curl ... | bash' veilig: apt/dpkg kunnen het script niet van stdin 'opeten'.
main() {
set -u

if [ "$(id -u)" -ne 0 ]; then
  echo "Start dit script als root (of met sudo)."
  exit 1
fi
exec </dev/null

LOG=/var/log/update-check.log
CONF=/etc/update-check.conf

# Pushover-instellingen: meegegeven waarden gaan voor en worden onthouden
NIEUW_USER=${PUSHOVER_USER:-}; NIEUW_TOKEN=${PUSHOVER_TOKEN:-}; NIEUW_PRIO=${PUSHOVER_PRIORITY:-}
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
[ -n "$NIEUW_USER" ]  && PUSHOVER_USER=$NIEUW_USER
[ -n "$NIEUW_TOKEN" ] && PUSHOVER_TOKEN=$NIEUW_TOKEN
[ -n "$NIEUW_PRIO" ]  && PUSHOVER_PRIORITY=$NIEUW_PRIO
PUSHOVER_PRIORITY=${PUSHOVER_PRIORITY:--1}
if [ -n "$NIEUW_USER$NIEUW_TOKEN$NIEUW_PRIO" ]; then
  ( umask 077
    printf 'PUSHOVER_USER=%q\nPUSHOVER_TOKEN=%q\nPUSHOVER_PRIORITY=%q\n' \
      "${PUSHOVER_USER:-}" "${PUSHOVER_TOKEN:-}" "$PUSHOVER_PRIORITY" > "$CONF" )
fi

exec > >(tee -a "$LOG") 2>&1

PROBLEMEN=(); WAARSCHUWINGEN=(); INFO=()
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
  export NEEDRESTART_SUSPEND=1          # needrestart pas na de updates zelf draaien
  # Bij gewijzigde configbestanden: jouw versie behouden
  APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

  echo ">> Pakketlijsten ophalen..."
  apt-get update || probleem "apt-get update mislukt (netwerk- of repository-fout)"

  if ! dpkg -s needrestart >/dev/null 2>&1; then
    echo ">> needrestart installeren (herstart diensten na updates)..."
    apt-get "${APT_OPTS[@]}" install needrestart || waarschuwing "needrestart installeren mislukt"
  fi

  echo ">> Pakketten bijwerken..."
  apt-get "${APT_OPTS[@]}" upgrade --with-new-pkgs || probleem "apt-get upgrade mislukt"
  apt-get "${APT_OPTS[@]}" autoremove || waarschuwing "autoremove mislukt"
elif command -v dnf >/dev/null; then
  PM=dnf
  echo ">> Pakketten bijwerken..."
  dnf -y upgrade --refresh || probleem "dnf upgrade mislukt"
  dnf -y autoremove || waarschuwing "autoremove mislukt"
  dnf -q needs-restarting -r >/dev/null 2>&1; [ $? -gt 1 ] && dnf -y install dnf-plugins-core >/dev/null 2>&1
else
  echo "Geen apt of dnf gevonden; deze distributie wordt niet ondersteund."
  exit 1
fi

# ---------------------------------------------------------------
# 2. Controleren of alles echt bijgewerkt is
# ---------------------------------------------------------------
echo ">> Controleren op achtergebleven updates..."
if [ "$PM" = apt ]; then
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
  [ -n "$HELD" ] && waarschuwing "Bewust vastgehouden (apt-mark hold): $HELD"
  [ -n "$FASE" ] && INFO+=("Uitgesteld door Ubuntu phased updates (normaal, volgt vanzelf): $FASE")
  [ -n "$(dpkg --audit 2>/dev/null)" ] && probleem "Half-geïnstalleerde pakketten (oplossen met: dpkg --configure -a)"
else
  dnf -q check-update >/dev/null 2>&1
  [ $? -eq 100 ] && probleem "Er staan nog updates open (zie: dnf check-update)"
fi

# ---------------------------------------------------------------
# 3. Diensten herstarten die nog oude (kwetsbare) code in het geheugen hebben
# ---------------------------------------------------------------
echo ">> Diensten met oude bibliotheken herstarten..."
REBOOT=0
if [ "$PM" = apt ] && command -v needrestart >/dev/null; then
  needrestart -r a -q >/dev/null 2>&1
  NR=$(needrestart -b -r l 2>/dev/null)
  KSTA=$(echo "$NR" | awk -F': ' '/NEEDRESTART-KSTA/ {print $2}')
  REST=$(echo "$NR" | awk -F': ' '/NEEDRESTART-SVC/ {print $2}' | xargs)
  [ "${KSTA:-0}" -ge 2 ] && REBOOT=1
  [ -n "$REST" ] && waarschuwing "Niet automatisch herstart (herstart van de server lost dit op): $REST"
elif [ "$PM" = dnf ]; then
  for svc in $(dnf -q needs-restarting -s 2>/dev/null); do
    case "$svc" in
      dbus*|systemd-*|*getty*|user@*) ;;   # niet veilig om live te herstarten
      *) systemctl try-restart "$svc" && echo "   herstart: $svc" ;;
    esac
  done
  dnf -q needs-restarting -r >/dev/null 2>&1; [ $? -eq 1 ] && REBOOT=1
  REST=$(dnf -q needs-restarting -s 2>/dev/null | xargs)
  [ -n "$REST" ] && waarschuwing "Niet automatisch herstart (herstart van de server lost dit op): $REST"
fi
[ -f /var/run/reboot-required ] && REBOOT=1
[ "$REBOOT" -eq 1 ] && waarschuwing "Herstart van de server nodig (nieuwe kernel of systeembibliotheken)"

# ---------------------------------------------------------------
# 4. Algemene gezondheid
# ---------------------------------------------------------------
echo ">> Services en schijfruimte controleren..."
FAILED=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | xargs)
[ -n "$FAILED" ] && waarschuwing "Mislukte services: $FAILED"

ROOTVOL=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ "${ROOTVOL:-0}" -ge 90 ] && waarschuwing "Schijf / is ${ROOTVOL}% vol"

if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  INFO+=("Docker-containers worden niet bijgewerkt (docker compose pull && docker compose up -d)")
fi

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

REGELS=$(
  for p in ${PROBLEMEN[@]+"${PROBLEMEN[@]}"}; do echo "[X] $p"; done
  for w in ${WAARSCHUWINGEN[@]+"${WAARSCHUWINGEN[@]}"}; do echo "[!] $w"; done
  for i in ${INFO[@]+"${INFO[@]}"}; do echo "[i] $i"; done
)

echo
echo "================ RESULTAAT ================"
[ -n "$REGELS" ] && echo "$REGELS" | sed 's/^/  /' && echo
echo "  Alles OK?  >>>  $STATUS  <<<"
echo "==========================================="
echo "Log: $LOG"

stuur_push
exit $RC
}

# ---------------------------------------------------------------
# Pushover-melding met het resultaat
# ---------------------------------------------------------------
stuur_push() {
  [ "${GEEN_PUSH:-}" = 1 ] && return 0   # update-alle.sh stuurt de melding zelf
  [ -n "${PUSHOVER_USER:-}" ] && [ -n "${PUSHOVER_TOKEN:-}" ] || return 0
  local tekst="${REGELS:-Alles bijgewerkt, geen bijzonderheden.}"
  if curl -s --max-time 20 \
       --form-string "token=$PUSHOVER_TOKEN" \
       --form-string "user=$PUSHOVER_USER" \
       --form-string "title=$(hostname): $STATUS" \
       --form-string "message=${tekst:0:1000}" \
       --form-string "priority=$PUSHOVER_PRIORITY" \
       https://api.pushover.net/1/messages.json | grep -q '"status":1'; then
    echo "Pushover-melding verstuurd."
  else
    echo "[!] Pushover-melding versturen mislukt (controleer PUSHOVER_USER/PUSHOVER_TOKEN)."
  fi
}

main "$@"
