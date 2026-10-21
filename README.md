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

| Melding | Betekenis | Exitcode |
|---|---|---|
| `JA` | Alles bijgewerkt en in orde | 0 |
| `JA, met aandachtspunten` | Bijgewerkt, maar kijk naar de `[!]`-regels | 2 |
| `NEE` | Er is iets mis, zie de `[X]`-regels | 1 |
