<?php
/* Shared CSRF helper for the claude-ssh Settings UI.
 *
 * Both sides use this single source so they can't disagree: the page
 * (ClaudeSsh.page) emits the token into the save_allowlist POST, and the AJAX
 * backend (include/exec.php) validates the POSTed token against it.
 *
 * We regex the token out of Unraid's state file rather than
 * parse_ini_file('/var/local/emhttp/var.ini'): other keys in that file can
 * carry values the default INI scanner mangles or rejects, which would make
 * the whole parse return empty and 403 every save. Reading just the
 * csrf_token line is immune to that, and it doesn't depend on emhttp having
 * populated $var in the including scope.
 */

function cs_csrf_token() {
    $ini = @file_get_contents('/var/local/emhttp/var.ini');
    if ($ini === false) return '';
    // Unraid writes values quoted, e.g.  csrf_token="ABCD1234..."
    if (preg_match('/^\s*csrf_token\s*=\s*"?([A-Za-z0-9]+)"?/m', $ini, $m)) {
        return $m[1];
    }
    return '';
}
