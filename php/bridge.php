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

// Sample list (newest first). Folder names start with the time, so reverse name order = newest first. Shared by index.php and dashboard.php.
function list_samples(): array
{
    $samples = [];
    foreach (array_reverse(glob(SAMPLES . '/*', GLOB_ONLYDIR) ?: []) as $d) {
        $id = basename($d);
        $meta = read_json($d . '/meta.json');
        if (sample_dir($id) !== null && $meta !== null) {
            $samples[] = ['id' => $id] + $meta;
        }
    }
    return $samples;
}

// Measurement-mode cell of the list table
function sample_mode(array $s): string
{
    if (($s['ok'] ?? true) === false) {
        return '<span class="no">Read failed</span>';
    }
    return isset($s['single_grain']) ? ($s['single_grain'] ? 'single-grain' : 'single-aliquot') : '—';
}

// Header value list → display string. With many values: the first $n + "+N".
function join_some(?array $v, int $n = 2): string
{
    if (!$v) {
        return '—';
    }
    return implode(', ', array_slice($v, 0, $n)) . (count($v) > $n ? ' +' . (count($v) - $n) : '');
}

// Sample list table (index.php, dashboard.php). $current is the id of the sample being viewed.
// header (sample name, user, measurement date, ...) comes from run.R inspect. Samples uploaded before it existed show '—'.
function sample_table(array $samples, string $current = ''): void
{
    ?>
    <div class="tablewrap">
      <table class="samples">
        <tr><th>Sample</th><th>Mode · light source</th><th>Contents</th><th>User · sequence</th><th>Measured</th><th>Comment</th><th>Uploaded</th><th></th></tr>
        <?php foreach ($samples as $s):
            $hd = $s['header'] ?? [];
            $d1 = $hd['date_first'] ?? null;
            $d2 = $hd['date_last'] ?? null; ?>
          <tr<?= $s['id'] === $current ? ' class="sel"' : '' ?>>
            <td><b><?= h(join_some($hd['sample'] ?? null)) ?></b>
              <span class="note"><?= h($s['original_name'] ?? '') ?> · <?= h(number_format(($s['size'] ?? 0) / 1048576, 1)) ?> MB</span></td>
            <td><?= sample_mode($s) ?><span class="note"><?= h(join_some($hd['lightsource'] ?? null)) ?></span></td>
            <td class="num"><?= h($s['n_positions'] ?? '—') ?> discs<?= !empty($s['single_grain']) ? ' · ' . h($s['n_grains']) . ' grains' : '' ?>
              <span class="note"><?= h($s['n_records'] ?? '—') ?> records · <?= h(join_some($s['record_types'] ?? null, 3)) ?></span></td>
            <td><?= h(join_some($hd['user'] ?? null)) ?><span class="note"><?= h(join_some($hd['sequence'] ?? null)) ?></span></td>
            <td class="num"><?= h($d1 ?? '—') ?><?php if ($d2 && $d2 !== $d1): ?><span class="note">~ <?= h($d2) ?></span><?php endif; ?></td>
            <td class="memo" title="<?= h(implode("\n", $hd['comment'] ?? [])) ?>"><?= h(join_some($hd['comment'] ?? null, 1)) ?></td>
            <td class="num"><?= h(substr((string) ($s['uploaded_at'] ?? ''), 0, 16)) ?></td>
            <td><?= $s['id'] === $current ? '<span class="note">Viewing now</span>' : '<a class="bracket" href="dashboard.php?id=' . h($s['id']) . '">Open</a>' ?></td>
          </tr>
        <?php endforeach; ?>
      </table>
    </div>
    <?php
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
