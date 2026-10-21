<?php
declare(strict_types=1);
require __DIR__ . '/../lib.php';

$server = (int)($_GET['server'] ?? 0);
$status = (string)($_GET['status'] ?? '');
$pagina = max(1, (int)($_GET['p'] ?? 1));
$per    = 50;

$waar = [];
$args = [];
if ($server) { $waar[] = 'r.server_id = ?'; $args[] = $server; }
if ($status !== '' && isset(STATUS_LABEL[$status])) { $waar[] = 'r.status = ?'; $args[] = $status; }
$where = $waar ? 'WHERE ' . implode(' AND ', $waar) : '';

$totaal = (int)q("SELECT COUNT(*) FROM runs r $where", $args)->fetchColumn();
$runs   = q("SELECT r.*, s.naam FROM runs r JOIN servers s ON s.id = r.server_id $where
             ORDER BY r.id DESC LIMIT $per OFFSET " . (($pagina - 1) * $per), $args)->fetchAll();
$servers = q('SELECT id, naam FROM servers ORDER BY naam')->fetchAll();

// Statistiek per server (laatste 90 dagen)
$stats = q("SELECT s.naam, COUNT(r.id) AS runs,
                   SUM(r.status IN ('JA','AANDACHT')) AS ok,
                   SUM(r.status IN ('NEE','FOUT')) AS fout,
                   COALESCE(SUM(r.aantal_pakketten),0) AS pakketten,
                   MAX(r.klaar) AS laatst
            FROM servers s LEFT JOIN runs r ON r.server_id = s.id AND r.aangevraagd >= ?
                 AND r.status IN ('JA','AANDACHT','NEE','FOUT')
            GROUP BY s.id ORDER BY s.naam", [date('Y-m-d', strtotime('-90 days'))])->fetchAll();

kop('Geschiedenis');
?>
<h1>Geschiedenis</h1>

<h2>Laatste 90 dagen</h2>
<div class="tabel-wrap"><table>
  <thead><tr><th>Server</th><th>Runs</th><th>Goed</th><th>Fout/NEE</th><th>Pakketten bijgewerkt</th><th>Laatste run</th></tr></thead>
  <tbody>
  <?php foreach ($stats as $st): ?>
    <tr><td><?= h($st['naam']) ?></td><td><?= (int)$st['runs'] ?></td><td><?= (int)$st['ok'] ?></td>
        <td class="<?= $st['fout'] ? 'rood-tekst' : '' ?>"><?= (int)$st['fout'] ?></td>
        <td><?= (int)$st['pakketten'] ?></td>
        <td><?= $st['laatst'] ? h(date('d-m-Y H:i', strtotime($st['laatst']))) : '' ?></td></tr>
  <?php endforeach; ?>
  </tbody>
</table></div>

<h2>Alle runs</h2>
<form method="get" class="filter">
  <select name="server"><option value="">Alle servers</option>
    <?php foreach ($servers as $s): ?>
      <option value="<?= (int)$s['id'] ?>" <?= $server === (int)$s['id'] ? 'selected' : '' ?>><?= h($s['naam']) ?></option>
    <?php endforeach; ?>
  </select>
  <select name="status"><option value="">Alle statussen</option>
    <?php foreach (STATUS_LABEL as $k => $v): ?>
      <option value="<?= h($k) ?>" <?= $status === $k ? 'selected' : '' ?>><?= h($v) ?></option>
    <?php endforeach; ?>
  </select>
  <button>Filteren</button>
</form>

<div class="tabel-wrap"><table>
  <thead><tr><th>#</th><th>Server</th><th>Status</th><th>Melding</th><th>Aanleiding</th><th>Gestart</th><th>Duur</th><th>Pakketten</th></tr></thead>
  <tbody>
  <?php foreach ($runs as $r): ?>
    <tr>
      <td><a href="run.php?id=<?= (int)$r['id'] ?>"><?= (int)$r['id'] ?></a></td>
      <td><?= h($r['naam']) ?></td>
      <td><a href="run.php?id=<?= (int)$r['id'] ?>"><?= badge($r['status']) ?></a></td>
      <td class="klein"><?= h($r['status'] === 'FOUT' ? $r['melding'] : str_replace("\n", ' · ', (string)$r['samenvatting'])) ?></td>
      <td><?= h($r['aanleiding']) ?></td>
      <td><?= h($r['gestart'] ? date('d-m-Y H:i', strtotime($r['gestart'])) : '') ?></td>
      <td><?= h(duur($r['gestart'], $r['klaar'])) ?></td>
      <td><?= (int)$r['aantal_pakketten'] ?></td>
    </tr>
  <?php endforeach; ?>
  <?php if (!$runs): ?><tr><td colspan="8" class="leeg">Geen runs gevonden.</td></tr><?php endif; ?>
  </tbody>
</table></div>

<?php if ($totaal > $per):
    $qs = fn(int $p) => '?' . http_build_query(['server' => $server ?: null, 'status' => $status ?: null, 'p' => $p]); ?>
  <p class="paginas">
    <?php if ($pagina > 1): ?><a href="<?= h($qs($pagina - 1)) ?>">« Nieuwer</a><?php endif; ?>
    Pagina <?= $pagina ?> van <?= (int)ceil($totaal / $per) ?>
    <?php if ($pagina * $per < $totaal): ?><a href="<?= h($qs($pagina + 1)) ?>">Ouder »</a><?php endif; ?>
  </p>
<?php endif; ?>
<?php voet();
