<?php
// lib.php – gedeelde functies voor Updatebeheer (web + runner)
declare(strict_types=1);

const CONFIG_BESTAND = '/etc/updatebeheer/config.php';
const SCRIPT_URL     = 'https://raw.githubusercontent.com/Rob-for/202610-update-check-php/main/update-check.sh';
const RUN_TIMEOUT    = 3600;   // max. seconden per server

$CONFIG = require CONFIG_BESTAND;
date_default_timezone_set($CONFIG['tijdzone'] ?? 'Europe/Amsterdam');

const STATUS_LABEL = [
    'wachtrij'     => 'In wachtrij',
    'bezig'        => 'Bezig…',
    'JA'           => 'JA',
    'AANDACHT'     => 'JA, met aandachtspunten',
    'NEE'          => 'NEE',
    'FOUT'         => 'Fout',
    'geannuleerd'  => 'Geannuleerd',
];

// ---------------------------------------------------------------- database
function db(): PDO
{
    static $pdo = null;
    global $CONFIG;
    if ($pdo === null) {
        $dsn = sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',
            $CONFIG['db_host'], (int)($CONFIG['db_poort'] ?? 3306), $CONFIG['db_naam']);
        $pdo = new PDO($dsn, $CONFIG['db_gebruiker'], $CONFIG['db_wachtwoord'], [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_TIMEOUT            => 5,
        ]);
    }
    return $pdo;
}

function q(string $sql, array $args = []): PDOStatement
{
    $st = db()->prepare($sql);
    $st->execute($args);
    return $st;
}

function nu(): string
{
    return date('Y-m-d H:i:s');
}

function migreer(): void
{
    db()->exec("CREATE TABLE IF NOT EXISTS servers (
        id          INT AUTO_INCREMENT PRIMARY KEY,
        naam        VARCHAR(100) NOT NULL,
        host        VARCHAR(255) NOT NULL,
        poort       INT NOT NULL DEFAULT 22,
        gebruiker   VARCHAR(64)  NOT NULL DEFAULT 'root',
        wachtwoord  TEXT NULL,
        actief      TINYINT(1) NOT NULL DEFAULT 1,
        opmerking   TEXT NULL,
        aangemaakt  DATETIME NOT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");

    db()->exec("CREATE TABLE IF NOT EXISTS runs (
        id               INT AUTO_INCREMENT PRIMARY KEY,
        server_id        INT NOT NULL,
        aanleiding       VARCHAR(20) NOT NULL,
        status           VARCHAR(20) NOT NULL,
        aangevraagd      DATETIME NOT NULL,
        gestart          DATETIME NULL,
        klaar            DATETIME NULL,
        exitcode         INT NULL,
        melding          VARCHAR(255) NULL,
        samenvatting     TEXT NULL,
        uitvoer          MEDIUMTEXT NULL,
        aantal_pakketten INT NOT NULL DEFAULT 0,
        INDEX idx_server (server_id, id),
        INDEX idx_status (status),
        CONSTRAINT fk_runs_server FOREIGN KEY (server_id) REFERENCES servers(id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");

    db()->exec("CREATE TABLE IF NOT EXISTS pakketten (
        id             INT AUTO_INCREMENT PRIMARY KEY,
        run_id         INT NOT NULL,
        pakket         VARCHAR(255) NOT NULL,
        actie          VARCHAR(20) NOT NULL,
        oude_versie    VARCHAR(255) NULL,
        nieuwe_versie  VARCHAR(255) NULL,
        INDEX idx_pakket (pakket),
        INDEX idx_run (run_id),
        CONSTRAINT fk_pakketten_run FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");

    db()->exec("CREATE TABLE IF NOT EXISTS instellingen (
        sleutel VARCHAR(64) PRIMARY KEY,
        waarde  TEXT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");
}

// ---------------------------------------------------------------- instellingen
function instelling(string $sleutel, string $standaard = ''): string
{
    $w = q('SELECT waarde FROM instellingen WHERE sleutel = ?', [$sleutel])->fetchColumn();
    return ($w === false || $w === null) ? $standaard : (string)$w;
}

function zet_instelling(string $sleutel, string $waarde): void
{
    q('INSERT INTO instellingen (sleutel, waarde) VALUES (?, ?)
       ON DUPLICATE KEY UPDATE waarde = VALUES(waarde)', [$sleutel, $waarde]);
}

// ---------------------------------------------------------------- versleuteling
function sleutel(): string
{
    global $CONFIG;
    return base64_decode($CONFIG['sleutel']);
}

function versleutel(string $tekst): ?string
{
    if ($tekst === '') {
        return null;
    }
    $iv  = random_bytes(12);
    $tag = '';
    $c   = openssl_encrypt($tekst, 'aes-256-gcm', sleutel(), OPENSSL_RAW_DATA, $iv, $tag);
    return base64_encode($iv . $tag . $c);
}

function ontsleutel(?string $data): string
{
    if ($data === null || $data === '') {
        return '';
    }
    $r = base64_decode($data);
    $p = openssl_decrypt(substr($r, 28), 'aes-256-gcm', sleutel(), OPENSSL_RAW_DATA,
        substr($r, 0, 12), substr($r, 12, 16));
    return $p === false ? '' : $p;
}

// ---------------------------------------------------------------- runs
/** Zet runs in de wachtrij voor één server (id) of alle actieve servers (null). */
function plan_runs(?int $serverId, string $aanleiding): int
{
    $sql  = 'SELECT id FROM servers WHERE actief = 1';
    $args = [];
    if ($serverId !== null) {
        $sql  = 'SELECT id FROM servers WHERE id = ?';
        $args = [$serverId];
    }
    $n = 0;
    foreach (q($sql, $args)->fetchAll() as $s) {
        $open = q("SELECT COUNT(*) FROM runs WHERE server_id = ? AND status IN ('wachtrij','bezig')", [$s['id']])
            ->fetchColumn();
        if ((int)$open === 0) {
            q("INSERT INTO runs (server_id, aanleiding, status, aangevraagd) VALUES (?, ?, 'wachtrij', ?)",
                [$s['id'], $aanleiding, nu()]);
            $n++;
        }
    }
    return $n;
}

// ---------------------------------------------------------------- pushover
/** @return array{0: bool, 1: string} */
function pushover(string $titel, string $tekst): array
{
    $user  = instelling('pushover_user');
    $token = instelling('pushover_token');
    if ($user === '' || $token === '') {
        return [false, 'Geen Pushover-sleutels ingesteld'];
    }
    $ctx = stream_context_create(['http' => [
        'method'        => 'POST',
        'header'        => 'Content-Type: application/x-www-form-urlencoded',
        'content'       => http_build_query([
            'token'    => $token,
            'user'     => $user,
            'title'    => mb_substr($titel, 0, 250),
            'message'  => mb_substr($tekst, 0, 1000),
            'priority' => instelling('pushover_prioriteit', '-1'),
        ]),
        'timeout'       => 20,
        'ignore_errors' => true,
    ]]);
    $antwoord = @file_get_contents('https://api.pushover.net/1/messages.json', false, $ctx);
    if ($antwoord === false) {
        return [false, 'Pushover niet bereikbaar'];
    }
    $json = json_decode($antwoord, true);
    if (($json['status'] ?? 0) == 1) {
        return [true, 'Verstuurd'];
    }
    return [false, implode('; ', $json['errors'] ?? [$antwoord])];
}

// ---------------------------------------------------------------- web-hulpjes
function h(mixed $s): string
{
    return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8');
}

function badge(string $status): string
{
    $klasse = strtolower($status);
    return '<span class="badge ' . h($klasse) . '">' . h(STATUS_LABEL[$status] ?? $status) . '</span>';
}

function duur(?string $van, ?string $tot): string
{
    if (!$van || !$tot) {
        return '';
    }
    $s = strtotime($tot) - strtotime($van);
    return $s < 60 ? "{$s} s" : floor($s / 60) . ' min ' . ($s % 60) . ' s';
}

function kop(string $titel, bool $verversen = false): void
{
    $msg = $_GET['msg'] ?? '';
    echo '<!doctype html><html lang="nl"><head><meta charset="utf-8">';
    echo '<meta name="viewport" content="width=device-width, initial-scale=1">';
    if ($verversen) {
        echo '<meta http-equiv="refresh" content="10">';
    }
    echo '<title>' . h($titel) . ' – Updatebeheer</title><link rel="stylesheet" href="stijl.css"></head><body>';
    echo '<header><a class="logo" href="index.php">Updatebeheer</a><nav>';
    echo '<a href="index.php">Servers</a><a href="geschiedenis.php">Geschiedenis</a>';
    echo '<a href="pakketten.php">Pakketten</a><a href="instellingen.php">Instellingen</a></nav></header><main>';
    if ($msg !== '') {
        echo '<div class="melding">' . h($msg) . '</div>';
    }
}

function voet(): void
{
    echo '</main></body></html>';
}

function terug(string $url, string $msg = ''): never
{
    if ($msg !== '') {
        $url .= (str_contains($url, '?') ? '&' : '?') . 'msg=' . urlencode($msg);
    }
    header('Location: ' . $url);
    exit;
}
