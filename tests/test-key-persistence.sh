#!/bin/bash
# authorized_keys reboot-persistence — cs_seed_authorized_keys().
#
# Unraid rebuilds /home from RAM on every boot, so a pubkey added only to the
# live /home/<user>/.ssh/authorized_keys is lost on the first reboot. The fix
# keeps the canonical copy on flash (/boot/config/plugins/claude-ssh/
# authorized_keys) and re-seeds the live file from it on each boot.
#
# Coverage:
#   1. Reseed: bare flash key(s) -> live file wrapped with the command= filter
#      restriction (single + multiple, ordering preserved).
#   2. Capture: a legacy live-only key is lifted to flash ONLY when flash is
#      empty; a command= prefix is stripped during capture.
#   3. Flash is authoritative: a live-only key not in flash is dropped on reseed.
#   4. Flash hygiene: blank lines and # comments skipped; wrapped lines in flash
#      are normalised (not double-wrapped).
#   5. Empty flash + empty live -> NEXT STEP guidance, live left empty.
#   6. Idempotency: re-running yields a byte-identical live file (boot re-runs it).
#   7. Structure: the source script defines + calls the function and defaults the
#      flash path to /boot/config/plugins/claude-ssh/authorized_keys.
#
# Purely behavioural — no root/NAS/docker. The function is extracted from the
# source script and run in a sandbox with controlled globals + file fixtures.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_SCRIPTS="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts"
SETUP="$PLUGIN_SCRIPTS/unraid-readonly-ssh-setup.sh"

if [ ! -f "$SETUP" ]; then
    echo "FAIL: $SETUP not found"
    exit 1
fi

PASS=0
FAIL=0
FAILED=()

# Extract the cs_seed_authorized_keys function body (block from its opening
# `cs_seed_authorized_keys() {` to the matching `}` at column 0).
extract_fn() {
    awk '
        /^cs_seed_authorized_keys\(\) \{$/ { capturing=1 }
        capturing { print }
        capturing && /^\}$/ { exit }
    ' "$SETUP"
}

FN=$(extract_fn)
if [ -z "$FN" ]; then
    echo "FAIL: cs_seed_authorized_keys() not found in $SETUP"
    exit 1
fi

WORK=$(mktemp -d -t claude-ssh-keys-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

RUNNER="$WORK/runner.sh"
{
    echo '#!/bin/bash'
    echo 'set -uo pipefail'
    echo "$FN"
    echo 'cs_seed_authorized_keys'
} > "$RUNNER"

# Expected wrapped line for key $2 with filter $1.
wrap() {
    printf 'command="%s",no-port-forwarding,no-agent-forwarding,no-X11-forwarding %s' "$1" "$2"
}

fail() { FAIL=$((FAIL + 1)); FAILED+=("$1"); }
ok()   { PASS=$((PASS + 1)); }

assert_eq() { # label expected actual
    if [ "$2" = "$3" ]; then ok; else fail "$1: expected [$2] got [$3]"; fi
}
assert_contains() { # label needle haystack
    case "$3" in *"$2"*) ok ;; *) fail "$1: missing [$2] in [$3]" ;; esac
}
assert_not_contains() { # label needle haystack
    case "$3" in *"$2"*) fail "$1: unexpected [$2] in [$3]" ;; *) ok ;; esac
}

# Run the function in a fresh sandbox. Args: <live-content|__none__> <flash-content|__none__> [filter-path]
# Echoes nothing; sets globals SB, AK, PK, OUT for the caller to inspect.
SB=""; AK=""; PK=""; OUT=""; FLT=""
run_seed() {
    local live="$1" flash="$2" filter="${3:-}"
    SB=$(mktemp -d "$WORK/sb-XXXXXX")
    mkdir -p "$SB/home/.ssh"
    FLT="${filter:-$SB/home/shell-filter.sh}"
    AK="$SB/home/.ssh/authorized_keys"
    PK="$SB/flash/authorized_keys"
    if [ "$live" != "__none__" ]; then printf '%s' "$live" > "$AK"; fi
    if [ "$flash" != "__none__" ]; then
        mkdir -p "$SB/flash"
        printf '%s' "$flash" > "$PK"
    fi
    OUT=$(HOME_DIR="$SB/home" FILTER_SCRIPT="$FLT" PERSIST_KEYS="$PK" bash "$RUNNER" 2>&1)
}

# === 1. Reseed: single bare flash key -> live wrapped ===
run_seed "__none__" "ssh-ed25519 AAAAKEY1 alice
"
ak=$(cat "$AK")
assert_eq "reseed-single" "$(wrap "$FLT" "ssh-ed25519 AAAAKEY1 alice")" "$ak"
assert_eq "reseed-single-linecount" "1" "$(grep -c 'command=' "$AK")"

# === 1b. Reseed: multiple flash keys -> two wrapped lines, order preserved ===
run_seed "__none__" "ssh-ed25519 AAAAKEY1 alice
ssh-rsa AAAAKEY2 bob
"
assert_eq "reseed-multi-linecount" "2" "$(grep -c 'command=' "$AK")"
assert_contains "reseed-multi-alice" "AAAAKEY1 alice" "$(cat "$AK")"
assert_contains "reseed-multi-bob" "AAAAKEY2 bob" "$(cat "$AK")"
# First wrapped line is alice (ordering preserved).
assert_contains "reseed-multi-order" "AAAAKEY1 alice" "$(head -n1 "$AK")"

# === 2. Capture: legacy live-only key lifted to flash when flash empty ===
run_seed "ssh-ed25519 AAAAKEY3 carol
" "__none__"
assert_eq "capture-flash-written" "ssh-ed25519 AAAAKEY3 carol" "$(cat "$PK")"
assert_eq "capture-live-wrapped" "$(wrap "$FLT" "ssh-ed25519 AAAAKEY3 carol")" "$(cat "$AK")"
assert_contains "capture-output-note" "Captured existing pubkey" "$OUT"

# === 2b. Capture strips an existing command= prefix when lifting to flash ===
old_wrapped=$(wrap "/old/shell-filter.sh" "ssh-ed25519 AAAAKEY4 dave")
run_seed "$old_wrapped
" "__none__" "/home/bob/shell-filter.sh"
# Flash gets the BARE key (no command= prefix).
assert_eq "capture-strip-flash" "ssh-ed25519 AAAAKEY4 dave" "$(cat "$PK")"
# Live is re-wrapped with the CURRENT filter path, not the old one.
assert_contains "capture-strip-newfilter" 'command="/home/bob/shell-filter.sh"' "$(cat "$AK")"
assert_not_contains "capture-strip-oldfilter" '/old/shell-filter.sh' "$(cat "$AK")"
assert_eq "capture-strip-linecount" "1" "$(grep -c 'command=' "$AK")"

# === 3. Flash authoritative: live-only key dropped on reseed ===
# Flash has only keyA; live has wrapped keyA + a stray wrapped keyB.
flt="$WORK/flt.sh"
run_seed "$(wrap "$flt" "ssh-ed25519 AAAAKEYA ann")
$(wrap "$flt" "ssh-ed25519 AAAAKEYB ben")
" "ssh-ed25519 AAAAKEYA ann
" "$flt"
assert_eq "authoritative-linecount" "1" "$(grep -c 'command=' "$AK")"
assert_contains "authoritative-keepsA" "AAAAKEYA ann" "$(cat "$AK")"
assert_not_contains "authoritative-dropsB" "AAAAKEYB" "$(cat "$AK")"
# Flash was NOT overwritten from live (still just keyA).
assert_eq "authoritative-flash-untouched" "ssh-ed25519 AAAAKEYA ann" "$(cat "$PK")"

# === 4. Flash hygiene: comments + blank lines skipped ===
run_seed "__none__" "# a leading comment

ssh-ed25519 AAAAKEY5 erin
# trailing comment
"
assert_eq "hygiene-linecount" "1" "$(grep -c 'command=' "$AK")"
assert_contains "hygiene-key" "AAAAKEY5 erin" "$(cat "$AK")"
assert_not_contains "hygiene-no-comment" "a leading comment" "$(cat "$AK")"

# === 5. Empty flash + empty live -> NEXT STEP, live empty ===
run_seed "__none__" "__none__"
assert_eq "empty-no-keys" "0" "$(grep -c 'command=' "$AK")"
assert_contains "empty-next-step" "NEXT STEP" "$OUT"
# Flash stays empty/absent (nothing to capture).
if [ ! -s "$PK" ]; then ok; else fail "empty-flash-stays-empty: flash unexpectedly populated"; fi

# === 6. Idempotency: re-running yields a byte-identical live file ===
run_seed "__none__" "ssh-ed25519 AAAAKEY6 fred
"
first=$(cat "$AK")
# Re-run against the SAME sandbox (flash already populated, live now wrapped).
OUT=$(HOME_DIR="$SB/home" FILTER_SCRIPT="$FLT" PERSIST_KEYS="$PK" bash "$RUNNER" 2>&1)
second=$(cat "$AK")
assert_eq "idempotent-identical" "$first" "$second"
assert_eq "idempotent-linecount" "1" "$(grep -c 'command=' "$AK")"

# === 7. Structure: source script defines + calls the function, flash default ===
if grep -qE '^cs_seed_authorized_keys\(\) \{$' "$SETUP"; then ok; else fail "structure: function not defined"; fi
if grep -qE '^cs_seed_authorized_keys$' "$SETUP"; then ok; else fail "structure: function not called"; fi
if grep -qF 'PERSIST_KEYS="/boot/config/plugins/claude-ssh/authorized_keys"' "$SETUP"; then
    ok
else
    fail "structure: PERSIST_KEYS default not the flash path"
fi
# The old interactive prompt must be gone (replaced by the flash flow).
if grep -qF 'paste the public key here' "$SETUP"; then
    fail "structure: legacy 'paste the public key here' prompt still present"
else
    ok
fi

TOTAL=$((PASS + FAIL))
echo "  cases: $PASS passed / $FAIL failed / $TOTAL total"
if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: $FAIL key-persistence case(s) failed:"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "PASS: authorized_keys persists across reboots (capture + flash-authoritative reseed)"
