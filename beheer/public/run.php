<?php
declare(strict_types=1);
require __DIR__ . '/../lib.php';

$id = (int)($_GET['id'] ?? 0);
$r  = q('SELECT r.*, s.naam, s.host FROM runs r JOIN servers s ON s.id = r.server_id WHERE r.id = ?', [$id])->fetch();
if (!$r) {
    terug('index.php', 'Run niet gevonden');
}
$pakketten = q('SELECT * FROM pakketten WHERE run_id = ? ORDER BY actie, pakket', [$id])->fetchAll();
$open = in_array($r['status'], ['wachtrij', 'bezig'], true);

kop('Run ' . $id, $open);
?>
<div class="balk">
  <h1>Run #<?= (int)$r['id'] ?> – <?= h($r['naam']) ?></h1>
  <?php if ($r['status'] === 'wachtrij'): ?>
    <form method="post" action="actie.php"><input type="hidden" name="actie" value="run_annuleren">
      <input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><button>Annuleren</button></form>
  <?php endif; ?>
</div>

<dl class="info">
  <dt>Status</dt><dd><?= badge($r['status']) ?> <?= $r['melding'] && $r['status'] === 'FOUT' ? h($r['melding']) : '' ?></dd>
  <dt>Server</dt><dd><?= h($r['naam']) ?> <span class="klein mono"><?= h($r['host']) ?></span></dd>
  <dt>Aanleiding</dt><dd><?= h($r['aanleiding']) ?></dd>
  <dt>Aangevraagd</dt><dd><?= h($r['aangevraagd']) ?></dd>
  <dt>Gestart</dt><dd><?= h($r['gestart']) ?></dd>
  <dt>Klaar</dt><dd><?= h($r['klaar']) ?> <?= $r['klaar'] ? '(' . h(duur($r['gestart'], $r['klaar'])) . ')' : '' ?></dd>
  <?php if ($r['exitcode'] !== null): ?><dt>Exitcode</dt><dd><?= (int)$r['exitcode'] ?></dd><?php endif; ?>
</dl>

<?php if ($r['samenvatting']): ?>
  <h2>Aandachtspunten</h2>
  <pre class="samenvatting"><?= h($r['samenvatting']) ?></pre>
<?php endif; ?>

<h2>Pakketten (<?= count($pakketten) ?>)</h2>
<?php if ($pakketten): ?>
<div class="tabel-wrap"><table>
  <thead><tr><th>Pakket</th><th>Actie</th><th>Oude versie</th><th>Nieuwe versie</th></tr></thead>
  <tbody>
  <?php foreach ($pakketten as $p): ?>
    <tr><td class="mono"><a href="pakketten.php?zoek=<?= urlencode($p['pakket']) ?>"><?= h($p['pakket']) ?></a></td>
        <td><?= h($p['actie']) ?></td><td class="mono"><?= h($p['oude_versie']) ?></td>
        <td class="mono"><?= h($p['nieuwe_versie']) ?></td></tr>
  <?php endforeach; ?>
  </tbody>
</table></div>
<?php else: ?>
  <p class="klein"><?= $open ? 'Nog bezig…' : 'Geen pakketten gewijzigd.' ?></p>
<?php endif; ?>

<h2>Volledige uitvoer</h2>
<pre class="log"><?= h($r['uitvoer'] ?: ($open ? 'Wachten op uitvoer…' : '(leeg)')) ?></pre>
<?php voet();
