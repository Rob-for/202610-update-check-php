<?php
declare(strict_types=1);
require __DIR__ . '/../lib.php';

$zoek = trim((string)($_GET['zoek'] ?? ''));
$args = [];
$where = '';
if ($zoek !== '') {
    $where = 'WHERE p.pakket LIKE ?';
    $args[] = '%' . $zoek . '%';
}
$rijen = q("SELECT p.*, r.klaar, r.id AS run_id, s.naam
            FROM pakketten p JOIN runs r ON r.id = p.run_id JOIN servers s ON s.id = r.server_id
            $where ORDER BY r.id DESC, p.pakket LIMIT 300", $args)->fetchAll();

kop('Pakketten');
?>
<h1>Pakketgeschiedenis</h1>
<p class="sub">Welk pakket is wanneer, op welke server, naar welke versie gegaan? Bijvoorbeeld: zoek op <i>php</i> of <i>openssl</i>.</p>
<form method="get" class="filter">
  <input name="zoek" value="<?= h($zoek) ?>" placeholder="pakketnaam…" autofocus>
  <button>Zoeken</button>
</form>
<div class="tabel-wrap"><table>
  <thead><tr><th>Wanneer</th><th>Server</th><th>Pakket</th><th>Actie</th><th>Oud</th><th>Nieuw</th></tr></thead>
  <tbody>
  <?php foreach ($rijen as $p): ?>
    <tr>
      <td><a href="run.php?id=<?= (int)$p['run_id'] ?>"><?= h($p['klaar'] ? date('d-m-Y H:i', strtotime($p['klaar'])) : '') ?></a></td>
      <td><?= h($p['naam']) ?></td>
      <td class="mono"><?= h($p['pakket']) ?></td>
      <td><?= h($p['actie']) ?></td>
      <td class="mono"><?= h($p['oude_versie']) ?></td>
      <td class="mono"><?= h($p['nieuwe_versie']) ?></td>
    </tr>
  <?php endforeach; ?>
  <?php if (!$rijen): ?><tr><td colspan="6" class="leeg">Niets gevonden.</td></tr><?php endif; ?>
  </tbody>
</table></div>
<?php voet();
