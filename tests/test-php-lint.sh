#!/bin/bash
# Runs `php -l` on the AJAX backend and on every .page file (which is just
# PHP-ish HTML with a frontmatter that we strip before linting).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v php >/dev/null 2>&1; then
    echo "  php not installed; skipping (install via 'brew install php')"
    exit 77
fi

EXEC="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/include/exec.php"
PAGES=(
    "$ROOT/src/usr/local/emhttp/plugins/claude-ssh/ClaudeSsh.page"
    "$ROOT/src/usr/local/emhttp/plugins/claude-ssh/ClaudeSshDashboard.page"
)

FAIL=0

# 1. exec.php — direct lint.
if ! php -l "$EXEC" >/dev/null; then
    echo "  FAIL: $EXEC"
    php -l "$EXEC"
    FAIL=1
else
    echo "  ok: include/exec.php"
fi

# 2. .page files — strip frontmatter (lines up to and including the `---`
# separator), then lint as PHP. Unraid pages are PHP with a header block.
for p in "${PAGES[@]}"; do
    TMP=$(mktemp -t pagelint-XXXXXX.php)
    awk 'BEGIN{strip=1} strip==1 && /^---$/ {strip=0; next} strip==0 {print}' "$p" > "$TMP"
    if ! php -l "$TMP" >/dev/null; then
        echo "  FAIL: $(basename "$p")"
        php -l "$TMP"
        FAIL=1
    else
        echo "  ok: $(basename "$p")"
    fi
    rm -f "$TMP"
done

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "PASS: php -l clean"
