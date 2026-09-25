<?php
// php/bridge.php — R-call and sample-path functions shared by the pages in web/.
//
// Kept outside the DocumentRoot (web/) so it cannot be executed directly by URL.
// This keeps the rule simple: the only files reachable by URL are the pages in web/.
//
// If Rscript is not on PATH, set it with the RSCRIPT environment variable.

declare(strict_types=1);

define('ROOT', dirname(__DIR__));
define('SAMPLES', ROOT . '/outputs/samples');
define('RSCRIPT', getenv('RSCRIPT') ?: 'Rscript');

const ALLOWED_EXT = ['bin', 'rda', 'rdata'];

// Sample ids and upload times are in Korean time. Some servers set UTC in php.ini, so it is fixed here.
date_default_timezone_set('Asia/Seoul');

function h($s): string
{
    return htmlspecialchars((string) $s, ENT_QUOTES, 'UTF-8');
}

// Sample id → folder path. null if the id format is wrong (blocks path manipulation). Does not check that the folder exists.
function sample_dir(string $id): ?string
{
    return preg_match('/^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$/', $id) ? SAMPLES . '/' . $id : null;
}

// Path of the uploaded measurement file (raw/input.{ext}). null if missing.
function sample_input(string $dir): ?string
{
    return glob($dir . '/raw/input.*')[0] ?? null;
}

function read_json(string $path): ?array
{
    return is_file($path) ? json_decode((string) file_get_contents($path), true) : null;
}

// Calls run.R. User input goes only through a JSON file; the only shell arguments are server-built paths.
// File names differ per request, so concurrent requests do not overwrite each other's input/output.
// With $keep_as the output is kept in the sample folder under that name (result record); otherwise it is deleted (display only).
function run_r(string $action, array $args, string $work_dir, ?string $keep_as = null): array
{
    $tag = $work_dir . '/' . $action . '-' . bin2hex(random_bytes(4));
    $in = $tag . '.in.json';
    $out = $tag . '.json';
    file_put_contents($in, json_encode(['action' => $action, 'args' => $args], JSON_UNESCAPED_UNICODE));

    $cmd = escapeshellarg(RSCRIPT) . ' ' . escapeshellarg(ROOT . '/R/run.R') . ' '
        . escapeshellarg($in) . ' ' . escapeshellarg($out) . ' 2>&1';
    exec($cmd, $console, $status);
    unlink($in);

    if (!is_file($out)) {
        // R could not even write the output file (e.g. no Rscript). Show the last console lines.
        return ['ok' => false, 'error' => 'R run failed (exit code ' . $status . '): ' . implode(' / ', array_slice($console, -3))];
    }

    $result = read_json($out) ?? ['ok' => false, 'error' => 'Could not read R output JSON.'];
    $keep_as === null ? unlink($out) : rename($out, $work_dir . '/' . $keep_as);

    return $result;
}
