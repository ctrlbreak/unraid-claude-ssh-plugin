#!/bin/bash
# Runs every test under tests/. Each test prints its own status line and
# exits non-zero on failure. This runner aggregates and reports.

set -u
cd "$(dirname "$0")"

TESTS=(
    test-plg-xml.sh
    test-shellcheck.sh
    test-php-lint.sh
    test-page-jquery.sh
    test-build.sh
    test-filter-regression.sh
    test-claude-write-validation.sh
    test-allowlist-config.sh
    test-boot-config-write-block.sh
    test-settings-save.sh
    test-username-configurable.sh
    test-idempotency.sh
    test-migration.sh
    test-upgrade-path.sh
    test-sudoers-drift.sh
    test-versions.sh
)

PASS=0
FAIL=0
SKIP=0
FAILED_TESTS=()

for t in "${TESTS[@]}"; do
    if [ ! -x "$t" ]; then
        echo "[SKIP] $t (not executable or missing)"
        SKIP=$((SKIP + 1))
        continue
    fi
    echo "=== $t ==="
    if bash "$t"; then
        PASS=$((PASS + 1))
    else
        rc=$?
        if [ "$rc" -eq 77 ]; then
            # Convention: tests exit 77 to signal SKIP (missing tool, etc.)
            SKIP=$((SKIP + 1))
        else
            FAIL=$((FAIL + 1))
            FAILED_TESTS+=("$t")
        fi
    fi
    echo ""
done

echo "==========================================="
echo "  $PASS passed · $FAIL failed · $SKIP skipped"
echo "==========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
exit 0
