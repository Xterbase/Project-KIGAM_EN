<?php
// web/index.php — stage 0: BIN upload → R (run.R inspect) → disc list table.
//
// Local run: php -S localhost:8000 -t web -d upload_max_filesize=200M -d post_max_size=200M
// Server: raise upload_max_filesize / post_max_size in php.ini to fit the real file sizes.
// If Rscript is not on PATH, set it with the RSCRIPT environment variable.

declare(strict_types=1);

const ALLOWED_EXT = ['bin', 'rda', 'rdata'];

$ROOT = dirname(__DIR__);
$SAMPLES = $ROOT . '/outputs/samples';
$RSCRIPT = getenv('RSCRIPT') ?: 'Rscript';

function h($s): string
{
    return htmlspecialchars((string) $s, ENT_QUOTES, 'UTF-8');
}

// Call run.R. User input goes only through the JSON file; shell arguments are server-made paths only.
function run_r(string $action, array $args, string $work_dir): array
{
    global $ROOT, $RSCRIPT;

    $in = $work_dir . '/' . $action . '.in.json';
    $out = $work_dir . '/' . $action . '.json';
    file_put_contents($in, json_encode(['action' => $action, 'args' => $args], JSON_UNESCAPED_UNICODE));

    $cmd = escapeshellarg($RSCRIPT) . ' ' . escapeshellarg($ROOT . '/R/run.R') . ' '
        . escapeshellarg($in) . ' ' . escapeshellarg($out) . ' 2>&1';
    exec($cmd, $console, $status);

    if (!is_file($out)) {
        // R could not even write the output file (e.g. no Rscript). Show the last console lines.
        return ['ok' => false, 'error' => 'R run failed (exit code ' . $status . '): ' . implode(' / ', array_slice($console, -3))];
    }

    return json_decode((string) file_get_contents($out), true) ?? ['ok' => false, 'error' => 'Could not read the R output JSON.'];
}

function sample_dir(string $id): ?string
{
    global $SAMPLES;
    return preg_match('/^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$/', $id) ? $SAMPLES . '/' . $id : null;
}

$error = null;

// ---- Upload (POST) → save → inspect → go to the result page (POST-Redirect-GET)
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $f = $_FILES['bin'] ?? null;
    $ext = strtolower(pathinfo((string) ($f['name'] ?? ''), PATHINFO_EXTENSION));

    if (!$f || $f['error'] !== UPLOAD_ERR_OK) {
        $error = 'Upload failed (code ' . ($f['error'] ?? 'none') . '). For a large file, check upload_max_filesize.';
    } elseif (!in_array($ext, ALLOWED_EXT, true)) {
        $error = 'Unsupported type: ' . $ext . ' (allowed: ' . implode(', ', ALLOWED_EXT) . ')';
    } else {
        $id = date('Ymd-His') . '-' . bin2hex(random_bytes(3));
        $dir = sample_dir($id);
        mkdir($dir . '/raw', 0775, true);

        // The server picks the stored name. The original file name is only recorded.
        $path = $dir . '/raw/input.' . $ext;
        move_uploaded_file($f['tmp_name'], $path);
        file_put_contents($dir . '/meta.json', json_encode(
            ['original_name' => $f['name'], 'uploaded_at' => date('c'), 'size' => $f['size']],
            JSON_UNESCAPED_UNICODE
        ));

        run_r('inspect', ['path' => $path], $dir);
        header('Location: ?sample=' . $id);
        exit;
    }
}

// ---- Result page (GET ?sample=...)
$sample = null;
if (isset($_GET['sample'])) {
    $dir = sample_dir((string) $_GET['sample']);
    if ($dir === null || !is_file($dir . '/inspect.json')) {
        $error = 'Sample not found.';
    } else {
        $sample = [
            'id' => $_GET['sample'],
            'meta' => json_decode((string) file_get_contents($dir . '/meta.json'), true),
            'inspect' => json_decode((string) file_get_contents($dir . '/inspect.json'), true),
        ];
    }
}
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Luminous</title>
<style>
  :root { --fg: #1d2330; --muted: #667085; --line: #e4e7ec; --accent: #2563eb; --bg: #f8fafc; --err: #b42318; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 15px/1.5 -apple-system, "Apple SD Gothic Neo", "Segoe UI", sans-serif; color: var(--fg); background: var(--bg); }
  main { max-width: 960px; margin: 0 auto; padding: 20px 16px 40px; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  h2 { font-size: 17px; margin: 28px 0 10px; }
  .sub { color: var(--muted); margin: 0 0 20px; }
  .card { background: #fff; border: 1px solid var(--line); border-radius: 10px; padding: 16px; }
  .err { color: var(--err); border-color: #fecdca; background: #fef3f2; margin-bottom: 16px; }
  .facts { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; }
  .fact b { display: block; font-size: 20px; }
  .fact span { color: var(--muted); font-size: 13px; }
  table { width: 100%; border-collapse: collapse; background: #fff; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { font-size: 13px; color: var(--muted); font-weight: 600; }
  .tag { display: inline-block; padding: 1px 8px; border-radius: 999px; background: #eff4ff; color: var(--accent); font-size: 13px; }
  .grains { color: var(--muted); font-size: 13px; }
  button { background: var(--accent); color: #fff; border: 0; border-radius: 8px; padding: 10px 16px; font-size: 15px; }
  a { color: var(--accent); }
</style>
</head>
<body>
<main>
  <h1>Luminous</h1>
  <p class="sub">Upload a luminescence measurement file (BIN/RDA) to see its discs and grains.</p>

  <?php if ($error): ?>
    <div class="card err"><?= h($error) ?></div>
  <?php endif; ?>

  <?php if (!$sample): ?>
    <form class="card" method="post" enctype="multipart/form-data">
      <p><input type="file" name="bin" accept=".bin,.BIN,.rda,.rdata,.RData" required></p>
      <button type="submit">Upload and inspect</button>
    </form>
  <?php else:
      $r = $sample['inspect'];
      if (!$r['ok']): ?>
    <div class="card err">Analysis failed: <?= h($r['error']) ?></div>
  <?php else:
        $x = $r['result'];
        $by_disc = [];
        foreach ($x['grains'] as $g) { $by_disc[$g['position']][] = $g['grain']; }
        $n_records = count($x['records']);
  ?>
    <div class="card facts">
      <div class="fact"><b><?= h($sample['meta']['original_name']) ?></b><span>File</span></div>
      <div class="fact"><b><span class="tag"><?= $x['single_grain'] ? 'single-grain' : 'single-aliquot' ?></span></b><span>Measurement mode</span></div>
      <div class="fact"><b><?= h($x['n_positions']) ?></b><span>Discs (POSITION)</span></div>
      <div class="fact"><b><?= $x['single_grain'] ? h(count($x['grains'])) : '—' ?></b><span>Grains (GRAIN)</span></div>
      <div class="fact"><b><?= h($n_records) ?></b><span>Records</span></div>
      <div class="fact"><b><?= h(implode(', ', $x['record_types'])) ?></b><span>Record types</span></div>
    </div>

    <h2>Disc list</h2>
    <table>
      <tr><th>Disc</th><th>Grains</th><th>Grain numbers</th></tr>
      <?php foreach ($by_disc as $pos => $grains): ?>
        <tr>
          <td><?= h($pos) ?></td>
          <td><?= $x['single_grain'] ? h(count($grains)) : '—' ?></td>
          <td class="grains"><?= $x['single_grain'] ? h(implode(', ', $grains)) : 'Measured per disc' ?></td>
        </tr>
      <?php endforeach; ?>
    </table>

    <p class="sub" style="margin-top:16px">
      Analysis package: Luminescence <?= h($r['meta']['luminescence_version']) ?> · R <?= h($r['meta']['r_version']) ?> ·
      Sample <?= h($sample['id']) ?> · <a href="?">Upload another file</a>
    </p>
  <?php endif; endif; ?>
</main>
</body>
</html>
