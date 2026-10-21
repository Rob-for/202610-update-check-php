<?php
declare(strict_types=1);
require __DIR__ . '/../lib.php';

$id = (int)($_GET['id'] ?? 0);
$s  = $id ? q('SELECT * FROM servers WHERE id = ?', [$id])->fetch() : null;
if ($id && !$s) {
    terug('index.php', 'Server niet gevonden');
}
$s = $s ?: ['id' => 0, 'naam' => '', 'host' => '', 'poort' => 22, 'gebruiker' => 'root',
            'wachtwoord' => null, 'actief' => 1, 'opmerking' => ''];

kop($id ? 'Server bewerken' : 'Server toevoegen');
?>
<h1><?= $id ? 'Server bewerken: ' . h($s['naam']) : 'Server toevoegen' ?></h1>
<form method="post" action="actie.php" class="formulier">
  <input type="hidden" name="actie" value="server_opslaan">
  <input type="hidden" name="id" value="<?= (int)$s['id'] ?>">

  <label>Naam <input name="naam" required value="<?= h($s['naam']) ?>" placeholder="bijv. immich"></label>
  <label>Host (IP of DNS-naam) <input name="host" required value="<?= h($s['host']) ?>" placeholder="192.168.1.52"></label>
  <label>SSH-poort <input name="poort" type="number" min="1" max="65535" value="<?= (int)$s['poort'] ?>"></label>
  <label>Gebruiker <input name="gebruiker" required value="<?= h($s['gebruiker']) ?>"></label>
  <label>Wachtwoord
    <input name="wachtwoord" type="password" autocomplete="new-password"
           placeholder="<?= $s['wachtwoord'] ? '•••••• (leeg laten = ongewijzigd)' : 'leeg = inloggen met SSH-sleutel' ?>">
    <span class="klein">Wordt versleuteld opgeslagen. Is de gebruiker geen root, dan wordt het ook voor sudo gebruikt.</span>
  </label>
  <?php if ($s['wachtwoord']): ?>
    <label class="check"><input type="checkbox" name="wachtwoord_wissen" value="1"> Opgeslagen wachtwoord wissen</label>
  <?php endif; ?>
  <label>Opmerking <input name="opmerking" value="<?= h($s['opmerking']) ?>" placeholder="optioneel"></label>
  <label class="check"><input type="checkbox" name="actief" value="1" <?= $s['actief'] ? 'checked' : '' ?>>
    Actief (meenemen bij 'Alle servers' en de automatische planning)</label>

  <div class="knoppen">
    <button class="primair">Opslaan</button>
    <a class="knop" href="index.php">Annuleren</a>
  </div>
</form>

<?php if ($id): ?>
<form method="post" action="actie.php" class="gevaar"
      onsubmit="return confirm('Server en al zijn geschiedenis verwijderen?')">
  <input type="hidden" name="actie" value="server_verwijderen">
  <input type="hidden" name="id" value="<?= (int)$s['id'] ?>">
  <button class="rood">Server verwijderen</button>
</form>
<?php endif; ?>
<?php voet();
