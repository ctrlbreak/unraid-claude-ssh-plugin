#!/bin/bash
# Sandbox test for the `dashboard` AJAX action's JSON shape — the contract the
# Unraid dashboard tile reads on every 60s poll.
#
# Strategy mirrors test-settings-save.sh: include/exec.php's dispatcher
# early-returns under PHP CLI, so we can require_once it from a tiny PHP
# runner and invoke buildDashboard() directly with staged paths.
#
# Coverage:
#   - All top-level keys present (healthy, color, username, plugin_version,
#     filter_version, writer_version, health, activity_24h, allowlist).
#   - Versions parsed from the setup scripts (FILTER_VERSION / WRITER_VERSION).
#   - Plugin version parsed from .plg <!ENTITY version "...">.
#   - health sub-keys present with the right types (booleans + ssh_key_count int).
#   - activity_24h sub-keys present as ints (0 in the sandbox — no syslog).
#   - allowlist counts derive from the same load_allowlist_file() the Settings
#     UI uses (so the tile and editor cannot disagree).
#   - color/healthy stays consistent when health checks fail.
#   - Old keys (writes_24h, blocked_24h) are gone — no orphan compat shims.
#
# Skips with exit 77 if PHP isn't installed (matches test-php-lint.sh).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC_PHP="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/include/exec.php"

if ! command -v php >/dev/null 2>&1; then
    echo "  php not installed; skipping (install via 'brew install php')"
    exit 77
fi
[ -f "$EXEC_PHP" ] || { echo "FAIL: $EXEC_PHP not found"; exit 1; }

SANDBOX=$(mktemp -d -t claude-ssh-dashboard-XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

# Stage fake setup scripts. readVersionMarker() scans the first 200 lines for
# `VAR="vN"` so any prelude is fine.
mkdir -p "$SANDBOX/scripts"
cat > "$SANDBOX/scripts/unraid-readonly-ssh-setup.sh" << 'EOF'
#!/bin/bash
FILTER_VERSION="v99"
EOF
cat > "$SANDBOX/scripts/claude-write-setup.sh" << 'EOF'
#!/bin/bash
WRITER_VERSION="v42"
EOF

# Stage fake .plg. pluginVersion() reads <!ENTITY version "...">.
cat > "$SANDBOX/claude-ssh.plg" << 'EOF'
<!DOCTYPE PLUGIN [
  <!ENTITY name      "claude-ssh">
  <!ENTITY version   "test-version-9.9.9">
]>
<PLUGIN name="&name;" version="&version;"></PLUGIN>
EOF

# Stage fake runtime artifacts. buildDashboard() checks file_exists for each.
touch "$SANDBOX/filter.sh" "$SANDBOX/claude-write" "$SANDBOX/claude-write-priv" "$SANDBOX/sudoers"

# Stage authorized_keys with two valid keys + one comment (count should be 2).
cat > "$SANDBOX/authorized_keys" << 'EOF'
# leading comment, ignored
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAfakekey1 user1@example
ssh-rsa AAAAB3NzaC1yc2EAAAfakekey2 user2@example
EOF

# Stage allowlist with 3 plugins + 2 containers. load_allowlist_file() honours
# CLAUDE_SSH_ALLOWLIST_FILE.
cat > "$SANDBOX/allowlist.cfg" << 'EOF'
plugin foo
plugin bar
plugin baz
container sonarr
container radarr
EOF

# PHP harness — invokes buildDashboard() with the staged paths and dumps JSON.
cat > "$SANDBOX/run.php" << 'RUNNER'
<?php
require_once getenv('EXEC_PHP');

$paths = [
    'filter'          => getenv('PATH_FILTER'),
    'writer_wrapper'  => getenv('PATH_WRAPPER'),
    'writer_priv'     => getenv('PATH_PRIV'),
    'sudoers'         => getenv('PATH_SUDOERS'),
    'authorized_keys' => getenv('PATH_AUTH_KEYS'),
];
$scriptsDir = getenv('SCRIPTS_DIR');
$pluginPlg  = getenv('PLG');
$username   = getenv('USERNAME') ?: 'claude-test-no-such-user';

echo json_encode(buildDashboard($scriptsDir, $paths, $username, $pluginPlg));
RUNNER

export EXEC_PHP
export SCRIPTS_DIR="$SANDBOX/scripts"
export PLG="$SANDBOX/claude-ssh.plg"
export PATH_FILTER="$SANDBOX/filter.sh"
export PATH_WRAPPER="$SANDBOX/claude-write"
export PATH_PRIV="$SANDBOX/claude-write-priv"
export PATH_SUDOERS="$SANDBOX/sudoers"
export PATH_AUTH_KEYS="$SANDBOX/authorized_keys"
export CLAUDE_SSH_ALLOWLIST_FILE="$SANDBOX/allowlist.cfg"
# Username so unique that /etc/passwd on the dev box can't match it → user_exists
# deterministically false → healthy false → color red. Lets us pin the
# health/color logic without needing a sandboxed /etc/passwd.
export USERNAME="claude-ssh-test-no-such-user-xyzqq"

J=$(php "$SANDBOX/run.php")

PASS=0
FAIL=0
FAILED=()

assert_in() {
    local label="$1" needle="$2"
    if printf '%s' "$J" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$label: expected substring '$needle' in JSON")
    fi
}
assert_not_in() {
    local label="$1" needle="$2"
    if printf '%s' "$J" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        FAILED+=("$label: unexpected substring '$needle' in JSON")
    else
        PASS=$((PASS + 1))
    fi
}

# Versions parsed from setup scripts and .plg.
assert_in "filter_version=v99"            '"filter_version":"v99"'
assert_in "writer_version=v42"            '"writer_version":"v42"'
assert_in "plugin_version=test-version"   '"plugin_version":"test-version-9.9.9"'

# Username echoed back verbatim.
assert_in "username echoed"               '"username":"claude-ssh-test-no-such-user-xyzqq"'

# Health sub-keys present. Filter/writer/sudoers are true because the staged
# files exist; user_exists pinned false via the unique username.
assert_in "health.user_exists=false"      '"user_exists":false'
assert_in "health.filter_installed=true"  '"filter_installed":true'
assert_in "health.writer_installed=true"  '"writer_installed":true'
assert_in "health.sudoers_installed=true" '"sudoers_installed":true'
assert_in "health.ssh_key_count=2"        '"ssh_key_count":2'

# Activity sub-keys present as integers (0 in sandbox — no /var/log/syslog
# match, or empty grep output).
assert_in "activity.accepted=0"           '"accepted":0'
assert_in "activity.blocked=0"            '"blocked":0'
assert_in "activity.writes=0"             '"writes":0'
assert_in "activity.rejected=0"           '"rejected":0'

# Allowlist counts derived from staged fixture.
assert_in "allowlist.plugins=3"           '"plugins":3'
assert_in "allowlist.containers=2"        '"containers":2'

# Health rollup: user_exists=false → healthy=false → color=red.
assert_in "healthy=false"                 '"healthy":false'
assert_in "color=red"                     '"color":"red"'

# Compat shims must NOT linger — the dashboard tile rewrite drops them.
assert_not_in "writes_24h gone"           '"writes_24h"'
assert_not_in "blocked_24h gone"          '"blocked_24h"'

TOTAL=$((PASS + FAIL))
echo "  cases: $PASS passed / $FAIL failed / $TOTAL total"
if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: dashboard action JSON shape regressed:"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    echo "  JSON: $J"
    exit 1
fi
echo "PASS: dashboard action JSON shape"
