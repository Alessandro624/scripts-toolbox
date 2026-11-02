<?php
declare(strict_types=1);

/**
 * Change a local file's mtime. CLI by default; HTTP requires explicit configuration.
 * HTTP environment: TIMESTAMP_TOKEN (32+ bytes), TIMESTAMP_DIRECTORY (absolute path).
 */
$isCli = PHP_SAPI === 'cli';
if (!$isCli) {
    header('Content-Type: text/plain; charset=UTF-8');
    header('Cache-Control: no-store');
}

function fail(string $message, int $status = 400): never
{
    global $isCli;
    if (!$isCli) {
        http_response_code($status);
    }
    file_put_contents($isCli ? 'php://stderr' : 'php://output', "Error: $message\n");
    exit(1);
}

if ($isCli) {
    if ($argc === 2 && $argv[1] === '--help') {
        echo "Usage: php update_file_timestamp_for_ftp.php FILE 'YYYY-MM-DD HH:MM:SS' [TIMEZONE]\n";
        exit(0);
    }

    if ($argc < 3 || $argc > 4) {
        fail("Expected FILE, 'YYYY-MM-DD HH:MM:SS', and optional TIMEZONE.");
    }

    $targetPath = $argv[1];
    $targetDate = $argv[2];
    $timezone = $argv[3] ?? 'Europe/Rome';
} else {
    $token = getenv('TIMESTAMP_TOKEN');
    $directory = getenv('TIMESTAMP_DIRECTORY');

    if ($token === false || strlen($token) < 32 || $directory === false || $directory === '') {
        fail('HTTP access is disabled until the server is configured.', 503);
    }

    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        header('Allow: POST');
        fail('Use POST.', 405);
    }

    if (!hash_equals('Bearer ' . $token, $_SERVER['HTTP_AUTHORIZATION'] ?? '')) {
        fail('Unauthorized.', 401);
    }

    $file = $_POST['file'] ?? null;
    $targetDate = $_POST['date'] ?? null;
    $timezone = $_POST['timezone'] ?? 'Europe/Rome';

    if (!is_string($file) || $file === '' || preg_match('/[\\\\\/\x00-\x1f:]/', $file)
        || $file === '.' || $file === '..' || rtrim($file, ". ") !== $file) {
        fail('Invalid file name.');
    }

    $base = realpath($directory);

    if ($base === false || !is_dir($base)) {
        fail('Configured directory is unavailable.', 503);
    }

    $targetPath = $base . DIRECTORY_SEPARATOR . $file;
    $resolved = realpath($targetPath);

    if ($resolved === false || dirname($resolved) !== $base) {
        fail('File not found in the configured directory.', 404);
    }
}

if (!is_string($targetDate) || !is_string($timezone)) {
    fail('Date and timezone must be strings.');
}

if (str_contains($targetPath, "\0") || is_link($targetPath) || !is_file($targetPath)) {
    fail('Target must be an existing regular file, not a symbolic link.', 404);
}

try {
    $zone = new DateTimeZone($timezone);
    $date = DateTimeImmutable::createFromFormat('!Y-m-d H:i:s', $targetDate, $zone);
    $errors = DateTimeImmutable::getLastErrors();

    if ($date === false || ($errors !== false && ($errors['warning_count'] || $errors['error_count']))
        || $date->format('Y-m-d H:i:s') !== $targetDate) {
        fail('Invalid date; use YYYY-MM-DD HH:MM:SS.');
    }
} catch (Throwable $error) {
    fail('Invalid date or timezone.');
}

$accessTime = fileatime($targetPath);

if ($accessTime === false || !@touch($targetPath, $date->getTimestamp(), $accessTime)) {
    fail('Unable to update the modification time.', 500);
}

clearstatcache(true, $targetPath);

if (filemtime($targetPath) !== $date->getTimestamp()) {
    fail('The filesystem did not retain the requested modification time.', 500);
}

echo "OK\nModification time: " . $date->format(DateTimeInterface::ATOM) . "\n";
