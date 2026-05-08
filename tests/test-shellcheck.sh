#!/bin/bash
# Runs shellcheck on every .sh script in the plugin and the two repo-level
# setup scripts the plugin packages.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_SCRIPTS="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts"

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "  shellcheck not installed; skipping (install via 'brew install shellcheck')"
    exit 77
fi

SCRIPTS=(
    "$PLUGIN_SCRIPTS/unraid-readonly-ssh-setup.sh"
    "$PLUGIN_SCRIPTS/claude-write-setup.sh"
    "$PLUGIN_SCRIPTS/install-runtime.sh"
    "$PLUGIN_SCRIPTS/uninstall-runtime.sh"
    "$ROOT/deploy.sh"
    "$ROOT/verify-install.sh"
)

# Acceptable warnings/info codes that are noise for our patterns:
#   SC2155 - declare and assign separately (cosmetic)
#   SC2002 - useless cat (we use it for clarity in some hook tests)
#   SC1091 - source path not following (we don't always source)
#   SC2029 - variable expands client-side in `ssh host "cmd $var"` — fine when
#            we control the variable (deploy.sh's $PLG is a fixed constant)
EXCLUDE="SC2155,SC2002,SC1091,SC2029"
FAIL=0

for s in "${SCRIPTS[@]}"; do
    if [ ! -f "$s" ]; then
        echo "  MISSING: $s"
        FAIL=1
        continue
    fi
    if ! shellcheck -e "$EXCLUDE" "$s"; then
        echo "  FAIL: $s"
        FAIL=1
    else
        echo "  ok: $(basename "$s")"
    fi
done

if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: shellcheck reported issues"
    exit 1
fi
echo "PASS: shellcheck clean"
