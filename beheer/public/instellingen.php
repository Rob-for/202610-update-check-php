<?php
declare(strict_types=1);
require __DIR__ . '/../lib.php';

$user = instelling('pushover_user');
kop('Instellingen');
?>
<h1>Instellingen</h1>
<form method="post" action="actie.php" class="formulier">
  <input type="hidden" name="actie" value="instellingen_opslaan">

  <h2>Automatisch updaten</h2>
  <label>Elke dag om (leeg = uit)
    <input name="planning_tijd" type="time" value="<?= h(instelling('planning_tijd')) ?>">
    <span class="klein">Alle actieve servers worden dan één voor één bijgewerkt.</span>
  </label>

  <h2>Pushover</h2>
  <label>User key <input name="pushover_user" value="<?= h($user) ?>" autocomplete="off"></label>
  <label>API token
    <input name="pushover_token" type="password" autocomplete="new-password"
           placeholder="<?= instelling('pushover_token') !== '' ? '•••••• (leeg laten = ongewijzigd)' : '' ?>">
  </label>
  <label>Prioriteit
    <select name="pushover_prioriteit">
      <?php foreach (['-2' => '-2 (geen melding, alleen in app)', '-1' => '-1 (stil)', '0' => '0 (normaal)', '1' => '1 (hoog)'] as $k => $v): ?>
        <option value="<?= $k ?>" <?= instelling('pushover_prioriteit', '-1') === (string)$k ? 'selected' : '' ?>><?= h($v) ?></option>
      <?php endforeach; ?>
    </select>
  </label>
  <label>Melding sturen
    <select name="pushover_wanneer">
      <option value="altijd" <?= instelling('pushover_wanneer', 'altijd') === 'altijd' ? 'selected' : '' ?>>Na elke server</option>
      <option value="problemen" <?= instelling('pushover_wanneer', 'altijd') === 'problemen' ? 'selected' : '' ?>>Alleen als het niet volledig JA is</option>
    </select>
  </label>

  <div class="knoppen">
    <button class="primair">Opslaan</button>
  </div>
</form>

<form method="post" action="actie.php">
  <input type="hidden" name="actie" value="test_push">
  <button <?= $user === '' ? 'disabled' : '' ?>>Testmelding sturen</button>
</form>
<?php voet();
