<?php
/* claude-ssh AJAX backend.
 *
 * Routes:
 *   status            - KPIs: user/filter/writer/sudoers state + versions
 *   system_state      - file inventory (path, mtime, size, sha256)
 *   recent_activity   - 24h syslog counts: RECV / BLOCKED / writes per category
 *   audit_log         - paginated syslog lines with date+tag filters
 *   load_allowlist    - read /mnt/user/appdata/claude-ssh/allowlist.cfg
 *   save_allowlist    - validate + atomically rewrite the allowlist
 *   dashboard         - compact summary for the dashboard tile
 *
 * Plain functions, no framework. Mirrors torrent-handler/include/exec.php style.
 *
 * Tests include this file via the PHP CLI; the dispatcher early-returns when
 * the SAPI is "cli" so test code can call helper functions directly without
 * bouncing off $_POST.
 */

// Allowlist path + name regex must match the filter (unraid-readonly-ssh-setup.sh)
// and writer (claude-write-setup.sh). Drift here lets the UI accept names the
// runtime would reject (or vice versa). test-claude-write-validation.sh
// asserts these constants stay in sync with the shell side.
const CS_NAME_REGEX = '/^[a-z][a-z0-9-]{0,63}$/';

// SSH username regex (POSIX-ish): start with a-z, then a-z0-9- up to 32 chars.
// Same regex used by the four shell scripts' cs_resolve_username function.
const CS_USERNAME_REGEX = '/^[a-z][a-z0-9-]{0,31}$/';

function cs_allowlist_path() {
    $env = getenv('CLAUDE_SSH_ALLOWLIST_FILE');
    // Default canonical location: /mnt/user/appdata/claude-ssh/allowlist.cfg
    // (on the array, mode 644, readable by the constrained SSH user). The
    // file used to live in /boot/config/plugins/claude-ssh/ but /boot is
    // FAT-mounted with dmask=0077, so the filter couldn't read it. Stays in
    // lockstep with the shell-side default in the filter + writer setup
    // scripts; test-claude-write-validation.sh asserts the parity.
    return $env !== false && $env !== '' ? $env : '/mnt/user/appdata/claude-ssh/allowlist.cfg';
}

// Resolve the configured SSH username. Mirrors cs_resolve_username in the
// shell scripts: env var → /boot/config/plugins/claude-ssh/username → "claude".
// Invalid values fall back to "claude" so the Status page never reports paths
// derived from a malformed config.
function cs_username() {
    $env = getenv('CLAUDE_SSH_USERNAME');
    if ($env !== false && $env !== '' && preg_match(CS_USERNAME_REGEX, $env)) {
        return $env;
    }
    $file = '/boot/config/plugins/claude-ssh/username';
    if (is_readable($file)) {
        $val = trim((string)@file_get_contents($file));
        if ($val !== '' && preg_match(CS_USERNAME_REGEX, $val)) {
            return $val;
        }
    }
    return 'claude';
}

// CSRF guard for STATE-CHANGING actions. save_allowlist controls the SSH write
// blast radius, so it must not be driveable cross-site; read-only actions are
// side-effect-free and ungated. The expected token comes from the shared
// cs_csrf_token() helper (include/csrf.php) — the SAME source the page uses to
// emit the token, so they can't disagree. hash_equals keeps the compare
// constant-time. The CLI test path never reaches the dispatcher (see the
// php_sapi_name guard below), so this doesn't run there.
require_once __DIR__ . '/csrf.php';
function cs_csrf_ok() {
    $expected = cs_csrf_token();
    if ($expected === '') return false;
    // PHP collapses duplicate POST keys to the LAST value, and Unraid's dynamix
    // ajax wrapper appends its OWN csrf_token to every POST — on this page that
    // appended copy arrives empty and clobbers the valid token the page sent
    // earlier in the body. So scan EVERY csrf_token in the raw body and accept
    // if any one matches (urlencoded form body; reading php://input does not
    // disturb the already-parsed $_POST used by save_allowlist below).
    $raw = (string)@file_get_contents('php://input');
    foreach (explode('&', $raw) as $pair) {
        $eq = strpos($pair, '=');
        if ($eq === false || substr($pair, 0, $eq) !== 'csrf_token') continue;
        $val = urldecode(substr($pair, $eq + 1));
        if ($val !== '' && hash_equals($expected, $val)) return true;
    }
    // Normal single-token case (no duplicate / non-form body).
    $sent = isset($_POST['csrf_token']) ? (string)$_POST['csrf_token'] : '';
    return $sent !== '' && hash_equals($expected, $sent);
}

// CLI guard: skip the request dispatcher when we're invoked from PHP CLI
// (i.e. from a test). Helper functions above remain callable.
if (php_sapi_name() === 'cli') return;

// Keep warnings/notices out of the response — any HTML before the JSON body
// breaks the client's `$.post(..., 'json')` parse, leaving the UI stuck on
// "Loading..." forever. We use @ on file reads but display_errors can still
// dump warnings from things like file_exists on root-only paths.
@ini_set('display_errors', '0');
error_reporting(0);

// Last-chance JSON wrapper: if anything fatal escapes a try, send something
// the client can render instead of an HTML error page.
register_shutdown_function(function () {
    $err = error_get_last();
    if ($err && in_array($err['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR], true)) {
        if (!headers_sent()) {
            header('Content-Type: application/json');
            http_response_code(500);
        }
        echo json_encode(['error' => 'php_fatal', 'message' => $err['message']]);
    }
});

$plugin     = 'claude-ssh';
$pluginDir  = "/usr/local/emhttp/plugins/$plugin";
$scriptsDir = "$pluginDir/scripts";
$pluginPlg  = "/var/log/plugins/$plugin.plg";

// Runtime-deployed file paths (written by the setup scripts on the NAS).
// /home/<user>/ paths track the configured SSH username so the Status page
// reflects whatever username install-runtime.sh resolved.
$cs_user = cs_username();
$paths = [
    'filter'          => "/home/$cs_user/shell-filter.sh",
    'writer_wrapper'  => '/usr/local/bin/claude-write',
    'writer_priv'     => '/usr/local/sbin/claude-write-priv',
    'sudoers'         => '/etc/sudoers.d/claude-write',
    'authorized_keys' => "/home/$cs_user/.ssh/authorized_keys",
];

$action = $_POST['action'] ?? '';

header('Content-Type: application/json');

switch ($action) {

case 'status':
    echo json_encode(buildStatus($scriptsDir, $pluginPlg, $paths, $cs_user));
    break;

case 'system_state':
    echo json_encode(buildSystemState($paths, $scriptsDir));
    break;

case 'recent_activity':
    echo json_encode(buildRecentActivity());
    break;

case 'audit_log':
    $dateFilter = $_POST['date_filter'] ?? 'today';
    $tagFilter  = $_POST['tag_filter']  ?? 'all';
    $maxLines   = (int)($_POST['max_lines'] ?? 500);
    if ($maxLines < 1)    $maxLines = 1;
    if ($maxLines > 2000) $maxLines = 2000;
    echo json_encode(buildAuditLog($dateFilter, $tagFilter, $maxLines));
    break;

case 'load_allowlist':
    echo json_encode(load_allowlist_file());
    break;

case 'save_allowlist':
    // State-changing: require a valid CSRF token (see cs_csrf_ok).
    if (!cs_csrf_ok()) {
        http_response_code(403);
        echo json_encode(['ok' => false, 'errors' => ['CSRF token missing or invalid — reload the Settings page and try again']]);
        break;
    }
    $plugins    = $_POST['plugins']    ?? '';
    $containers = $_POST['containers'] ?? '';
    $result = save_allowlist_file($plugins, $containers);
    if (empty($result['ok'])) http_response_code(400);
    echo json_encode($result);
    break;

case 'dashboard':
    echo json_encode(buildDashboard($scriptsDir, $paths, $cs_user, $pluginPlg));
    break;

default:
    http_response_code(400);
    echo json_encode(['error' => "unknown action '$action'"]);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Read a shell-variable assignment of the form `VAR="vN"` or `VAR=vN` from
// the top of a setup script. This is the single source of truth for the
// filter and writer runtime contract versions — same value the script uses
// for its install banner, so the Status page can't drift from what was
// printed at install time.
function readVersionMarker($path, $varName) {
    if (!is_readable($path)) return null;
    $h = @fopen($path, 'r');
    if (!$h) return null;
    $version = null;
    $lines = 0;
    while (($line = fgets($h)) !== false && $lines < 200) {
        $lines++;
        if (preg_match('/^\s*' . preg_quote($varName, '/') . '="?(v\d+(?:\.\d+)*)"?\s*$/', $line, $m)) {
            $version = $m[1];
            break;
        }
    }
    fclose($h);
    return $version;
}

function fileMeta($path) {
    if (!file_exists($path)) {
        return ['exists' => false];
    }
    return [
        'exists' => true,
        'path'   => $path,
        'size'   => @filesize($path) ?: 0,
        'mtime'  => @date('c', @filemtime($path) ?: 0),
        'sha256' => is_readable($path) ? @hash_file('sha256', $path) : null,
        'mode'   => substr(sprintf('%o', @fileperms($path) ?: 0), -4),
    ];
}

function pluginVersion($plgPath) {
    if (!is_readable($plgPath)) return null;
    $contents = @file_get_contents($plgPath);
    if (!$contents) return null;
    if (preg_match('/<!ENTITY\s+version\s+"([^"]+)"\s*>/', $contents, $m)) {
        return $m[1];
    }
    return null;
}

function sshKeyCount($authorizedKeysPath) {
    if (!is_readable($authorizedKeysPath)) return 0;
    $contents = @file_get_contents($authorizedKeysPath);
    if ($contents === false) return 0;
    $count = 0;
    foreach (explode("\n", $contents) as $line) {
        if (preg_match('/\bssh-(rsa|ed25519|ecdsa|dss)\b/', $line)) $count++;
    }
    return $count;
}

function buildStatus($scriptsDir, $pluginPlg, $paths, $username = 'claude') {
    // Versions: read from the canonical source scripts that the plugin packages.
    // The runtime filter at /home/<user>/shell-filter.sh is an expansion of the
    // setup script's heredoc — same logic, different path.
    $filterVer = readVersionMarker("$scriptsDir/unraid-readonly-ssh-setup.sh", 'FILTER_VERSION');
    $writerVer = readVersionMarker("$scriptsDir/claude-write-setup.sh",       'WRITER_VERSION');
    $pluginVer = pluginVersion($pluginPlg);

    // User existence: check /etc/passwd directly (no need to fork id).
    $passwd = @file_get_contents('/etc/passwd');
    $userExists = $passwd !== false && (bool)preg_match('/^' . preg_quote($username, '/') . ':/m', $passwd);

    // Sudoers presence: either the .d fragment or the appended block in /etc/sudoers.
    $sudoersFragment = file_exists($paths['sudoers']);
    $sudoersInline   = false;
    $mainSudoers = @file_get_contents('/etc/sudoers');
    if ($mainSudoers !== false && strpos($mainSudoers, 'claude-write deploy channel') !== false) {
        $sudoersInline = true;
    }

    $filterMeta  = fileMeta($paths['filter']);
    $wrapperMeta = fileMeta($paths['writer_wrapper']);
    $privMeta    = fileMeta($paths['writer_priv']);

    $health = [
        'user_exists'      => $userExists,
        'filter_installed' => !empty($filterMeta['exists']),
        'wrapper_installed'=> !empty($wrapperMeta['exists']),
        'priv_installed'   => !empty($privMeta['exists']),
        'sudoers_installed'=> $sudoersFragment || $sudoersInline,
    ];
    $allHealthy = !in_array(false, $health, true);

    return [
        'plugin_version'  => $pluginVer,
        'filter_version'  => $filterVer,
        'writer_version'  => $writerVer,
        'username'        => $username,
        'health'          => $health,
        'all_healthy'     => $allHealthy,
        'ssh_key_count'   => sshKeyCount($paths['authorized_keys']),
        'sudoers'         => [
            'fragment_path'    => $paths['sudoers'],
            'fragment_present' => $sudoersFragment,
            'inline_present'   => $sudoersInline,
        ],
    ];
}

function buildSystemState($paths, $scriptsDir) {
    $state = [];
    foreach ($paths as $name => $path) {
        $state[$name] = fileMeta($path);
    }
    // Also include the source scripts the plugin packages, so the user can see
    // both the canonical source and the deployed runtime artifacts side-by-side.
    $state['source_filter_setup'] = fileMeta("$scriptsDir/unraid-readonly-ssh-setup.sh");
    $state['source_writer_setup'] = fileMeta("$scriptsDir/claude-write-setup.sh");
    return ['files' => $state];
}

function buildRecentActivity() {
    // Window: last 24h. Implementation: grep current /var/log/syslog.
    // Older entries are in rotated logs (.1, .2.gz, ...) — out of scope for v1.
    $syslog = '/var/log/syslog';
    if (!is_readable($syslog)) {
        return ['error' => 'syslog not readable', 'window_hours' => 24];
    }

    // Build a date prefix list for the last 24h. Syslog timestamps come in two
    // shapes: ISO ("2026-05-04T...") or BSD ("May  4 10:23:45"). We'll scan
    // for our tags and filter by mtime since 24h ago using a coarse cutoff.
    $cutoff = time() - 86400;

    $counts = [
        'window_hours'   => 24,
        'filter_recv'    => 0,
        'filter_blocked' => 0,
        'writes_total'   => 0,
        'writes_rejected'=> 0,
        'writes_per_category' => [
            'scratch'        => 0,
            'plugin-file'    => 0,
            'appdata-script' => 0,
        ],
    ];

    // Use grep + tail in one shell call to avoid parsing the entire syslog
    // in PHP. Bound output at 50k matching lines just in case.
    $cmd = "grep -E 'claude-(shell|write)' " . escapeshellarg($syslog) . " 2>/dev/null | tail -n 50000";
    $output = @shell_exec($cmd);
    if (!$output) return $counts;

    foreach (explode("\n", $output) as $line) {
        if ($line === '') continue;
        $ts = parseSyslogTime($line);
        if ($ts !== null && $ts < $cutoff) continue;

        if (strpos($line, 'claude-shell') !== false) {
            if (strpos($line, 'RECV:')    !== false) $counts['filter_recv']++;
            if (strpos($line, 'BLOCKED')  !== false) $counts['filter_blocked']++;
        } elseif (strpos($line, 'claude-write') !== false) {
            if (preg_match('/WROTE category=([a-z-]+)/', $line, $m)) {
                $counts['writes_total']++;
                if (isset($counts['writes_per_category'][$m[1]])) {
                    $counts['writes_per_category'][$m[1]]++;
                }
            } elseif (strpos($line, 'REJECTED') !== false) {
                $counts['writes_rejected']++;
            }
        }
    }
    return $counts;
}

function buildAuditLog($dateFilter, $tagFilter, $maxLines) {
    $syslog = '/var/log/syslog';
    if (!is_readable($syslog)) {
        return ['error' => 'syslog not readable', 'lines' => []];
    }

    // Build cutoff timestamp.
    $now = time();
    $cutoff = null;
    switch ($dateFilter) {
        case 'today':     $cutoff = strtotime('today 00:00:00');         break;
        case 'yesterday': $cutoff = strtotime('yesterday 00:00:00');     break;
        case '7days':     $cutoff = $now - 7 * 86400;                    break;
        default:          $cutoff = strtotime('today 00:00:00');
    }

    $tagPattern = '';
    switch ($tagFilter) {
        case 'claude-shell': $tagPattern = 'claude-shell';           break;
        case 'claude-write': $tagPattern = 'claude-write';           break;
        case 'sudo':         $tagPattern = 'sudo.*claude-write-priv';break;
        default:             $tagPattern = 'claude-(shell|write)|sudo.*claude-write-priv';
    }

    $cmd = "grep -E " . escapeshellarg($tagPattern) . " " . escapeshellarg($syslog)
         . " 2>/dev/null | tail -n " . (int)max($maxLines * 4, 2000);
    $output = @shell_exec($cmd);
    if (!$output) return ['lines' => []];

    $rows = [];
    foreach (explode("\n", $output) as $line) {
        if ($line === '') continue;
        $ts = parseSyslogTime($line);
        if ($ts !== null && $cutoff !== null && $ts < $cutoff) continue;
        $rows[] = [
            'timestamp' => $ts ? date('c', $ts) : null,
            'raw'       => $line,
        ];
    }
    // Trim to maxLines (most recent N).
    if (count($rows) > $maxLines) {
        $rows = array_slice($rows, -$maxLines);
    }
    return [
        'date_filter' => $dateFilter,
        'tag_filter'  => $tagFilter,
        'count'       => count($rows),
        'lines'       => $rows,
    ];
}

function buildDashboard($scriptsDir, $paths, $username = 'claude', $pluginPlg = null) {
    $filterVer = readVersionMarker("$scriptsDir/unraid-readonly-ssh-setup.sh", 'FILTER_VERSION');
    $writerVer = readVersionMarker("$scriptsDir/claude-write-setup.sh",       'WRITER_VERSION');
    $pluginVer = $pluginPlg !== null ? pluginVersion($pluginPlg) : null;

    $userExists = false;
    $passwd = @file_get_contents('/etc/passwd');
    if ($passwd !== false) $userExists = (bool)preg_match('/^' . preg_quote($username, '/') . ':/m', $passwd);

    $filterPresent  = file_exists($paths['filter']);
    $writerPresent  = file_exists($paths['writer_wrapper']) && file_exists($paths['writer_priv']);
    $sudoersPresent = file_exists($paths['sudoers']);
    if (!$sudoersPresent) {
        $main = @file_get_contents('/etc/sudoers');
        if ($main !== false && strpos($main, 'claude-write deploy channel') !== false) {
            $sudoersPresent = true;
        }
    }
    $sshKeys = sshKeyCount($paths['authorized_keys']);

    $healthy = $userExists && $filterPresent && $writerPresent && $sudoersPresent;

    // 24h activity for the tile: one syslog pass, four counters. Mirrors the
    // shape buildRecentActivity() uses (and its line-classification rules) so
    // the tile and the Settings page can't disagree on what an "accepted" or
    // "rejected" line is.
    $accepted = 0;
    $blocked  = 0;
    $writes   = 0;
    $rejected = 0;
    $cutoff = time() - 86400;
    $cmd = "grep -E 'claude-(shell|write)' /var/log/syslog 2>/dev/null | tail -n 50000";
    $output = @shell_exec($cmd);
    if ($output) {
        foreach (explode("\n", $output) as $line) {
            if ($line === '') continue;
            $ts = parseSyslogTime($line);
            if ($ts !== null && $ts < $cutoff) continue;
            if (strpos($line, 'claude-shell') !== false) {
                if (strpos($line, 'BLOCKED') !== false) {
                    $blocked++;
                } elseif (strpos($line, 'RECV:') !== false) {
                    $accepted++;
                }
            } elseif (strpos($line, 'claude-write') !== false) {
                if (strpos($line, 'WROTE') !== false) {
                    $writes++;
                } elseif (strpos($line, 'REJECTED') !== false) {
                    $rejected++;
                }
            }
        }
    }

    // Allowlist counts: reuse the Settings-page loader so the tile can't drift
    // from what the editor shows. Invalid entries don't count (Settings UI
    // surfaces them separately).
    $allowlist = load_allowlist_file();

    $color = 'green';
    if (!$healthy) $color = 'red';
    elseif ($blocked > 0) $color = 'amber';

    return [
        'healthy'        => $healthy,
        'color'          => $color,
        'username'       => $username,
        'plugin_version' => $pluginVer,
        'filter_version' => $filterVer,
        'writer_version' => $writerVer,
        'health' => [
            'user_exists'       => $userExists,
            'filter_installed'  => $filterPresent,
            'writer_installed'  => $writerPresent,
            'sudoers_installed' => $sudoersPresent,
            'ssh_key_count'     => $sshKeys,
        ],
        'activity_24h' => [
            'accepted' => $accepted,
            'blocked'  => $blocked,
            'writes'   => $writes,
            'rejected' => $rejected,
        ],
        'allowlist' => [
            'plugins'    => count($allowlist['plugins']),
            'containers' => count($allowlist['containers']),
        ],
    ];
}

// ---------------------------------------------------------------------------
// Allowlist load/save (Settings UI)
// ---------------------------------------------------------------------------

function cs_normalise_names($input) {
    // Accepts: array of strings, comma-list, or newline-list. Returns trimmed,
    // non-empty array. Splits on whitespace AND commas so the textareas are
    // tolerant of either separator.
    if (is_array($input)) {
        $arr = $input;
    } elseif (is_string($input)) {
        $arr = preg_split('/[\s,]+/', $input);
    } else {
        $arr = [];
    }
    $out = [];
    foreach ($arr as $item) {
        $t = trim((string)$item);
        if ($t !== '') $out[] = $t;
    }
    return $out;
}

function cs_allowlist_header() {
    return <<<HEADER
# claude-ssh allowlist — runtime config for the claude-write deploy channel.
#
# CANONICAL LOCATION: /mnt/user/appdata/claude-ssh/allowlist.cfg
# Lives on the array (mode 644) because /boot is FAT-mounted with dmask=0077
# (kernel-forced mode 700 on every dir), which would block the constrained
# SSH user from reading the file. The filter + writer read this path on
# every invocation.
#
# Edited via the Settings UI. Manual edits to comments or unrelated lines are
# overwritten when this file is saved from the UI; edit the file directly to
# preserve them.
#
# Format:
#   plugin <name>      Allow plugin-* writes for /usr/local/emhttp/plugins/<name>/
#   container <name>   Allow appdata-script writes for /mnt/user/appdata/<name>/scripts/
#
# Names must match: ^[a-z][a-z0-9-]{0,63}$  (lowercase, digits, hyphen)

HEADER;
}

function load_allowlist_file($path = null) {
    if ($path === null) $path = cs_allowlist_path();
    $base = [
        'path'               => $path,
        'exists'             => false,
        'plugins'            => [],
        'containers'         => [],
        'invalid_plugins'    => [],
        'invalid_containers' => [],
        'raw_size'           => 0,
        'raw_mtime'          => null,
    ];
    if (!is_readable($path)) return $base;
    $contents = @file_get_contents($path);
    if ($contents === false) return $base;
    $base['exists']    = true;
    $base['raw_size']  = strlen($contents);
    $base['raw_mtime'] = @date('c', @filemtime($path) ?: 0);

    $plugins = $containers = $invPlugins = $invContainers = [];
    foreach (explode("\n", $contents) as $line) {
        $trimmed = trim($line);
        if ($trimmed === '' || $trimmed[0] === '#') continue;
        // Match "<kind> <name>" — same shape the awk parser sees (NF == 2).
        if (preg_match('/^(plugin|container)\s+(\S+)\s*$/', $trimmed, $m)) {
            $kind = $m[1];
            $name = $m[2];
            $valid = (bool)preg_match(CS_NAME_REGEX, $name);
            if ($kind === 'plugin') {
                if ($valid) $plugins[] = $name; else $invPlugins[] = $name;
            } else {
                if ($valid) $containers[] = $name; else $invContainers[] = $name;
            }
        }
    }
    $base['plugins']            = array_values(array_unique($plugins));
    $base['containers']         = array_values(array_unique($containers));
    $base['invalid_plugins']    = array_values(array_unique($invPlugins));
    $base['invalid_containers'] = array_values(array_unique($invContainers));
    return $base;
}

function save_allowlist_file($plugins, $containers, $path = null) {
    if ($path === null) $path = cs_allowlist_path();
    $plugins    = cs_normalise_names($plugins);
    $containers = cs_normalise_names($containers);

    $errors = [];
    foreach ($plugins as $n) {
        if (!preg_match(CS_NAME_REGEX, $n)) {
            $errors[] = "invalid plugin name: '" . $n . "' (must match ^[a-z][a-z0-9-]{0,63}$)";
        }
    }
    foreach ($containers as $n) {
        if (!preg_match(CS_NAME_REGEX, $n)) {
            $errors[] = "invalid container name: '" . $n . "' (must match ^[a-z][a-z0-9-]{0,63}$)";
        }
    }
    if (!empty($errors)) return ['ok' => false, 'errors' => $errors];

    $plugins    = array_values(array_unique($plugins));
    $containers = array_values(array_unique($containers));

    $body = cs_allowlist_header();
    if (count($plugins) > 0) {
        $body .= "\n# Plugins\n";
        foreach ($plugins as $n) $body .= "plugin $n\n";
    }
    if (count($containers) > 0) {
        $body .= "\n# Containers\n";
        foreach ($containers as $n) $body .= "container $n\n";
    }

    $dir = dirname($path);
    if (!is_dir($dir)) {
        if (!@mkdir($dir, 0755, true)) {
            return ['ok' => false, 'errors' => ["could not create directory: $dir"]];
        }
    }

    // Atomic write: temp file in same dir, rename. Same-dir is required so
    // the rename is atomic on the same filesystem (cross-FS rename falls back
    // to copy+unlink, which has a window where a reader sees a partial file).
    $tmp = $path . '.tmp.' . getmypid();
    if (@file_put_contents($tmp, $body, LOCK_EX) === false) {
        return ['ok' => false, 'errors' => ["could not write temp file: $tmp"]];
    }
    @chmod($tmp, 0644);
    if (!@rename($tmp, $path)) {
        @unlink($tmp);
        return ['ok' => false, 'errors' => ["could not rename $tmp to $path"]];
    }

    return [
        'ok'         => true,
        'path'       => $path,
        'plugins'    => $plugins,
        'containers' => $containers,
        'raw_mtime'  => @date('c', @filemtime($path) ?: 0),
    ];
}

function parseSyslogTime($line) {
    // ISO 8601: 2026-05-04T10:23:45.123+00:00
    if (preg_match('/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)/', $line, $m)) {
        $ts = strtotime($m[1]);
        return $ts !== false ? $ts : null;
    }
    // BSD format: "May  4 10:23:45 host tag: ..."
    if (preg_match('/^([A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s/', $line, $m)) {
        $ts = strtotime($m[1]);
        return $ts !== false ? $ts : null;
    }
    return null;
}
