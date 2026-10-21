<?php
declare(strict_types=1);
require __DIR__ . '/../lib.php';

$servers = q("SELECT s.*,
        (SELECT r.id FROM runs r WHERE r.server_id = s.id AND r.status NOT IN ('wachtrij','bezig','geannuleerd') ORDER BY r.id DESC LIMIT 1) AS laatste_run,
        (SELECT r.id FROM runs r WHERE r.server_id = s.id AND r.status IN ('wachtrij','bezig') ORDER BY r.id DESC LIMIT 1) AS open_run,
        (SELECT COUNT(*) FROM runs r WHERE r.server_id = s.id AND r.status IN ('JA','AANDACHT','NEE','FOUT')) AS aantal_runs
    FROM servers s ORDER BY s.naam")->fetchAll();

$runInfo = function (mixed $id): ?array {
    return $id ? q('SELECT * FROM runs WHERE id = ?', [$id])->fetch() : null;
};

$bezig   = (int)q("SELECT COUNT(*) FROM runs WHERE status IN ('wachtrij','bezig')")->fetchColumn();
$recent  = q("SELECT r.*, s.naam FROM runs r JOIN servers s ON s.id = r.server_id ORDER BY r.id DESC LIMIT 15")->fetchAll();
$planning = instelling('planning_tijd');

kop('Servers', $bezig > 0);
?>
<div class="balk">
  <h1>Servers</h1>
  <div class="knoppen">
    <form method="post" action="actie.php"><input type="hidden" name="actie" value="update_alle">
      <button class="primair" <?= $servers ? '' : 'disabled' ?>>Alle servers updaten</button></form>
    <a class="knop" href="server.php">+ Server toevoegen</a>
  </div>
</div>
<p class="sub">
  Automatisch: <?= $planning !== '' ? 'elke dag om <b>' . h($planning) . '</b>' : '<b>uit</b>' ?>
  · <a href="instellingen.php">wijzigen</a>
  <?= $bezig ? " · <b>$bezig run(s) in uitvoering of wachtrij</b> (pagina ververst vanzelf)" : '' ?>
</p>

<?php if (!$servers): ?>
  <p class="leeg">Nog geen servers. <a href="server.php">Voeg de eerste toe.</a></p>
<?php else: ?>
<div class="tabel-wrap"><table>
  <thead><tr><th>Server</th><th>Adres</th><th>Laatste resultaat</th><th>Wanneer</th><th>Pakketten</th><th></th></tr></thead>
  <tbody>
  <?php foreach ($servers as $s):
      $l = $runInfo($s['laatste_run']);
      $o = $runInfo($s['open_run']); ?>
    <tr class="<?= $s['actief'] ? '' : 'inactief' ?>">
      <td><b><?= h($s['naam']) ?></b><?= $s['actief'] ? '' : ' <span class="klein">(uit)</span>' ?>
          <?= $s['opmerking'] ? '<div class="klein">' . h($s['opmerking']) . '</div>' : '' ?></td>
      <td class="mono"><?= h($s['gebruiker']) ?>@<?= h($s['host']) ?><?= $s['poort'] != 22 ? ':' . (int)$s['poort'] : '' ?></td>
      <td>
        <?php if ($o): ?><a href="run.php?id=<?= (int)$o['id'] ?>"><?= badge($o['status']) ?></a>
        <?php elseif ($l): ?><a href="run.php?id=<?= (int)$l['id'] ?>"><?= badge($l['status']) ?></a>
          <?php if ($l['status'] === 'FOUT'): ?><div class="klein"><?= h($l['melding']) ?></div><?php endif; ?>
        <?php else: ?><span class="klein">nog nooit</span><?php endif; ?>
      </td>
      <td><?= $l ? h(date('d-m-Y H:i', strtotime($l['klaar'] ?? $l['aangevraagd']))) : '' ?></td>
      <td><?= $l ? (int)$l['aantal_pakketten'] : '' ?></td>
      <td><div class="acties">
        <form method="post" action="actie.php"><input type="hidden" name="actie" value="update_server">
          <input type="hidden" name="id" value="<?= (int)$s['id'] ?>">
          <button <?= $o ? 'disabled' : '' ?>>Nu updaten</button></form>
        <a class="knop" href="server.php?id=<?= (int)$s['id'] ?>">Bewerken</a>
        <a class="knop" href="geschiedenis.php?server=<?= (int)$s['id'] ?>">Geschiedenis (<?= (int)$s['aantal_runs'] ?>)</a>
      </div></td>
    </tr>
  <?php endforeach; ?>
  </tbody>
</table></div>
<?php endif; ?>

<?php if ($recent): ?>
<h2>Laatste runs</h2>
<div class="tabel-wrap"><table>
  <thead><tr><th>#</th><th>Server</th><th>Status</th><th>Aanleiding</th><th>Gestart</th><th>Duur</th><th>Pakketten</th></tr></thead>
  <tbody>
  <?php foreach ($recent as $r): ?>
    <tr>
      <td><a href="run.php?id=<?= (int)$r['id'] ?>"><?= (int)$r['id'] ?></a></td>
      <td><?= h($r['naam']) ?></td>
      <td><a href="run.php?id=<?= (int)$r['id'] ?>"><?= badge($r['status']) ?></a></td>
      <td><?= h($r['aanleiding']) ?></td>
      <td><?= h($r['gestart'] ? date('d-m H:i', strtotime($r['gestart'])) : '') ?></td>
      <td><?= h(duur($r['gestart'], $r['klaar'])) ?></td>
      <td><?= (int)$r['aantal_pakketten'] ?></td>
    </tr>
  <?php endforeach; ?>
  </tbody>
</table></div>
<?php endif; ?>
<?php voet();
