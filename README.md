# update-check

Werkt een Linux-server volledig bij en geeft daarna een duidelijk **JA** of **NEE**, ook als Pushover-melding.

## Gebruik

Eerste keer per server, met je Pushover-sleutels:

```bash
curl -fsSL https://raw.githubusercontent.com/Rob-for/202610-update-check-php/main/update-check.sh | PUSHOVER_USER=<user-key> PUSHOVER_TOKEN=<api-token> bash
```

De sleutels worden op de server bewaard in `/etc/update-check.conf` (alleen leesbaar voor root). Daarna is dit genoeg:

```bash
curl -fsSL https://raw.githubusercontent.com/Rob-for/202610-update-check-php/main/update-check.sh | bash
```

Zet de sleutels **nooit** in deze publieke repository.

## Wat het doet

1. Werkt alle pakketten bij (`apt` of `dnf`). Gewijzigde configbestanden blijven behouden.
2. Controleert of er niets is blijven hangen.
3. Herstart diensten die nog oude, mogelijk kwetsbare code in het geheugen hebben (via `needrestart`, dat het script zo nodig installeert). Denk aan PHP-FPM, Apache of nginx.
4. Meldt of de server zelf herstart moet worden, of er services mislukt zijn en of de schijf bijna vol is.
5. Stuurt het resultaat via Pushover (standaard prioriteit -1, een stille melding).

Het script herstart de server **nooit** zelf en werkt Docker-images niet bij. Alles wordt gelogd in `/var/log/update-check.log`.

## Alle servers in één keer (update-alle.sh)

Op een beheer-LXC (Debian/Ubuntu, als root):

1. Zet je servers in `/root/servers.txt` (zie `servers.txt.voorbeeld`).
2. Eerste keer, met Pushover:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/Rob-for/202610-update-check-php/main/update-alle.sh | PUSHOVER_USER=<user-key> PUSHOVER_TOKEN=<api-token> bash
   ```
3. Daarna:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/Rob-for/202610-update-check-php/main/update-alle.sh | bash
   ```

Het script logt via SSH in op elke server, draait daar `update-check.sh` en stuurt per server een Pushover-melding met het resultaat. Volledige logs per server staan in `/var/log/update-alle/`.

Aanrader: rol eenmalig SSH-sleutels uit met `… | bash -s sleutels`. Daarna kunnen wachtwoorden van root-gebruikers uit de lijst.

## Webpagina: Updatebeheer (map `beheer/`)

Servers beheren, updates starten en de volledige geschiedenis bekijken via de browser. De gegevens staan in MySQL/MariaDB.

1. Maak eenmalig de database aan op je MySQL-server met `beheer/database.sql` (kies daar een eigen wachtwoord).
2. Installeer op de beheer-LXC (Debian/Ubuntu, als root):
   ```bash
   apt update && apt install -y curl
   curl -fsSL https://raw.githubusercontent.com/Rob-for/202610-update-check-php/main/beheer/installeer.sh | DB_HOST=<mysql-server> DB_WACHTWOORD='<wachtwoord>' bash
   ```
3. Open `http://<ip-van-de-lxc>/`. De pagina is alleen bereikbaar vanaf het lokale netwerk.

Bijwerken naar een nieuwe versie: hetzelfde commando zonder `DB_…`. Bestaande `/root/servers.txt` en Pushover-sleutels worden bij de eerste installatie overgenomen.

## Uitkomst

| Melding | Betekenis | Exitcode |
|---|---|---|
| `JA` | Alles bijgewerkt en in orde | 0 |
| `JA, met aandachtspunten` | Bijgewerkt, maar kijk naar de `[!]`-regels | 2 |
| `NEE` | Er is iets mis, zie de `[X]`-regels | 1 |
