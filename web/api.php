<?php
// web/api.php — takes the dashboard's (assets/app.js) fetch, runs R (run.R), and returns the result JSON as is.
//
// Request:  POST {"id": "<sample id>", "action": "<action>", "args": {...}}
// Response: run.R's output as is {"ok", "action", "result" | "error", "meta"}
//
// The server adds the measurement file path. Of the args the browser sends, only the keys allowed for each action reach R
// (so the browser cannot choose arguments that point at server files, such as path or progress_file).

declare(strict_types=1);

require __DIR__ . '/../php/bridge.php';

// action => [allowed args keys, needs the measurement file, result record file (null = display only, not kept)]
const ACTIONS = [
    'curve' => [['position', 'record_index', 'grain', 'mode'], true, null],
    'dose_response' => [['position', 'signal_integral', 'background_integral', 'grain', 'mode', 'seed'], true, null],
    'sar' => [['positions', 'signal_integral', 'background_integral', 'mode', 'seed'], true, 'sar.json'],
    'age_model' => [['de', 'de_error', 'sigmab', 'model', 'max_k'], false, 'age_model.json'],
];

header('Content-Type: application/json; charset=utf-8');

function fail(int $code, string $msg): void
{
    http_response_code($code);
    echo json_encode(['ok' => false, 'error' => $msg], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    fail(405, 'POST requests only.');
}

$req = json_decode((string) file_get_contents('php://input'), true);
$action = is_array($req) ? ($req['action'] ?? null) : null;
if (!is_string($action) || !isset(ACTIONS[$action]) || !is_array($req['args'] ?? null)) {
    fail(400, 'Malformed request.');
}

$dir = sample_dir((string) ($req['id'] ?? ''));
if ($dir === null || !is_dir($dir)) {
    fail(404, 'Sample not found.');
}

[$keys, $needs_file, $keep_as] = ACTIONS[$action];
$args = array_intersect_key($req['args'], array_flip($keys));

if ($needs_file) {
    $args['path'] = sample_input($dir);
    if ($args['path'] === null) {
        fail(404, 'Measurement file missing.');
    }
}

$result = run_r($action, $args, $dir, $keep_as);
echo json_encode($result, JSON_UNESCAPED_UNICODE);
