#!/usr/bin/env bash
# update-alle.sh – draait update-check.sh op al je servers via SSH, één voor één
#
# Gebruik (op de beheer-LXC, als root):
#   curl -fsSL https://raw.githubusercontent.com/Rob-for/202610-update-check-php/main/update-alle.sh | bash
#
# Eerste keer met Pushover (sleutels worden onthouden in /etc/update-check.conf):
#   curl -fsSL .../update-alle.sh | PUSHOVER_USER=xxx PUSHOVER_TOKEN=yyy bash
#
# Optioneel, eenmalig: SSH-sleutels op alle servers zetten.
# Daarna mogen de wachtwoorden uit servers.txt (behalve als sudo er een nodig heeft).
#   curl -fsSL .../update-alle.sh | bash -s sleutels
#
# De serverlijst staat in /root/servers.txt (zie servers.txt.voorbeeld).

main() {
set -u
exec </dev/null

if [ "$(id -u)" -ne 0 ]; then
  echo "Start dit script als root."
  exit 1
fi

SERVERS=${SERVERS:-/root/servers.txt}
SCRIPT_URL=${SCRIPT_URL:-"https://raw.githubusercontent.com/Rob-for/202610-update-check-php/main/update-check.sh"}
LOGDIR=/var/log/update-alle
CONF=/etc/update-check.conf
MODUS=${1:-update}

# --- Pushover-instellingen (zelfde manier als update-check.sh) ---
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

# --- Benodigde programma's ---
NODIG=()
command -v ssh     >/dev/null || NODIG+=(openssh-client)
command -v sshpass >/dev/null || NODIG+=(sshpass)
command -v curl    >/dev/null || NODIG+=(curl)
if [ ${#NODIG[@]} -gt 0 ]; then
  echo ">> Installeren: ${NODIG[*]}"
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${NODIG[@]}" >/dev/null \
    || { echo "Installeren mislukt."; exit 1; }
fi

# --- Serverlijst inlezen ---
if [ ! -f "$SERVERS" ]; then
  echo "Serverlijst $SERVERS niet gevonden. Maak hem aan, bijvoorbeeld:"
  echo
  echo "  # host[:poort]     gebruiker   wachtwoord (leeg = SSH-sleutel)"
  echo "  192.168.1.52       bart        geheim"
  echo "  lamp.thuis.lan     root"
  exit 1
fi
chmod 600 "$SERVERS"
mapfile -t REGELS < <(grep -vE '^[[:space:]]*(#|$)' "$SERVERS")
if [ ${#REGELS[@]} -eq 0 ]; then
  echo "Geen servers in $SERVERS."
  exit 1
fi

mkdir -p /root/.ssh "$LOGDIR"; chmod 700 /root/.ssh
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=30 -o ServerAliveCountMax=20)

# --- Modus: SSH-sleutels uitrollen ---
if [ "$MODUS" = sleutels ]; then
  [ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519 -C "update-alle@$(hostname)"
  for regel in "${REGELS[@]}"; do
    read -r doel gebruiker ww _ <<< "$regel"
    host=${doel%%:*}; poort=22; [[ $doel == *:* ]] && poort=${doel##*:}
    echo ">> $host: sleutel plaatsen voor $gebruiker..."
    if [ -n "${ww:-}" ]; then
      SSHPASS=$ww sshpass -e ssh-copy-id -i /root/.ssh/id_ed25519.pub "${SSH_OPTS[@]}" -p "$poort" "$gebruiker@$host" >/dev/null 2>&1 \
        && echo "   gelukt" || echo "   MISLUKT"
    else
      echo "   overgeslagen (geen wachtwoord in de lijst)"
    fi
  done
  echo
  echo "Klaar. Gebruikers die geen sudo-wachtwoord nodig hebben (of root zijn), mogen nu zonder wachtwoord in $SERVERS."
  exit 0
fi

# --- Modus: updates draaien ---
STAMP=$(date +%F_%H%M)
OVERZICHT=(); DETAILS=(); N_JA=0; N_NEE=0

for regel in "${REGELS[@]}"; do
  read -r doel gebruiker ww _ <<< "$regel"
  ww=${ww:-}
  host=${doel%%:*}; poort=22; [[ $doel == *:* ]] && poort=${doel##*:}
  log="$LOGDIR/${host}_$STAMP.log"

  # Commando op de server: update-check ophalen en draaien; push stuurt dit script per server
  remote="env GEEN_PUSH=1 bash -o pipefail -c '(curl -fsSL $SCRIPT_URL 2>/dev/null || wget -qO- $SCRIPT_URL) | bash'"
  [ "$gebruiker" != root ] && remote="sudo -S -p '' $remote"

  echo
  echo "######## $host ($gebruiker) – bezig... (log: $log)"
  if [ -n "$ww" ]; then
    # Wachtwoord gaat via stdin naar sudo, en via SSHPASS naar ssh – nooit op de commandline
    printf '%s\n' "$ww" | SSHPASS=$ww sshpass -e ssh "${SSH_OPTS[@]}" -p "$poort" "$gebruiker@$host" "$remote" > "$log" 2>&1
    rc=$?
  else
    ssh -o BatchMode=yes "${SSH_OPTS[@]}" -p "$poort" "$gebruiker@$host" "$remote" > "$log" 2>&1 < /dev/null
    rc=$?
  fi

  # Resultaatblok van de server tonen
  sed -n '/RESULTAAT/,/^=====/p' "$log" | sed '1d;$d'

  if ! grep -q 'Alles OK?' "$log"; then
    case $rc in
      5)   status="INLOGGEN MISLUKT (verkeerd wachtwoord?)" ;;
      255) status="NIET BEREIKBAAR / SSH-fout" ;;
      *)   status="FOUT (code $rc) – zie log"
           grep -qiE 'sudo:.*(password|wachtwoord)|incorrect password|no tty' "$log" && status="SUDO MISLUKT (wachtwoord nodig of fout)" ;;
    esac
    rc=1
  else
    case $rc in
      0) status="JA" ;;
      2) status="JA, met aandachtspunten" ;;
      *) status="NEE" ;;
    esac
  fi

  echo "-------- $host: $status"
  OVERZICHT+=("$host: $status")
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then N_JA=$((N_JA+1)); else N_NEE=$((N_NEE+1)); fi

  # Eén Pushover-melding per server
  details=$(grep -E '^[[:space:]]+\[(X|!)\]' "$log" | sed -E 's/^[[:space:]]+//')
  [ -n "$details" ] || details="Alles bijgewerkt, geen bijzonderheden."
  stuur_push "$host: $status" "$details"
done

# --- Totaaloverzicht ---
echo
echo "================ OVERZICHT ALLE SERVERS ================"
for o in "${OVERZICHT[@]}"; do echo "  $o"; done
echo
if [ "$N_NEE" -eq 0 ]; then
  ALLES="JA"
else
  ALLES="NEE ($N_NEE van ${#REGELS[@]} niet in orde)"
fi
echo "  Alles OK?  >>>  $ALLES  <<<"
echo "========================================================"
echo "Logs: $LOGDIR"

# Logs ouder dan 90 dagen opruimen
find "$LOGDIR" -name '*.log' -mtime +90 -delete 2>/dev/null

if [ -z "${PUSHOVER_USER:-}" ] || [ -z "${PUSHOVER_TOKEN:-}" ]; then
  echo
  echo "[!] Geen Pushover-sleutels ingesteld, er zijn geen meldingen verstuurd."
  echo "    Draai één keer met:  curl ... | PUSHOVER_USER=<user-key> PUSHOVER_TOKEN=<api-token> bash"
fi
[ "$N_NEE" -eq 0 ]
}

# Pushover-melding: $1 = titel, $2 = tekst
stuur_push() {
  [ -n "${PUSHOVER_USER:-}" ] && [ -n "${PUSHOVER_TOKEN:-}" ] || return 0
  local antwoord
  antwoord=$(curl -sS --max-time 20 \
       --form-string "token=$PUSHOVER_TOKEN" \
       --form-string "user=$PUSHOVER_USER" \
       --form-string "title=$1" \
       --form-string "message=${2:0:1000}" \
       --form-string "priority=$PUSHOVER_PRIORITY" \
       https://api.pushover.net/1/messages.json 2>&1)
  if echo "$antwoord" | grep -q '"status":1'; then
    echo "   Pushover-melding verstuurd."
  else
    echo "   [!] Pushover-melding mislukt: $antwoord"
  fi
}

main "$@"
