<?php
// web/dashboard.php — the dashboard shell for one sample.
// Only the file layout (inspect.json) is embedded in the page; curves, SAR and models are fetched by assets/app.js from api.php as needed.

declare(strict_types=1);

require __DIR__ . '/../php/bridge.php';

$id = (string) ($_GET['id'] ?? '');
$dir = sample_dir($id);
$meta = $dir ? read_json($dir . '/meta.json') : null;
$inspect = $dir ? read_json($dir . '/inspect.json') : null;
$error = null;

if ($meta === null || $inspect === null) {
    http_response_code(404);
    $error = 'Sample not found.';
} elseif (!$inspect['ok']) {
    $error = 'Could not read the file: ' . $inspect['error'];
}
?>
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= $meta ? h($meta['original_name']) . ' · ' : '' ?>Luminous</title>
<link rel="stylesheet" href="assets/app.css">
</head>
<body>
<?php if ($error): ?>
  <div class="page">
    <p class="axis">Dashboard</p>
    <div class="card error"><?= h($error) ?></div>
    <a class="bracket" href="./">Back to upload</a>
  </div>
<?php else: ?>
<div class="layout">
  <nav>
    <div class="brand">Luminous</div>
    <div class="file"><?= h($meta['original_name']) ?></div>
    <!-- Tree menu: the selected tab becomes a white box (pill) joined to the content panel on the right. Sub-items expand only under the selected tab. -->
    <ul class="tree" id="tree">
      <li class="pill" id="pill" aria-hidden="true"></li>
      <li data-v="upload"><a class="tab" href="#upload"><span class="dot"></span>Upload<span class="num">01</span></a>
        <div class="sub"><ul><li><a href="#file">File layout</a></li><li><a href="#upfile">Upload another file</a></li><li><a href="#uplist">Samples</a></li></ul></div></li>
      <li data-v="signal"><a class="tab" href="#signal"><span class="dot"></span>Signal analysis<span class="num">02</span></a>
        <div class="sub"><ul><li><a href="#sigcurve">Curves</a></li><li><a href="#sigrun">Analysis settings · SAR</a></li></ul></div></li>
      <li data-v="dash"><a class="tab" href="#dash"><span class="dot"></span>Dashboard<span class="num">03</span></a>
        <div class="sub"><ul><li><a href="#dplots">Four charts</a></li><li><a href="#dmap">Disc map</a></li><li><a href="#dtable">Results per unit</a></li><li><a href="#dqc">QC of selected unit</a></li></ul></div></li>
      <li data-v="model"><a class="tab" href="#model"><span class="dot"></span>Age model<span class="num">04</span></a>
        <div class="sub"><ul><li><a href="#modelBox">Recommendation · representative dose</a></li></ul></div></li>
    </ul>
  </nav>

  <main class="panel">
    <div class="context" id="context"></div>

    <section class="view" id="upload">
      <p class="axis">01 · Upload</p>
      <h2 id="file">File layout</h2>
      <div class="card facts" id="facts"></div>
      <h3>Discs</h3>
      <div class="tablewrap"><table id="discs"></table></div>

      <h3 id="upfile">Upload another file</h3>
      <!-- index.php handles the upload (save → inspect → redirect to the new dashboard). -->
      <form method="post" action="./" enctype="multipart/form-data" id="upForm">
        <label class="drop" id="drop">
          <input type="file" name="bin" accept=".bin,.BIN,.rda,.rdata,.RData" hidden>
          <b>Drop a BIN / RDA file here</b><span class="note">or click to choose · after upload the file layout is read and the new dashboard opens (a few seconds)</span>
        </label>
      </form>

      <h3 id="uplist">Samples</h3>
      <div class="tablewrap">
        <table>
          <tr><th>Uploaded</th><th>File</th><th>Measurement mode</th><th>Discs</th><th>Grains</th><th></th></tr>
          <?php foreach (list_samples() as $s): ?>
            <tr<?= $s['id'] === $id ? ' class="sel"' : '' ?>>
              <td class="num"><?= h(substr((string) ($s['uploaded_at'] ?? ''), 0, 16)) ?></td>
              <td><?= h($s['original_name'] ?? '') ?></td>
              <td><?= sample_mode($s) ?></td>
              <td class="num"><?= h($s['n_positions'] ?? '—') ?></td>
              <td class="num"><?= !empty($s['single_grain']) ? h($s['n_grains']) : '—' ?></td>
              <td><?= $s['id'] === $id ? '<span class="note">Current file</span>' : '<a class="bracket" href="dashboard.php?id=' . h($s['id']) . '">Open</a>' ?></td>
            </tr>
          <?php endforeach; ?>
        </table>
      </div>
    </section>

    <section class="view" id="signal">
      <p class="axis">02 · Signal analysis</p>
      <h2>Signal curves and analysis settings</h2>
      <div class="row" id="sigcurve">
        <label>Disc <select id="selPos"></select></label>
        <label id="grainLabel">Grain <select id="selGrain"></select></label>
        <label>Record <select id="selRec"></select></label>
      </div>
      <div class="howto"></div>
      <div class="plotbox"><div id="curvePlot" class="plot tall"></div></div>
      <p class="note" id="curveInfo"></p>

      <h3 id="sigrun">Analysis settings</h3>
      <div class="card">
        <form id="runForm">
          <div class="row">
            <span class="seg" id="modeSeg"><span class="thumb"></span></span>
            <label>Signal integral <input type="text" id="sig" placeholder="e.g. 6:10" pattern="\s*\d+\s*:\s*\d+\s*" required></label>
            <label>Background integral <input type="text" id="bg" placeholder="e.g. 81:100" pattern="\s*\d+\s*:\s*\d+\s*" required></label>
          </div>
          <div class="row" style="margin:0">
            <button type="submit" class="btn primary" id="runBtn">Run SAR</button>
            <span class="note" id="runStatus"></span>
          </div>
        </form>
        <p class="note" id="runHint" style="margin:10px 0 0"></p>
      </div>
    </section>

    <section class="view" id="dash">
      <p class="axis">03 · Dashboard</p>
      <h2>De distribution dashboard</h2>
      <p class="note" id="distEmpty">Waiting for SAR. Set the integrals in 02 · Signal analysis and run it to show this.</p>
      <div id="distBody" hidden>
        <div class="selbar">
          <button class="btn" id="prevBtn" title="Previous (←)">Previous</button>
          <span class="big" id="selTitle"></span>
          <span id="selDetail"></span>
          <button class="btn" id="nextBtn" title="Next (→)">Next</button>
          <span class="note">Click the table or map, or use the ← → keys</span>
        </div>
        <div class="howto"></div>
        <div class="dash" id="dplots">
          <div class="plotbox"><div id="dCurve" class="plot"></div></div>
          <div class="plotbox"><div id="dDR" class="plot"></div></div>
          <div class="plotbox"><div id="dHist" class="plot"></div></div>
          <div class="plotbox"><div id="dRadial" class="plot"></div></div>
        </div>
        <p class="note">Radial plot: only QC-passing De shown. Read a De by extending the line from the origin (left 0) through the point to the arc on the right. Inside the grey band (±2) a point equals the central value within its own error.</p>
        <div class="lower">
          <div id="dmap">
            <div class="row"><b id="mapTitle"></b> <select id="mapDisc"></select></div>
            <div class="map" id="map"></div>
            <div class="legend"><span><i style="background:var(--pass)"></i>Pass</span><span><i style="background:var(--fail)"></i>Fail</span>
              <span><i style="box-shadow:inset 0 0 0 0.5px var(--slate-smoke)"></i>Not in file</span></div>
            <p class="note" id="mapNote"></p>
          </div>
          <div>
            <div class="row" id="dtable"><b>Results per analysis unit</b>
              <label class="switch"><input type="checkbox" id="onlyPass"><span class="track"><span class="knob"></span></span>Passing only</label>
              <span class="note" id="tableCount"></span></div>
            <div class="tablewrap"><table id="units"></table></div>
            <p class="note" id="failedNote"></p>
            <h3 id="dqc">QC of the selected unit</h3>
            <div class="tablewrap"><table id="qc"></table></div>
          </div>
        </div>
      </div>
    </section>

    <section class="view" id="model">
      <p class="axis">04 · Age model</p>
      <h2>Age model</h2>
      <div class="card" id="modelBox"><p class="note">Waiting for SAR.</p></div>
    </section>
  </main>
</div>
<div class="chip" id="chip"></div>

<script id="boot" type="application/json"><?= json_encode(
    ['id' => $id, 'file' => $meta['original_name'], 'inspect' => $inspect['result'], 'meta' => $inspect['meta']],
    JSON_UNESCAPED_UNICODE | JSON_HEX_TAG | JSON_HEX_AMP
) ?></script>
<script src="assets/vendor/plotly-basic-2.35.2.min.js"></script>
<script src="assets/app.js"></script>
<?php endif; ?>
</body>
</html>
