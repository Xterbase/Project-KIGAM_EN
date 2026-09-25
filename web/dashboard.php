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
<html lang="en">
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
    <ol>
      <li><a href="#file">File<small>discs · grains</small></a></li>
      <li><a href="#signal">Signal<small>curves · analysis settings</small></a></li>
      <li><a href="#dist">De distribution<small>dashboard at a glance</small></a></li>
      <li><a href="#model">Model<small>recommendation · representative dose</small></a></li>
    </ol>
    <a class="bracket" href="./">Upload another file</a>
  </nav>

  <main>
    <div class="context" id="context"></div>

    <section id="file">
      <p class="axis">01 · File</p>
      <h2>File layout</h2>
      <div class="card facts" id="facts"></div>
      <h3>Discs</h3>
      <div class="tablewrap"><table id="discs"></table></div>
    </section>

    <section id="signal">
      <p class="axis">02 · Signal</p>
      <h2>Signal curve</h2>
      <div class="row">
        <label>Disc <select id="selPos"></select></label>
        <label id="grainLabel">Grain <select id="selGrain"></select></label>
        <label>Record <select id="selRec"></select></label>
      </div>
      <div class="plotbox"><div id="curvePlot" class="plot tall"></div></div>
      <p class="note" id="curveInfo"></p>

      <div class="card" style="margin-top:24px">
        <h3 style="margin-top:0">Analysis settings</h3>
        <form id="runForm" class="row" style="margin-bottom:8px">
          <span class="seg" id="modeSeg"></span>
          <label>Signal integral <input type="text" id="sig" placeholder="e.g. 6:10" pattern="\s*\d+\s*:\s*\d+\s*" required></label>
          <label>Background integral <input type="text" id="bg" placeholder="e.g. 81:100" pattern="\s*\d+\s*:\s*\d+\s*" required></label>
          <button type="submit" class="primary" id="runBtn">Run SAR</button>
          <span class="note" id="runStatus"></span>
        </form>
        <p class="note" id="runHint"></p>
      </div>
    </section>

    <section id="dist">
      <p class="axis">03 · De distribution</p>
      <h2>De distribution dashboard</h2>
      <p class="note" id="distEmpty">Waiting for SAR. Set the integrals in 02 · Signal and run it to show this.</p>
      <div id="distBody" hidden>
        <div class="card selbar">
          <button id="prevBtn" title="Previous (←)">Previous</button>
          <span class="big" id="selTitle"></span>
          <span id="selDetail"></span>
          <button id="nextBtn" title="Next (→)">Next</button>
          <span class="note">Click the table or map, or use the ← → keys</span>
        </div>
        <div class="dash">
          <div class="plotbox"><div id="dCurve" class="plot"></div></div>
          <div class="plotbox"><div id="dDR" class="plot"></div></div>
          <div class="plotbox"><div id="dHist" class="plot"></div></div>
          <div class="plotbox"><div id="dRadial" class="plot"></div>
            <p class="note">Only QC-passing De shown. Read a De by extending the line from the origin (left 0) through the point to the arc on the right. Inside the grey band (±2) a point equals the central value within its own error.</p></div>
        </div>
        <div class="lower">
          <div>
            <div class="row"><b id="mapTitle"></b> <select id="mapDisc"></select></div>
            <div class="map" id="map"></div>
            <div class="legend"><span><i style="background:var(--pass)"></i>Pass</span><span><i style="background:var(--fail)"></i>Fail</span>
              <span><i style="box-shadow:inset 0 0 0 0.5px var(--slate-smoke)"></i>Not in file</span></div>
            <p class="note" id="mapNote"></p>
          </div>
          <div>
            <div class="row"><b>Results per analysis unit</b> <label class="note"><input type="checkbox" id="onlyPass"> Passing only</label>
              <span class="note" id="tableCount"></span></div>
            <div class="tablewrap"><table id="units"></table></div>
            <p class="note" id="failedNote"></p>
            <h3>QC of the selected unit</h3>
            <div class="tablewrap"><table id="qc"></table></div>
          </div>
        </div>
      </div>
    </section>

    <section id="model">
      <p class="axis">04 · Model</p>
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
