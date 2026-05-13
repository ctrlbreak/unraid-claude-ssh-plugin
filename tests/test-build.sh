#!/bin/bash
# Verifies `make` produces a .txz that contains the expected paths.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/claude-ssh.txz"

# Clean any prior build to make sure we exercise a fresh path.
make -C "$ROOT" clean >/dev/null
if ! make -C "$ROOT" >/dev/null; then
    echo "FAIL: make failed"
    make -C "$ROOT"
    exit 1
fi
if [ ! -f "$PKG" ]; then
    echo "FAIL: $PKG not produced"
    exit 1
fi
echo "  built: $PKG ($(stat -c %s "$PKG" 2>/dev/null || stat -f %z "$PKG") bytes)"

EXPECTED=(
    "usr/local/emhttp/plugins/claude-ssh/ClaudeSsh.page"
    "usr/local/emhttp/plugins/claude-ssh/ClaudeSshDashboard.page"
    "usr/local/emhttp/plugins/claude-ssh/default.cfg"
    "usr/local/emhttp/plugins/claude-ssh/include/exec.php"
    "usr/local/emhttp/plugins/claude-ssh/scripts/install-runtime.sh"
    "usr/local/emhttp/plugins/claude-ssh/scripts/uninstall-runtime.sh"
    "usr/local/emhttp/plugins/claude-ssh/scripts/unraid-readonly-ssh-setup.sh"
    "usr/local/emhttp/plugins/claude-ssh/scripts/claude-write-setup.sh"
    "usr/local/emhttp/plugins/claude-ssh/LICENSE"
    "usr/local/emhttp/plugins/claude-ssh/claude-ssh.png"
    "usr/local/emhttp/plugins/claude-ssh/README.md"
)

LISTING=$(tar -tJf "$PKG" 2>/dev/null)
if [ -z "$LISTING" ]; then
    echo "FAIL: tar -tJf produced no output (corrupt archive?)"
    exit 1
fi

FAIL=0
for path in "${EXPECTED[@]}"; do
    if ! echo "$LISTING" | grep -qxF "$path"; then
        echo "  MISSING from .txz: $path"
        FAIL=1
    fi
done

if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: package missing expected paths"
    echo "Listing:"
    echo "$LISTING" | sed 's/^/  /'
    exit 1
fi

echo "  files in archive: $(echo "$LISTING" | wc -l | tr -d ' ')"
echo "PASS: build produced expected layout"
