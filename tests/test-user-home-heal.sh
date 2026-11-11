#!/bin/bash
# SSH user account repair at boot (unraid-readonly-ssh-setup.sh sections 1-2).
#
# Unraid saves user accounts to flash and restores them at boot in its own
# normalised shape: home "/", shell /bin/false, and a primary GID whose group
# entry is not persisted. /home itself is RAM-backed, so the home directory is
# gone too. The setup used to create the home only via `useradd -m` for a new
# user, so this state skipped creation, the filter write into the missing home
# failed, and `set -e` aborted the install before keys, sshd and the writer.
#
# Coverage:
#   1. Unraid-restored account (home "/", /bin/false, orphaned GID, no home dir):
#      setup completes, home repaired + created 755, shell bash, primary group
#      users, filter written, UID unchanged, no useradd.
#   2. Re-run on the repaired state is a no-op for usermod (idempotent).
#   3. Healthy account with a 777 home (root umask) is tightened to 755.
#   4. Fresh install (user absent) still goes through useradd and ends at 755.
#   5. Non-default username: every call names that user, never "claude".
#   6. Structure: no `usermod -m` (moving the old home "/" would be disastrous).
#
# Purely behavioural: the section from "# --- 1. Create the user" through the
# filter install is extracted from the source and run in a sandbox, with stub
# id/getent/useradd/usermod/passwd/chown backed by fixture passwd/group files.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts/unraid-readonly-ssh-setup.sh"

if [ ! -f "$SETUP" ]; then
    echo "FAIL: $SETUP not found"
    exit 1
fi

SECTION=$(awk '
    /^# --- 1\. Create the user/ { capturing=1 }
    capturing { print }
    capturing && /^echo "Installed shell filter/ { exit }
' "$SETUP")
if [ -z "$SECTION" ]; then
    echo "FAIL: could not extract the user + filter section from $SETUP"
    exit 1
fi

WORK=$(mktemp -d -t cs-home-heal-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

RUNNER="$WORK/runner.sh"
{
    echo '#!/bin/bash'
    echo 'set -euo pipefail'
    echo "$SECTION"
} > "$RUNNER"

STUBS="$WORK/stubs"
mkdir -p "$STUBS"

cat > "$STUBS/getent" << 'EOF'
#!/bin/bash
case "$1" in
    passwd|group) awk -F: -v k="$2" '$1 == k || $3 == k' "$STATE/$1" | head -n1 | grep . || exit 2 ;;
    *) exit 1 ;;
esac
EOF

cat > "$STUBS/id" << 'EOF'
#!/bin/bash
if [ "$1" = "-nG" ]; then u="$2"; else u="$1"; fi
line=$(awk -F: -v k="$u" '$1 == k' "$STATE/passwd")
if [ -z "$line" ]; then echo "id: '$u': no such user" >&2; exit 1; fi
[ "$1" = "-nG" ] || { echo "uid=$(echo "$line" | cut -d: -f3)($u)"; exit 0; }
gid=$(echo "$line" | cut -d: -f4)
pg=$(awk -F: -v g="$gid" '$3 == g { print $1 }' "$STATE/group")
sup=$(awk -F: -v u="$u" '{ n = split($4, m, ","); for (i = 1; i <= n; i++) if (m[i] == u) print $1 }' "$STATE/group" | tr '\n' ' ')
if [ -z "$pg" ]; then
    echo "id: cannot find name for group ID $gid" >&2
    echo "$gid $sup"
    exit 1
fi
echo "$pg $sup"
EOF

cat > "$STUBS/useradd" << 'EOF'
#!/bin/bash
echo "useradd $*" >> "$STATE/calls.log"
d="" s=""
while [ $# -gt 1 ]; do
    case "$1" in
        -m) shift ;;
        -d) d="$2"; shift 2 ;;
        -s) s="$2"; shift 2 ;;
        *) echo "useradd stub: unexpected $1" >&2; exit 9 ;;
    esac
done
echo "$1:x:1001:1001::$d:$s" >> "$STATE/passwd"
echo "$1:x:1001:" >> "$STATE/group"
mkdir -p -m 700 "$d"
EOF

cat > "$STUBS/usermod" << 'EOF'
#!/bin/bash
echo "usermod $*" >> "$STATE/calls.log"
d="" s="" g="" ag=""
while [ $# -gt 1 ]; do
    case "$1" in
        -d) d="$2"; shift 2 ;;
        -s) s="$2"; shift 2 ;;
        -g) g="$2"; shift 2 ;;
        -aG) ag="$2"; shift 2 ;;
        *) echo "usermod stub: unexpected option $1" >&2; exit 9 ;;
    esac
done
u="$1"
gid=""
if [ -n "$g" ]; then
    gid=$(awk -F: -v k="$g" '$1 == k || $3 == k { print $3 }' "$STATE/group")
    [ -n "$gid" ] || { echo "usermod: group '$g' does not exist" >&2; exit 6; }
fi
awk -F: -v OFS=: -v u="$u" -v d="$d" -v s="$s" -v g="$gid" '
    $1 == u { if (d != "") $6 = d; if (s != "") $7 = s; if (g != "") $4 = g }
    { print }
' "$STATE/passwd" > "$STATE/passwd.new" && mv "$STATE/passwd.new" "$STATE/passwd"
if [ -n "$ag" ]; then
    awk -F: -v OFS=: -v u="$u" -v grp="$ag" '
        $1 == grp { $4 = ($4 == "" ? u : $4 "," u) }
        { print }
    ' "$STATE/group" > "$STATE/group.new" && mv "$STATE/group.new" "$STATE/group"
fi
EOF

cat > "$STUBS/passwd" << 'EOF'
#!/bin/bash
echo "passwd $*" >> "$STATE/calls.log"
EOF

cat > "$STUBS/chown" << 'EOF'
#!/bin/bash
echo "chown $*" >> "$STATE/calls.log"
EOF

chmod 755 "$STUBS"/*

PASS=0
FAIL=0
FAILED=()
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

mode_of() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

# Field N of the user's passwd line in the current sandbox.
pw_field() { awk -F: -v u="$1" -v n="$2" '$1 == u { print $n }' "$SB/state/passwd"; }

# Sandbox globals set by new_sandbox / run_setup.
SB=""; HOME_DIR=""; OUT=""; RC=0; CALLS=""

# new_sandbox <username> <passwd-line|__none__> <home: absent|mode>
# The passwd line may use @HOME@ for the sandbox home path.
new_sandbox() {
    local user="$1" pwline="$2" home="$3"
    SB=$(mktemp -d "$WORK/sb-XXXXXX")
    mkdir -p "$SB/state" "$SB/home"
    HOME_DIR="$SB/home/$user"
    printf 'root:x:0:\nusers:x:100:\n' > "$SB/state/group"
    : > "$SB/state/passwd"
    if [ "$pwline" != "__none__" ]; then
        printf '%s\n' "${pwline//@HOME@/$HOME_DIR}" >> "$SB/state/passwd"
    fi
    if [ "$home" != "absent" ]; then
        mkdir -p "$HOME_DIR"
        chmod "$home" "$HOME_DIR"
    fi
}

# run_setup <username>: runs the extracted section against the current sandbox.
run_setup() {
    local user="$1" home="$HOME_DIR"
    : > "$SB/state/calls.log"
    OUT=$(STATE="$SB/state" PATH="$STUBS:$PATH" USERNAME="$user" \
          HOME_DIR="$home" FILTER_SCRIPT="$home/shell-filter.sh" \
          bash "$RUNNER" 2>&1)
    RC=$?
    CALLS=$(cat "$SB/state/calls.log")
}

# === 1. Unraid-restored account: home "/", /bin/false, orphaned GID 1003 ===
new_sandbox claude 'claude:x:1003:1003::/:/bin/false' absent
run_setup claude
assert_eq "restored: exit status" "0" "$RC"
if [ -f "$HOME_DIR/shell-filter.sh" ]; then ok; else fail "restored: filter not written ($OUT)"; fi
if [ -d "$HOME_DIR" ]; then
    assert_eq "restored: home mode" "755" "$(mode_of "$HOME_DIR")"
else
    fail "restored: home directory not created"
fi
assert_eq "restored: passwd home" "$HOME_DIR" "$(pw_field claude 6)"
assert_eq "restored: passwd shell" "/bin/bash" "$(pw_field claude 7)"
assert_eq "restored: primary gid -> users" "100" "$(pw_field claude 4)"
assert_eq "restored: uid unchanged" "1003" "$(pw_field claude 3)"
assert_not_contains "restored: no useradd" "useradd" "$CALLS"
assert_contains "restored: home chowned to user" "chown claude:users $HOME_DIR" "$CALLS"

# === 2. Re-run on the repaired state: no further account changes ===
run_setup claude
assert_eq "rerun: exit status" "0" "$RC"
assert_not_contains "rerun: no usermod" "usermod" "$CALLS"
assert_eq "rerun: home mode" "755" "$(mode_of "$HOME_DIR")"

# === 3. Healthy account, home left 777 by root's umask -> 755 ===
new_sandbox claude 'claude:x:1003:100::@HOME@:/bin/bash' 777
run_setup claude
assert_eq "umask777: exit status" "0" "$RC"
assert_eq "umask777: home mode" "755" "$(mode_of "$HOME_DIR")"
assert_not_contains "umask777: no usermod -d/-s/-g" "usermod -" "$(echo "$CALLS" | grep -v -- '-aG')"

# === 4. Fresh install: user absent -> useradd path, ends 755 ===
new_sandbox claude __none__ absent
run_setup claude
assert_eq "fresh: exit status" "0" "$RC"
assert_contains "fresh: useradd called" "useradd -m -d $HOME_DIR -s /bin/bash claude" "$CALLS"
if [ -f "$HOME_DIR/shell-filter.sh" ]; then ok; else fail "fresh: filter not written ($OUT)"; fi
assert_eq "fresh: home mode" "755" "$(mode_of "$HOME_DIR")"
assert_not_contains "fresh: no primary-group change" "usermod -g" "$CALLS"

# === 5. Non-default username in the Unraid-restored shape ===
new_sandbox bob 'bob:x:1004:1004::/:/bin/false' absent
run_setup bob
assert_eq "bob: exit status" "0" "$RC"
assert_eq "bob: passwd home" "$HOME_DIR" "$(pw_field bob 6)"
assert_eq "bob: passwd shell" "/bin/bash" "$(pw_field bob 7)"
assert_eq "bob: primary gid -> users" "100" "$(pw_field bob 4)"
assert_contains "bob: home chowned to bob" "chown bob:users $HOME_DIR" "$CALLS"
assert_not_contains "bob: no literal claude in calls" "claude" "$CALLS"
if [ -d "$HOME_DIR" ]; then
    assert_eq "bob: home mode" "755" "$(mode_of "$HOME_DIR")"
else
    fail "bob: home directory not created"
fi

# === 6. Structure: usermod never moves the home ===
if grep -E '^[^#]*usermod[^#]*[[:space:]]-m([[:space:]]|$)' "$SETUP" >/dev/null; then
    fail "structure: usermod -m present (would move the old home, which may be /)"
else
    ok
fi

TOTAL=$((PASS + FAIL))
echo "  cases: $PASS passed / $FAIL failed / $TOTAL total"
if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: $FAIL user/home repair case(s) failed:"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "PASS: setup repairs an Unraid-restored SSH account (home, shell, group, 755)"
