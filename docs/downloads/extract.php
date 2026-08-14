<?php
declare(strict_types=1);

/**
 * Smart cPanel Deployer - Production server endpoint
 *
 * Requirements:
 *   - PHP 8.0+
 *   - ext-zip (ZipArchive)
 *   - write access to this directory
 *   - a non-empty .deploy-token file in this directory
 *
 * Authentication:
 *   X-Deploy-Token: <token>
 *   or Authorization: Bearer <token>
 */

set_time_limit(0);
ini_set('memory_limit', '512M');
ignore_user_abort(true);
header('Content-Type: application/json; charset=UTF-8');
header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
header('X-Content-Type-Options: nosniff');

const API_VERSION = '2.0';
const MAX_BACKUPS = 10;
const MAX_STATE_AGE_DAYS = 14;
const MAX_LOG_BYTES = 5_242_880; // 5 MiB
const MAX_ROTATED_LOGS = 5;
const MAX_UPLOAD_BYTES = 1_073_741_824; // 1 GiB

$ROOT = __DIR__;
$BACKUP_DIR = $ROOT . '/.deploy-backups';
$STATE_DIR = $ROOT . '/.deploy-state';
$STAGING_DIR = $ROOT . '/.deploy-staging';
$TOKEN_FILE = $ROOT . '/.deploy-token';
$LOCK_FILE = $ROOT . '/.deploy.lock';
$SERVER_LOG = $ROOT . '/.deploy-server.log';
$MANIFEST_FILE = $ROOT . '/.deploy-manifest.json';

$ACTIVE_DEPLOY_ID = null;
$ACTIVE_ACTION = null;
$ACTIVE_STATE_DIR = $STATE_DIR;

/** @return never */
function respondJson(bool $ok, string $message, mixed $data = null, int $httpCode = 200): void
{
    http_response_code($httpCode);
    $payload = [
        'ok' => $ok,
        'api_version' => API_VERSION,
        'message' => $message,
        'data' => $data,
        'timestamp' => gmdate('c'),
    ];
    echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

function param(string $name, string $default = ''): string
{
    $value = $_POST[$name] ?? $_GET[$name] ?? $default;
    return is_scalar($value) ? trim((string)$value) : $default;
}

function requestHeader(string $name): string
{
    $key = 'HTTP_' . strtoupper(str_replace('-', '_', $name));
    if (isset($_SERVER[$key])) {
        return trim((string)$_SERVER[$key]);
    }

    if (function_exists('getallheaders')) {
        foreach ((array)getallheaders() as $header => $value) {
            if (strcasecmp((string)$header, $name) === 0) {
                return trim((string)$value);
            }
        }
    }
    return '';
}

function clientToken(): string
{
    $direct = requestHeader('X-Deploy-Token');
    if ($direct !== '') {
        return $direct;
    }

    $authorization = requestHeader('Authorization');
    if (preg_match('/^Bearer\s+(.+)$/i', $authorization, $m) === 1) {
        return trim($m[1]);
    }
    return '';
}

function requireMethod(array $methods): void
{
    $method = strtoupper((string)($_SERVER['REQUEST_METHOD'] ?? 'GET'));
    if (!in_array($method, $methods, true)) {
        header('Allow: ' . implode(', ', $methods));
        respondJson(false, 'HTTP method not allowed.', ['code' => 'METHOD_NOT_ALLOWED'], 405);
    }
}

function ensureDirectory(string $path, int $mode = 0755): void
{
    if (is_dir($path)) {
        return;
    }
    if (!mkdir($path, $mode, true) && !is_dir($path)) {
        throw new RuntimeException("Unable to create directory: {$path}");
    }
}

function rotateLogIfNeeded(string $logFile): void
{
    if (!is_file($logFile) || (int)filesize($logFile) < MAX_LOG_BYTES) {
        return;
    }

    $rotated = $logFile . '.' . gmdate('Ymd_His');
    @rename($logFile, $rotated);

    $logs = glob($logFile . '.*') ?: [];
    usort($logs, static fn(string $a, string $b): int => (filemtime($b) ?: 0) <=> (filemtime($a) ?: 0));
    foreach (array_slice($logs, MAX_ROTATED_LOGS) as $old) {
        @unlink($old);
    }
}

function serverLog(string $level, string $message, array $context = []): void
{
    global $SERVER_LOG, $ACTIVE_DEPLOY_ID, $ACTIVE_ACTION;

    rotateLogIfNeeded($SERVER_LOG);
    unset($context['token'], $context['password'], $context['ftp_password']);
    $entry = [
        'timestamp' => gmdate('c'),
        'level' => strtoupper($level),
        'action' => $ACTIVE_ACTION,
        'deploy_id' => $ACTIVE_DEPLOY_ID,
        'message' => $message,
        'context' => $context ?: (object)[],
    ];
    @file_put_contents(
        $SERVER_LOG,
        json_encode($entry, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE) . PHP_EOL,
        FILE_APPEND | LOCK_EX
    );
}

function atomicJsonWrite(string $path, array $data): void
{
    $tmp = $path . '.tmp.' . bin2hex(random_bytes(4));
    $encoded = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
    if ($encoded === false || file_put_contents($tmp, $encoded, LOCK_EX) === false) {
        @unlink($tmp);
        throw new RuntimeException('Unable to write JSON state file.');
    }
    if (!@rename($tmp, $path)) {
        @unlink($tmp);
        throw new RuntimeException('Unable to atomically replace JSON state file.');
    }
}

function statePath(string $deployId): string
{
    global $STATE_DIR;
    return $STATE_DIR . '/' . $deployId . '.json';
}

function validDeployId(string $deployId): bool
{
    return preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]{5,127}$/', $deployId) === 1;
}

function loadState(string $deployId): ?array
{
    if (!validDeployId($deployId)) {
        return null;
    }
    $path = statePath($deployId);
    if (!is_file($path)) {
        return null;
    }
    $raw = file_get_contents($path);
    $data = is_string($raw) ? json_decode($raw, true) : null;
    return is_array($data) ? $data : null;
}

function saveState(string $deployId, array $changes, bool $merge = true): array
{
    global $STATE_DIR;
    ensureDirectory($STATE_DIR);
    $state = $merge ? (loadState($deployId) ?? []) : [];
    $state = array_replace($state, $changes);
    $state['deploy_id'] = $deployId;
    $state['updated_at'] = gmdate('c');
    if (!isset($state['started_at'])) {
        $state['started_at'] = gmdate('c');
    }
    atomicJsonWrite(statePath($deployId), $state);
    return $state;
}

function acquireDeployLock()
{
    global $LOCK_FILE;
    $handle = fopen($LOCK_FILE, 'c+');
    if ($handle === false) {
        throw new RuntimeException('Unable to open deployment lock file.');
    }
    if (!flock($handle, LOCK_EX | LOCK_NB)) {
        fclose($handle);
        return null;
    }
    ftruncate($handle, 0);
    fwrite($handle, json_encode(['pid' => getmypid(), 'time' => gmdate('c')]));
    fflush($handle);
    return $handle;
}

function releaseDeployLock($handle): void
{
    if (is_resource($handle)) {
        @flock($handle, LOCK_UN);
        @fclose($handle);
    }
}

function normalizeRelativePath(string $path): string
{
    $path = str_replace('\\', '/', $path);
    $path = preg_replace('#/+#', '/', $path) ?? $path;
    return ltrim($path, '/');
}

function isReservedRelativePath(string $relative): bool
{
    $relative = normalizeRelativePath($relative);
    $first = explode('/', $relative, 2)[0] ?? '';

    if ($relative === 'extract.php' || $relative === '.deploy-token' || $relative === '.deploy.lock' || $relative === '.deploy-server.log' || $relative === '.deploy-manifest.json') {
        return true;
    }
    if (in_array($first, ['.deploy-backups', '.deploy-state', '.deploy-staging'], true)) {
        return true;
    }
    return str_starts_with($first, '.deploy-');
}

function safeArchiveEntryName(string $name): ?string
{
    $name = str_replace('\\', '/', $name);
    if ($name === '' || str_contains($name, "\0")) {
        return null;
    }
    if (str_starts_with($name, '/') || preg_match('/^[A-Za-z]:\//', $name) === 1) {
        return null;
    }

    $parts = [];
    foreach (explode('/', $name) as $segment) {
        if ($segment === '' || $segment === '.') {
            continue;
        }
        if ($segment === '..') {
            return null;
        }
        $parts[] = $segment;
    }
    if (!$parts) {
        return null;
    }

    $relative = implode('/', $parts);
    if (isReservedRelativePath($relative)) {
        return null;
    }
    return $relative;
}

function zipEntryIsSymlink(ZipArchive $zip, int $index): bool
{
    $opsys = 0;
    $attr = 0;
    if (!$zip->getExternalAttributesIndex($index, $opsys, $attr)) {
        return false;
    }
    $mode = ($attr >> 16) & 0xF000;
    return $mode === 0xA000;
}

/** @return list<string> */
function validateArchiveAndGetFiles(string $zipPath): array
{
    $zip = new ZipArchive();
    $result = $zip->open($zipPath);
    if ($result !== true) {
        throw new RuntimeException("Unable to open ZIP archive (ZipArchive code {$result}).");
    }

    $files = [];
    try {
        if ($zip->numFiles < 1) {
            throw new RuntimeException('Uploaded archive is empty.');
        }
        for ($i = 0; $i < $zip->numFiles; $i++) {
            $name = (string)$zip->getNameIndex($i);
            $safe = safeArchiveEntryName($name);
            if ($safe === null) {
                throw new RuntimeException("Unsafe or reserved archive entry: {$name}");
            }
            if (zipEntryIsSymlink($zip, $i)) {
                throw new RuntimeException("Symbolic links are not allowed in deployment archives: {$name}");
            }
            if (!str_ends_with($name, '/')) {
                $files[] = $safe;
            }
        }
    } finally {
        $zip->close();
    }

    $files = array_values(array_unique($files));
    sort($files, SORT_STRING);
    if (!$files) {
        throw new RuntimeException('Uploaded archive does not contain deployable files.');
    }
    return $files;
}

function removePath(string $path): void
{
    if (!file_exists($path) && !is_link($path)) {
        return;
    }
    if (is_file($path) || is_link($path)) {
        if (!@unlink($path) && (file_exists($path) || is_link($path))) {
            throw new RuntimeException("Unable to remove file: {$path}");
        }
        return;
    }

    $items = scandir($path);
    if ($items === false) {
        throw new RuntimeException("Unable to scan directory: {$path}");
    }
    foreach ($items as $item) {
        if ($item === '.' || $item === '..') {
            continue;
        }
        removePath($path . DIRECTORY_SEPARATOR . $item);
    }
    if (!@rmdir($path) && is_dir($path)) {
        throw new RuntimeException("Unable to remove directory: {$path}");
    }
}

/** @return list<string> */
function readManifest(): array
{
    global $MANIFEST_FILE;
    if (!is_file($MANIFEST_FILE)) {
        return [];
    }
    $raw = file_get_contents($MANIFEST_FILE);
    $data = is_string($raw) ? json_decode($raw, true) : null;
    if (!is_array($data) || !isset($data['files']) || !is_array($data['files'])) {
        return [];
    }

    $files = [];
    foreach ($data['files'] as $file) {
        if (!is_string($file)) {
            continue;
        }
        $safe = safeArchiveEntryName($file);
        if ($safe !== null) {
            $files[] = $safe;
        }
    }
    return array_values(array_unique($files));
}

function writeManifest(array $files, string $deployId): void
{
    global $MANIFEST_FILE;
    sort($files, SORT_STRING);
    atomicJsonWrite($MANIFEST_FILE, [
        'deploy_id' => $deployId,
        'created_at' => gmdate('c'),
        'files' => array_values(array_unique($files)),
    ]);
}

function removeManifestFiles(array $files): void
{
    global $ROOT;
    $dirs = [];
    foreach ($files as $relative) {
        $safe = safeArchiveEntryName((string)$relative);
        if ($safe === null) {
            continue;
        }
        $full = $ROOT . '/' . $safe;
        if (is_file($full) || is_link($full)) {
            if (!@unlink($full) && (is_file($full) || is_link($full))) {
                throw new RuntimeException("Unable to remove deployed file: {$safe}");
            }
        }
        $dir = dirname($safe);
        while ($dir !== '.' && $dir !== '' && $dir !== '/') {
            $dirs[$dir] = substr_count($dir, '/');
            $dir = dirname($dir);
        }
    }

    arsort($dirs, SORT_NUMERIC);
    foreach (array_keys($dirs) as $relativeDir) {
        $full = $ROOT . '/' . $relativeDir;
        if (is_dir($full)) {
            @rmdir($full); // intentionally remove only if empty
        }
    }
}

function shouldBackupRelative(string $relative, ?string $artifactBasename): bool
{
    $relative = normalizeRelativePath($relative);
    if ($relative === '') {
        return false;
    }
    if ($artifactBasename !== null && $relative === $artifactBasename) {
        return false;
    }
    if ($relative === 'extract.php' || $relative === '.deploy-token' || $relative === '.deploy.lock' || $relative === '.deploy-server.log') {
        return false;
    }
    $first = explode('/', $relative, 2)[0] ?? '';
    if (in_array($first, ['.deploy-backups', '.deploy-state', '.deploy-staging'], true)) {
        return false;
    }
    return true;
}

function createBackup(string $deployId, ?string $artifactBasename): ?string
{
    global $ROOT, $BACKUP_DIR;
    ensureDirectory($BACKUP_DIR);

    $backupName = 'backup-' . gmdate('Ymd_His') . '-' . preg_replace('/[^A-Za-z0-9._-]/', '_', $deployId) . '.zip';
    $backupPath = $BACKUP_DIR . '/' . $backupName;
    $zip = new ZipArchive();
    $opened = $zip->open($backupPath, ZipArchive::CREATE | ZipArchive::OVERWRITE);
    if ($opened !== true) {
        throw new RuntimeException("Unable to create backup ZIP (ZipArchive code {$opened}).");
    }

    $count = 0;
    try {
        $iterator = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($ROOT, FilesystemIterator::SKIP_DOTS),
            RecursiveIteratorIterator::LEAVES_ONLY
        );
        /** @var SplFileInfo $item */
        foreach ($iterator as $item) {
            $full = $item->getPathname();
            $relative = normalizeRelativePath(substr($full, strlen($ROOT) + 1));
            if (!shouldBackupRelative($relative, $artifactBasename)) {
                continue;
            }
            if ($item->isLink()) {
                serverLog('WARNING', 'Skipping symbolic link in backup.', ['path' => $relative]);
                continue;
            }
            if ($item->isFile()) {
                if (!$zip->addFile($full, $relative)) {
                    throw new RuntimeException("Unable to add file to backup: {$relative}");
                }
                $count++;
            }
        }
    } finally {
        $closed = $zip->close();
        if (!$closed) {
            @unlink($backupPath);
            throw new RuntimeException('Unable to finalize backup ZIP.');
        }
    }

    if ($count === 0) {
        @unlink($backupPath);
        return null;
    }
    return $backupName;
}

function rotateBackups(): void
{
    global $BACKUP_DIR;
    $files = glob($BACKUP_DIR . '/backup-*.zip') ?: [];
    usort($files, static fn(string $a, string $b): int => (filemtime($b) ?: 0) <=> (filemtime($a) ?: 0));
    foreach (array_slice($files, MAX_BACKUPS) as $old) {
        @unlink($old);
    }
}

function cleanupOldStates(): void
{
    global $STATE_DIR;
    $cutoff = time() - (MAX_STATE_AGE_DAYS * 86400);
    foreach (glob($STATE_DIR . '/*.json') ?: [] as $file) {
        $mtime = filemtime($file);
        if ($mtime !== false && $mtime < $cutoff) {
            @unlink($file);
        }
    }
}

function extractZipTo(string $zipPath, string $destination): void
{
    ensureDirectory($destination);
    $zip = new ZipArchive();
    $opened = $zip->open($zipPath);
    if ($opened !== true) {
        throw new RuntimeException("Unable to open ZIP for extraction (ZipArchive code {$opened}).");
    }
    try {
        if (!$zip->extractTo($destination)) {
            throw new RuntimeException('ZipArchive extraction failed.');
        }
    } finally {
        $zip->close();
    }
}

function copyStagingIntoRoot(string $stageDir, array $files): void
{
    global $ROOT;
    foreach ($files as $relative) {
        $safe = safeArchiveEntryName((string)$relative);
        if ($safe === null) {
            throw new RuntimeException("Unsafe staging file path: {$relative}");
        }
        $source = $stageDir . '/' . $safe;
        $destination = $ROOT . '/' . $safe;
        if (!is_file($source)) {
            throw new RuntimeException("Expected staged file is missing: {$safe}");
        }
        $parent = dirname($destination);
        ensureDirectory($parent);

        if (file_exists($destination) || is_link($destination)) {
            if (is_dir($destination) && !is_link($destination)) {
                removePath($destination);
            } else {
                @unlink($destination);
            }
        }

        if (!@rename($source, $destination)) {
            if (!@copy($source, $destination)) {
                throw new RuntimeException("Unable to publish staged file: {$safe}");
            }
            @unlink($source);
        }
    }
}

function restoreBackup(?string $backupName, array $currentManifest, bool $hadPreviousManifest): void
{
    global $ROOT, $BACKUP_DIR, $STAGING_DIR, $MANIFEST_FILE;

    removeManifestFiles($currentManifest);
    if ($backupName === null || $backupName === '') {
        if (!$hadPreviousManifest) {
            @unlink($MANIFEST_FILE);
        }
        return;
    }

    $backupName = basename($backupName);
    $backupPath = $BACKUP_DIR . '/' . $backupName;
    if (!is_file($backupPath)) {
        throw new RuntimeException("Backup file not found: {$backupName}");
    }

    $restoreStage = $STAGING_DIR . '/restore-' . bin2hex(random_bytes(6));
    ensureDirectory($restoreStage);
    try {
        $zip = new ZipArchive();
        $opened = $zip->open($backupPath);
        if ($opened !== true) {
            throw new RuntimeException("Unable to open backup ZIP (ZipArchive code {$opened}).");
        }
        try {
            if (!$zip->extractTo($restoreStage)) {
                throw new RuntimeException('Unable to extract backup ZIP.');
            }
        } finally {
            $zip->close();
        }

        $iterator = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($restoreStage, FilesystemIterator::SKIP_DOTS),
            RecursiveIteratorIterator::LEAVES_ONLY
        );
        /** @var SplFileInfo $item */
        foreach ($iterator as $item) {
            if (!$item->isFile() || $item->isLink()) {
                continue;
            }
            $relative = normalizeRelativePath(substr($item->getPathname(), strlen($restoreStage) + 1));
            $destination = $ROOT . '/' . $relative;
            ensureDirectory(dirname($destination));
            if (file_exists($destination) || is_link($destination)) {
                if (is_dir($destination) && !is_link($destination)) {
                    removePath($destination);
                } else {
                    @unlink($destination);
                }
            }
            if (!@rename($item->getPathname(), $destination)) {
                if (!@copy($item->getPathname(), $destination)) {
                    throw new RuntimeException("Unable to restore file: {$relative}");
                }
            }
        }

        if (!$hadPreviousManifest && !is_file($restoreStage . '/.deploy-manifest.json')) {
            @unlink($MANIFEST_FILE);
        }
    } finally {
        if (is_dir($restoreStage)) {
            removePath($restoreStage);
        }
    }
}


function backupContainsManifest(?string $backupName): bool
{
    global $BACKUP_DIR;
    if ($backupName === null || $backupName === '') {
        return false;
    }
    $path = $BACKUP_DIR . '/' . basename($backupName);
    if (!is_file($path)) {
        return false;
    }
    $zip = new ZipArchive();
    $opened = $zip->open($path);
    if ($opened !== true) {
        return false;
    }
    try {
        return $zip->locateName('.deploy-manifest.json', ZipArchive::FL_NOCASE) !== false;
    } finally {
        $zip->close();
    }
}

function latestBackupName(): ?string
{
    global $BACKUP_DIR;
    $files = glob($BACKUP_DIR . '/backup-*.zip') ?: [];
    if (!$files) {
        return null;
    }
    usort($files, static fn(string $a, string $b): int => (filemtime($b) ?: 0) <=> (filemtime($a) ?: 0));
    return basename($files[0]);
}

function requireAuthentication(): void
{
    global $TOKEN_FILE;
    if (!is_file($TOKEN_FILE)) {
        serverLog('ERROR', 'Deploy token file is missing.');
        respondJson(false, 'Server deployment token is not configured.', ['code' => 'TOKEN_NOT_CONFIGURED'], 503);
    }
    $expected = trim((string)file_get_contents($TOKEN_FILE));
    if ($expected === '') {
        respondJson(false, 'Server deployment token is empty.', ['code' => 'TOKEN_NOT_CONFIGURED'], 503);
    }
    $provided = clientToken();
    if ($provided === '' || !hash_equals($expected, $provided)) {
        usleep(150000);
        serverLog('WARNING', 'Rejected deployment API authentication attempt.', ['remote_addr' => $_SERVER['REMOTE_ADDR'] ?? null]);
        respondJson(false, 'Forbidden.', ['code' => 'FORBIDDEN'], 403);
    }
}

function validateServerRequirements(): array
{
    global $ROOT, $TOKEN_FILE;
    return [
        'php_version' => PHP_VERSION,
        'zip_archive' => class_exists(ZipArchive::class),
        'root_writable' => is_writable($ROOT),
        'token_configured' => is_file($TOKEN_FILE) && trim((string)@file_get_contents($TOKEN_FILE)) !== '',
    ];
}

register_shutdown_function(static function (): void {
    global $ACTIVE_DEPLOY_ID;
    if ($ACTIVE_DEPLOY_ID === null) {
        return;
    }
    $last = error_get_last();
    if ($last === null || !in_array($last['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR, E_USER_ERROR], true)) {
        return;
    }
    try {
        saveState($ACTIVE_DEPLOY_ID, [
            'status' => 'failed',
            'error' => 'Fatal PHP error: ' . ($last['message'] ?? 'unknown'),
        ]);
        serverLog('ERROR', 'Fatal PHP error terminated deployment.', ['error' => $last['message'] ?? 'unknown']);
    } catch (Throwable) {
        // Nothing else can be done during fatal shutdown.
    }
});

try {
    if (!class_exists(ZipArchive::class)) {
        respondJson(false, 'PHP ZipArchive extension is required.', ['code' => 'ZIP_EXTENSION_MISSING'], 500);
    }

    ensureDirectory($BACKUP_DIR);
    ensureDirectory($STATE_DIR);
    ensureDirectory($STAGING_DIR);

    $ACTIVE_ACTION = strtolower(param('action', 'health'));
    requireAuthentication();

    switch ($ACTIVE_ACTION) {
        case 'health': {
            requireMethod(['GET', 'POST']);
            $requirements = validateServerRequirements();
            $healthy = !in_array(false, $requirements, true);
            respondJson($healthy, $healthy ? 'Deployment API is healthy.' : 'Deployment API has unmet requirements.', $requirements, $healthy ? 200 : 500);
        }

        case 'status': {
            requireMethod(['GET', 'POST']);
            $deployId = param('deploy_id');
            if (!validDeployId($deployId)) {
                respondJson(false, 'A valid deploy_id is required.', ['code' => 'INVALID_DEPLOY_ID'], 400);
            }
            $state = loadState($deployId);
            if ($state === null) {
                respondJson(false, 'Deploy state was not found.', ['code' => 'STATE_NOT_FOUND', 'deploy_id' => $deployId], 404);
            }
            respondJson(true, 'Deploy state loaded.', $state);
        }

        case 'backup': {
            requireMethod(['POST']);
            $lock = acquireDeployLock();
            if ($lock === null) {
                respondJson(false, 'Another deployment operation is already running.', ['code' => 'DEPLOY_LOCKED'], 409);
            }
            try {
                $manualId = 'manual-' . gmdate('YmdHis') . '-' . bin2hex(random_bytes(3));
                $ACTIVE_DEPLOY_ID = $manualId;
                $backup = createBackup($manualId, null);
                rotateBackups();
                serverLog('INFO', 'Manual backup completed.', ['backup' => $backup]);
                respondJson(true, 'Backup completed.', ['backup' => $backup, 'deploy_id' => $manualId]);
            } finally {
                releaseDeployLock($lock);
            }
        }

        case 'extract': {
            requireMethod(['POST']);
            $file = basename(param('file'));
            $deployId = param('deploy_id');
            $expectedSha = strtolower(param('sha256'));

            if ($file === '' || !str_ends_with(strtolower($file), '.zip')) {
                respondJson(false, 'A .zip file parameter is required.', ['code' => 'INVALID_FILE'], 400);
            }
            if (!validDeployId($deployId)) {
                respondJson(false, 'A valid deploy_id is required.', ['code' => 'INVALID_DEPLOY_ID'], 400);
            }
            if ($expectedSha !== '' && preg_match('/^[a-f0-9]{64}$/', $expectedSha) !== 1) {
                respondJson(false, 'sha256 must be a 64-character hexadecimal digest.', ['code' => 'INVALID_SHA256'], 400);
            }

            $ACTIVE_DEPLOY_ID = $deployId;
            $zipPath = $ROOT . '/' . $file;
            if (!is_file($zipPath)) {
                saveState($deployId, ['status' => 'failed', 'file' => $file, 'error' => 'Uploaded archive not found.'], false);
                respondJson(false, 'Uploaded archive was not found on the server.', ['code' => 'FILE_NOT_FOUND', 'deploy_id' => $deployId], 404);
            }
            $size = filesize($zipPath);
            if ($size === false || $size <= 0 || $size > MAX_UPLOAD_BYTES) {
                saveState($deployId, ['status' => 'failed', 'file' => $file, 'error' => 'Invalid archive size.'], false);
                respondJson(false, 'Uploaded archive size is invalid or exceeds the server limit.', ['code' => 'INVALID_ARCHIVE_SIZE', 'deploy_id' => $deployId], 413);
            }

            $existing = loadState($deployId);
            if (is_array($existing) && ($existing['status'] ?? '') === 'completed') {
                respondJson(true, 'This Deploy ID has already completed successfully.', $existing);
            }

            $lock = acquireDeployLock();
            if ($lock === null) {
                saveState($deployId, ['status' => 'waiting', 'file' => $file], $existing !== null);
                respondJson(false, 'Another deployment operation is already running.', ['code' => 'DEPLOY_LOCKED', 'deploy_id' => $deployId, 'status' => 'waiting'], 409);
            }

            $stageDir = $STAGING_DIR . '/' . $deployId;
            $backupName = null;
            $newManifest = [];
            $previousManifest = readManifest();
            $hadPreviousManifest = is_file($MANIFEST_FILE);
            $rootModified = false;

            try {
                saveState($deployId, [
                    'status' => 'starting',
                    'file' => $file,
                    'archive_size' => $size,
                    'expected_sha256' => $expectedSha !== '' ? $expectedSha : null,
                    'previous_manifest_count' => count($previousManifest),
                ], false);
                serverLog('INFO', 'Deployment started.', ['file' => $file, 'archive_size' => $size]);

                $actualSha = hash_file('sha256', $zipPath);
                if (!is_string($actualSha)) {
                    throw new RuntimeException('Unable to calculate archive SHA-256.');
                }
                if ($expectedSha !== '' && !hash_equals($expectedSha, strtolower($actualSha))) {
                    throw new RuntimeException('Uploaded archive SHA-256 does not match the client digest.');
                }

                saveState($deployId, ['status' => 'extracting', 'sha256' => $actualSha]);
                $newManifest = validateArchiveAndGetFiles($zipPath);
                if (is_dir($stageDir)) {
                    removePath($stageDir);
                }
                ensureDirectory($stageDir);
                extractZipTo($zipPath, $stageDir);
                serverLog('INFO', 'Archive validated and extracted to staging.', ['file_count' => count($newManifest)]);

                saveState($deployId, ['status' => 'backing_up', 'new_manifest_count' => count($newManifest)]);
                $backupName = createBackup($deployId, $file);
                saveState($deployId, [
                    'backup' => $backupName,
                    'had_previous_manifest' => $hadPreviousManifest,
                ]);
                rotateBackups();
                serverLog('INFO', 'Pre-deployment backup completed.', ['backup' => $backupName]);

                saveState($deployId, ['status' => 'deploying']);
                $rootModified = true;
                removeManifestFiles($previousManifest);
                copyStagingIntoRoot($stageDir, $newManifest);
                writeManifest($newManifest, $deployId);

                saveState($deployId, [
                    'status' => 'completed',
                    'completed_at' => gmdate('c'),
                    'file_count' => count($newManifest),
                    'error' => null,
                ]);
                serverLog('INFO', 'Deployment completed successfully.', ['file_count' => count($newManifest), 'backup' => $backupName]);
                @unlink($zipPath);
                if (is_dir($stageDir)) {
                    removePath($stageDir);
                }
                cleanupOldStates();
                respondJson(true, 'Deployment completed successfully.', loadState($deployId));
            } catch (Throwable $e) {
                serverLog('ERROR', 'Deployment failed.', ['error' => $e->getMessage(), 'root_modified' => $rootModified]);
                $rollbackError = null;
                if ($rootModified) {
                    try {
                        removeManifestFiles($newManifest);
                        restoreBackup($backupName, [], $hadPreviousManifest);
                        saveState($deployId, [
                            'status' => 'failed_rolled_back',
                            'error' => $e->getMessage(),
                            'rollback_at' => gmdate('c'),
                        ]);
                        serverLog('WARNING', 'Automatic rollback after deployment failure succeeded.');
                    } catch (Throwable $rollbackException) {
                        $rollbackError = $rollbackException->getMessage();
                        saveState($deployId, [
                            'status' => 'failed',
                            'error' => $e->getMessage(),
                            'rollback_error' => $rollbackError,
                        ]);
                        serverLog('ERROR', 'Automatic rollback after deployment failure also failed.', ['rollback_error' => $rollbackError]);
                    }
                } else {
                    saveState($deployId, ['status' => 'failed', 'error' => $e->getMessage()]);
                }
                if (is_dir($stageDir)) {
                    try { removePath($stageDir); } catch (Throwable) {}
                }
                respondJson(false, $rollbackError === null && $rootModified
                    ? 'Deployment failed and was automatically rolled back.'
                    : 'Deployment failed.', [
                        'code' => 'DEPLOY_FAILED',
                        'deploy_id' => $deployId,
                        'status' => loadState($deployId)['status'] ?? 'failed',
                        'error' => $e->getMessage(),
                        'rollback_error' => $rollbackError,
                    ], 500);
            } finally {
                releaseDeployLock($lock);
            }
        }

        case 'restore': {
            requireMethod(['POST']);
            $deployId = param('deploy_id');
            if ($deployId !== '' && !validDeployId($deployId)) {
                respondJson(false, 'deploy_id is invalid.', ['code' => 'INVALID_DEPLOY_ID'], 400);
            }
            $ACTIVE_DEPLOY_ID = $deployId !== '' ? $deployId : null;

            $lock = acquireDeployLock();
            if ($lock === null) {
                respondJson(false, 'Another deployment operation is already running.', ['code' => 'DEPLOY_LOCKED'], 409);
            }
            try {
                $state = $deployId !== '' ? loadState($deployId) : null;
                $backupName = is_array($state) ? (($state['backup'] ?? null) ?: null) : latestBackupName();
                $hadPreviousManifest = is_array($state)
                    ? (bool)($state['had_previous_manifest'] ?? true)
                    : backupContainsManifest($backupName);
                $currentManifest = readManifest();

                if ($deployId !== '' && $state === null) {
                    respondJson(false, 'Deploy state was not found for rollback.', ['code' => 'STATE_NOT_FOUND', 'deploy_id' => $deployId], 404);
                }
                if ($backupName === null && $deployId === '') {
                    respondJson(false, 'No backup is available for rollback.', ['code' => 'NO_BACKUP'], 404);
                }

                serverLog('WARNING', 'Rollback started.', ['backup' => $backupName, 'current_manifest_count' => count($currentManifest)]);
                restoreBackup($backupName, $currentManifest, $hadPreviousManifest);
                if ($deployId !== '') {
                    saveState($deployId, [
                        'status' => 'rolled_back',
                        'rolled_back_at' => gmdate('c'),
                        'rollback_backup' => $backupName,
                    ]);
                }
                serverLog('WARNING', 'Rollback completed.', ['backup' => $backupName]);
                respondJson(true, 'Rollback completed successfully.', [
                    'deploy_id' => $deployId !== '' ? $deployId : null,
                    'status' => 'rolled_back',
                    'backup' => $backupName,
                ]);
            } finally {
                releaseDeployLock($lock);
            }
        }

        case 'cleanup': {
            requireMethod(['POST']);
            $file = basename(param('file'));
            $deployId = param('deploy_id');
            $removed = [];
            if ($file !== '') {
                $target = $ROOT . '/' . $file;
                if (is_file($target) && @unlink($target)) {
                    $removed[] = $file;
                }
            }
            foreach (glob($STAGING_DIR . '/*') ?: [] as $stage) {
                $mtime = filemtime($stage);
                if ($mtime !== false && $mtime < time() - 86400) {
                    try { removePath($stage); } catch (Throwable $e) { serverLog('WARNING', 'Unable to remove stale staging directory.', ['path' => basename($stage), 'error' => $e->getMessage()]); }
                }
            }
            rotateBackups();
            cleanupOldStates();
            serverLog('INFO', 'Cleanup completed.', ['removed' => $removed, 'requested_deploy_id' => $deployId]);
            respondJson(true, 'Cleanup completed.', ['removed' => $removed, 'deploy_id' => $deployId !== '' ? $deployId : null]);
        }

        default:
            respondJson(false, 'Unknown action.', ['code' => 'UNKNOWN_ACTION', 'action' => $ACTIVE_ACTION], 400);
    }
} catch (Throwable $e) {
    serverLog('ERROR', 'Unhandled deployment API exception.', ['error' => $e->getMessage(), 'type' => get_class($e)]);
    respondJson(false, 'Internal deployment API error.', [
        'code' => 'INTERNAL_ERROR',
        'error' => $e->getMessage(),
        'deploy_id' => $ACTIVE_DEPLOY_ID,
    ], 500);
}
