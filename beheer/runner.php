<?php
// runner.php – voert de update-runs uit. Draait elke minuut via cron als root.
//   php runner.php              wachtrij + planning verwerken
//   php runner.php --migreer    alleen database-tabellen aanmaken/bijwerken
//   php runner.php --importeer  /root/servers.txt en /etc/update-check.conf inlezen (eenmalig)
declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    exit("Alleen via de commandline.\n");
}
require __DIR__ . '/lib.php';

$optie = $argv[1] ?? '';

if ($optie === '--migreer') {
    migreer();
    echo "Database OK.\n";
    exit(0);
}

if ($optie === '--importeer') {
    migreer();
    importeer();
    exit(0);
}

// Maar één runner tegelijk
$lock = fopen('/run/updatebeheer.lock', 'c');
if (!$lock || !flock($lock, LOCK_EX | LOCK_NB)) {
    exit(0);
}

migreer();

// Runs die 'bezig' bleven staan (runner gecrasht, LXC herstart) afsluiten
q("UPDATE runs SET status = 'FOUT', melding = 'Afgebroken (runner gestopt)', klaar = ? WHERE status = 'bezig'", [nu()]);

// Automatische planning (dagelijks op ingestelde tijd)
$tijd = instelling('planning_tijd');
if ($tijd !== '' && date('H:i') >= $tijd && instelling('planning_laatst') !== date('Y-m-d')) {
    zet_instelling('planning_laatst', date('Y-m-d'));
    $n = plan_runs(null, 'planning');
    logregel("Planning $tijd: $n server(s) in de wachtrij gezet");
}

// Wachtrij afwerken, één server tegelijk
while (true) {
    $run = q("SELECT r.id AS run_id, s.* FROM runs r JOIN servers s ON s.id = r.server_id
              WHERE r.status = 'wachtrij' ORDER BY r.id LIMIT 1")->fetch();
    if (!$run) {
        break;
    }
    voer_uit($run);
}
exit(0);

// =====================================================================

function logregel(string $tekst): void
{
    echo '[' . nu() . "] $tekst\n";
}

function voer_uit(array $s): void
{
    $runId = (int)$s['run_id'];
    q("UPDATE runs SET status = 'bezig', gestart = ? WHERE id = ?", [nu(), $runId]);
    logregel("Start run $runId: {$s['naam']} ({$s['gebruiker']}@{$s['host']}:{$s['poort']})");

    $ww = ontsleutel($s['wachtwoord']);

    // Commando op de server. LC_ALL=C zodat apt Engelse uitvoer geeft (nodig om pakketten te herkennen).
    $remote = "env LC_ALL=C GEEN_PUSH=1 bash -o pipefail -c "
            . "'(curl -fsSL " . SCRIPT_URL . " 2>/dev/null || wget -qO- " . SCRIPT_URL . ") | bash'";
    if ($s['gebruiker'] !== 'root') {
        $remote = "sudo -S -p '' " . $remote;
    }

    $sshOpts = ['-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=accept-new',
                '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=20',
                '-p', (string)$s['poort'], $s['gebruiker'] . '@' . $s['host'], $remote];
    $env = ['PATH' => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', 'HOME' => '/root'];

    if ($ww !== '') {
        $cmd = array_merge(['sshpass', '-e', 'ssh'], $sshOpts);
        $env['SSHPASS'] = $ww;
    } else {
        $cmd = array_merge(['ssh', '-o', 'BatchMode=yes'], $sshOpts);
    }

    $proc = proc_open($cmd, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['redirect', 1]], $pipes, null, $env);
    if (!is_resource($proc)) {
        afronden($runId, $s, 'FOUT', -1, 'Kon ssh niet starten', '');
        return;
    }
    if ($ww !== '') {
        fwrite($pipes[0], $ww . "\n");   // voor sudo -S
    }
    fclose($pipes[0]);
    stream_set_blocking($pipes[1], false);

    $uit = '';
    $start = $laatsteOpslag = time();
    $timeout = false;
    while (true) {
        $r = [$pipes[1]];
        $w = $e = null;
        if (@stream_select($r, $w, $e, 5) > 0) {
            $stuk = fread($pipes[1], 65536);
            if ($stuk === false || $stuk === '') {
                if (feof($pipes[1])) {
                    break;
                }
            } else {
                $uit .= $stuk;
            }
        }
        if (time() - $laatsteOpslag >= 5) {      // live meekijken in de webpagina
            q('UPDATE runs SET uitvoer = ? WHERE id = ?', [schoon($uit), $runId]);
            $laatsteOpslag = time();
        }
        if (time() - $start > RUN_TIMEOUT) {
            proc_terminate($proc);
            $uit .= "\n[Afgebroken: duurde langer dan " . (RUN_TIMEOUT / 60) . " minuten]\n";
            $timeout = true;
            break;
        }
    }
    fclose($pipes[1]);
    $rc  = proc_close($proc);
    $uit = schoon($uit);

    // Status bepalen
    if (str_contains($uit, 'Alles OK?') && !$timeout) {
        $status  = match ($rc) { 0 => 'JA', 2 => 'AANDACHT', default => 'NEE' };
        $melding = STATUS_LABEL[$status];
    } else {
        $status = 'FOUT';
        if ($timeout) {
            $melding = 'Timeout';
        } elseif ($rc === 5) {
            $melding = 'Inloggen mislukt (verkeerd wachtwoord?)';
        } elseif ($rc === 255) {
            $melding = 'Niet bereikbaar / SSH-fout';
        } elseif (preg_match('/sudo:.*(password|wachtwoord)|incorrect password|no tty|not in the sudoers/i', $uit)) {
            $melding = 'Sudo mislukt (wachtwoord nodig of geen sudo-rechten)';
        } else {
            $melding = "Fout (code $rc)";
        }
    }
    afronden($runId, $s, $status, $rc, $melding, $uit);
}

function afronden(int $runId, array $s, string $status, int $rc, string $melding, string $uit): void
{
    // Aandachtspunten uit het resultaatblok
    preg_match_all('/^\s+(\[(?:X|!|i)\].*)$/m', $uit, $m);
    $samenvatting = implode("\n", array_map('trim', $m[1]));

    $pakketten = pakketten_uit_log($uit);

    q('UPDATE runs SET status = ?, klaar = ?, exitcode = ?, melding = ?, samenvatting = ?, uitvoer = ?,
              aantal_pakketten = ? WHERE id = ?',
        [$status, nu(), $rc, mb_substr($melding, 0, 255), $samenvatting, $uit, count($pakketten), $runId]);
    $ins = db()->prepare('INSERT INTO pakketten (run_id, pakket, actie, oude_versie, nieuwe_versie) VALUES (?, ?, ?, ?, ?)');
    foreach ($pakketten as $p) {
        $ins->execute([$runId, $p[0], $p[1], $p[2], $p[3]]);
    }
    logregel("Klaar run $runId: {$s['naam']} = $status ($melding), " . count($pakketten) . ' pakket(ten)');

    // Pushover per server
    $altijd = instelling('pushover_wanneer', 'altijd') === 'altijd';
    if ($altijd || $status !== 'JA') {
        $tekst = $samenvatting !== '' ? $samenvatting : 'Geen bijzonderheden.';
        if ($status === 'FOUT') {
            $tekst = $melding;
        }
        $tekst .= "\n" . count($pakketten) . ' pakket(ten) bijgewerkt.';
        [$ok, $antw] = pushover($s['naam'] . ': ' . (STATUS_LABEL[$status] ?? $status), $tekst);
        if (!$ok && $antw !== 'Geen Pushover-sleutels ingesteld') {
            logregel("Pushover mislukt: $antw");
        }
    }
}

/** Uitvoer opschonen: voortgangsregels, kleurcodes en ongeldige UTF-8 eruit. */
function schoon(string $t): string
{
    $t = str_replace("\r", "\n", $t);
    $t = preg_replace('/\x1b\[[0-9;?]*[A-Za-z]/', '', $t) ?? $t;
    $t = preg_replace("/\n{3,}/", "\n\n", $t) ?? $t;
    return mb_convert_encoding($t, 'UTF-8', 'UTF-8');
}

/** @return list<array{0:string,1:string,2:?string,3:?string}> pakket, actie, oud, nieuw */
function pakketten_uit_log(string $uit): array
{
    $lijst = [];
    // apt (Debian/Ubuntu)
    preg_match_all('/^Unpacking ([^\s:]+)(?::\S+)? \((\S+)\)( over \((\S+)\))?/m', $uit, $m, PREG_SET_ORDER);
    foreach ($m as $x) {
        $over = isset($x[4]) && $x[4] !== '';
        $lijst[$x[1]] = [$x[1], $over ? 'bijgewerkt' : 'nieuw', $over ? $x[4] : null, $x[2]];
    }
    preg_match_all('/^Removing ([^\s:]+)(?::\S+)? \((\S+)\)/m', $uit, $m, PREG_SET_ORDER);
    foreach ($m as $x) {
        $lijst[$x[1] . '#weg'] = [$x[1], 'verwijderd', $x[2], null];
    }
    // dnf (Fedora/RHEL)
    foreach (['Upgrading' => 'bijgewerkt', 'Installing' => 'nieuw', 'Erasing' => 'verwijderd'] as $woord => $actie) {
        preg_match_all('/^\s+' . $woord . '\s+:\s+(\S+)/m', $uit, $m);
        foreach ($m[1] as $p) {
            $lijst[$p . '#' . $actie] = [$p, $actie, null, null];
        }
    }
    return array_values($lijst);
}

function importeer(): void
{
    // Pushover-sleutels uit de oude configuratie
    if (is_readable('/etc/update-check.conf') && instelling('pushover_user') === '') {
        $conf = parse_ini_string(str_replace("'", '', file_get_contents('/etc/update-check.conf')));
        if (!empty($conf['PUSHOVER_USER'])) {
            zet_instelling('pushover_user', $conf['PUSHOVER_USER']);
            zet_instelling('pushover_token', $conf['PUSHOVER_TOKEN'] ?? '');
            zet_instelling('pushover_prioriteit', $conf['PUSHOVER_PRIORITY'] ?? '-1');
            echo "Pushover-sleutels overgenomen uit /etc/update-check.conf\n";
        }
    }
    // Servers uit de oude serverlijst (alleen als de database nog leeg is)
    $bestand = '/root/servers.txt';
    if (is_readable($bestand) && (int)q('SELECT COUNT(*) FROM servers')->fetchColumn() === 0) {
        $n = 0;
        foreach (file($bestand) as $regel) {
            $regel = trim($regel);
            if ($regel === '' || $regel[0] === '#') {
                continue;
            }
            $d = preg_split('/\s+/', $regel);
            [$host, $poort] = array_pad(explode(':', $d[0], 2), 2, '22');
            q('INSERT INTO servers (naam, host, poort, gebruiker, wachtwoord, actief, aangemaakt) VALUES (?, ?, ?, ?, ?, 1, ?)',
                [$host, $host, (int)$poort, $d[1] ?? 'root', versleutel($d[2] ?? ''), nu()]);
            $n++;
        }
        echo "$n server(s) overgenomen uit $bestand\n";
    }
}
