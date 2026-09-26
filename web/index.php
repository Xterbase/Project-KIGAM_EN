<?php
// web/index.php — upload + sample list.
// BIN/RDA upload → saved to outputs/samples/{id}/raw/ → R (run.R inspect) → redirect to dashboard.php.
//
// Run locally: php -S localhost:8000 -t web -d upload_max_filesize=200M -d post_max_size=200M
// Server: point the DocumentRoot at web/ only. Raise php.ini's upload_max_filesize / post_max_size and
// nginx's client_max_body_size (default 1 MB) to fit the real file sizes.

declare(strict_types=1);

require __DIR__ . '/../php/bridge.php';

$error = null;

// ---- Upload (POST) → save → inspect → redirect to the dashboard (POST-Redirect-GET)
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

        // The most common failure on a server: the web server account cannot write to outputs/.
        if (!@mkdir($dir . '/raw', 0775, true)) {
            $error = 'Could not create the sample folder. Check that the web server account can write to outputs/.';
        } else {
            // The server chooses the stored name. The original file name is only recorded.
            $path = $dir . '/raw/input.' . $ext;
            move_uploaded_file($f['tmp_name'], $path);

            $r = run_r('inspect', ['path' => $path], $dir, 'inspect.json');
            $x = $r['result'] ?? [];
            file_put_contents($dir . '/meta.json', json_encode([
                'original_name' => $f['name'],
                'uploaded_at' => date('c'),
                'size' => $f['size'],
                // Summary for the list (so the whole inspect.json is not read every time)
                'ok' => $r['ok'],
                'single_grain' => $x['single_grain'] ?? null,
                'n_positions' => $x['n_positions'] ?? null,
                'n_grains' => isset($x['grains']) ? count($x['grains']) : null,
                'n_records' => isset($x['records']) ? count($x['records']) : null,
                'record_types' => $x['record_types'] ?? null,
                'header' => $x['header'] ?? null,
            ], JSON_UNESCAPED_UNICODE));

            header('Location: dashboard.php?id=' . $id);
            exit;
        }
    }
}

$samples = list_samples();
?>
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Luminous</title>
<link rel="stylesheet" href="assets/app.css">
</head>
<body>
<div class="page">
  <p class="axis">00 · Upload</p>
  <h1>Luminous</h1>
  <p class="lead">Upload a luminescence measurement file (BIN/RDA) to see signal curves, SAR, the De distribution, and the age model on one screen.</p>

  <?php if ($error): ?>
    <div class="card error"><?= h($error) ?></div>
  <?php endif; ?>

  <!-- Drop zone (assets/drop.js): uploads as soon as a file is chosen, then opens the dashboard -->
  <form method="post" enctype="multipart/form-data" id="upForm">
    <label class="drop" id="drop">
      <input type="file" name="bin" accept=".bin,.BIN,.rda,.rdata,.RData" hidden>
      <b>Drop a BIN / RDA file here</b>
      <span class="note">or click to choose · max <?= h(ini_get('upload_max_filesize')) ?> · after upload the file layout is read and the dashboard opens (a few seconds)</span>
    </label>
  </form>

  <p class="axis" style="margin-top:48px">Samples</p>
  <?php if (!$samples): ?>
    <p class="note">No files uploaded yet.</p>
  <?php else: ?>
    <?php sample_table($samples); ?>
  <?php endif; ?>
</div>
<script src="assets/drop.js"></script>
</body>
</html>
