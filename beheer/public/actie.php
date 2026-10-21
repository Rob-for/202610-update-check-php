<?php
declare(strict_types=1);
require __DIR__ . '/../lib.php';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    terug('index.php');
}
$actie = (string)($_POST['actie'] ?? '');
$id    = (int)($_POST['id'] ?? 0);

switch ($actie) {
    case 'update_alle':
        $n = plan_runs(null, 'knop');
        terug('index.php', "$n server(s) in de wachtrij gezet. De update start binnen een minuut.");

    case 'update_server':
        $n = plan_runs($id, 'knop');
        terug('index.php', $n ? 'In de wachtrij gezet. De update start binnen een minuut.' : 'Deze server staat al in de wachtrij.');

    case 'run_annuleren':
        q("UPDATE runs SET status = 'geannuleerd', klaar = ? WHERE id = ? AND status = 'wachtrij'", [nu(), $id]);
        terug('run.php?id=' . $id, 'Geannuleerd.');

    case 'server_opslaan':
        $naam      = trim((string)($_POST['naam'] ?? ''));
        $host      = trim((string)($_POST['host'] ?? ''));
        $poort     = (int)($_POST['poort'] ?? 22) ?: 22;
        $gebruiker = trim((string)($_POST['gebruiker'] ?? 'root'));
        $ww        = (string)($_POST['wachtwoord'] ?? '');
        $actief    = isset($_POST['actief']) ? 1 : 0;
        $opmerking = trim((string)($_POST['opmerking'] ?? ''));

        if ($naam === '' || $host === '' || $gebruiker === ''
            || !preg_match('/^[A-Za-z0-9.\-:\[\]]+$/', $host) || !preg_match('/^[A-Za-z0-9._\-]+$/', $gebruiker)) {
            terug('server.php' . ($id ? "?id=$id" : ''), 'Controleer naam, host en gebruiker (geen spaties of vreemde tekens).');
        }
        if ($id) {
            q('UPDATE servers SET naam = ?, host = ?, poort = ?, gebruiker = ?, actief = ?, opmerking = ? WHERE id = ?',
                [$naam, $host, $poort, $gebruiker, $actief, $opmerking, $id]);
            if ($ww !== '') {
                q('UPDATE servers SET wachtwoord = ? WHERE id = ?', [versleutel($ww), $id]);
            } elseif (!empty($_POST['wachtwoord_wissen'])) {
                q('UPDATE servers SET wachtwoord = NULL WHERE id = ?', [$id]);
            }
        } else {
            q('INSERT INTO servers (naam, host, poort, gebruiker, wachtwoord, actief, opmerking, aangemaakt)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                [$naam, $host, $poort, $gebruiker, versleutel($ww), $actief, $opmerking, nu()]);
        }
        terug('index.php', "Server '$naam' opgeslagen.");

    case 'server_verwijderen':
        q('DELETE FROM servers WHERE id = ?', [$id]);
        terug('index.php', 'Server verwijderd.');

    case 'instellingen_opslaan':
        $tijd = (string)($_POST['planning_tijd'] ?? '');
        if ($tijd !== '' && !preg_match('/^\d{2}:\d{2}$/', $tijd)) {
            $tijd = '';
        }
        if ($tijd !== instelling('planning_tijd')) {
            zet_instelling('planning_tijd', $tijd);
            // Niet direct alsnog vandaag draaien als de tijd al voorbij is
            zet_instelling('planning_laatst', date('H:i') >= $tijd ? date('Y-m-d') : '');
        }
        zet_instelling('pushover_user', trim((string)($_POST['pushover_user'] ?? '')));
        if (($_POST['pushover_token'] ?? '') !== '') {
            zet_instelling('pushover_token', trim((string)$_POST['pushover_token']));
        }
        zet_instelling('pushover_prioriteit', (string)(int)($_POST['pushover_prioriteit'] ?? -1));
        zet_instelling('pushover_wanneer', ($_POST['pushover_wanneer'] ?? '') === 'problemen' ? 'problemen' : 'altijd');
        terug('instellingen.php', 'Instellingen opgeslagen.');

    case 'test_push':
        [$ok, $antw] = pushover('Updatebeheer: test', 'Als je dit ziet, werkt Pushover.');
        terug('instellingen.php', $ok ? 'Testmelding verstuurd.' : "Testmelding mislukt: $antw");

    default:
        terug('index.php');
}
