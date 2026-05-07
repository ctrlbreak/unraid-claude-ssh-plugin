#!/bin/bash
# Developer utility: build the .txz and install the plugin on a NAS over SSH.
#
# This is a convenience for plugin authors / contributors iterating against a
# real Unraid box. End users should NOT use this — install via the web UI from
# the release `.plg` URL instead (see docs/install.md).
#
# Usage:
#   NAS_HOST=root@nas.local bash deploy.sh
#
# Behaviour:
#   - Builds claude-ssh.txz via `make`.
#   - Copies .txz + .plg to /boot/config/plugins/claude-ssh/ on the NAS via scp.
#   - Runs `plugin install <plg> forced` on the NAS.
#
# Requires: passwordless root SSH to the NAS. The `forced` flag re-installs
# even if the plugin manager thinks the version is unchanged — useful when
# the .plg version didn't bump but you want to redeploy a built .txz.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
NAS="${NAS_HOST:-}"

if [ -z "$NAS" ]; then
    cat <<EOF >&2
ERROR: NAS_HOST not set. Pass it via env, e.g.:

  NAS_HOST=root@nas.local bash deploy.sh

End users should install via the release URL from the Unraid web UI:

  https://github.com/ctrlbreak/unraid-claude-ssh-plugin/releases/latest/download/claude-ssh.plg

(See docs/install.md for the user-facing install path.)
EOF
    exit 1
fi

echo "==> Building .txz package..."
make -C "$REPO_ROOT"

# Render the .plg by substituting __MD5__ with the computed md5 — same as CI.
# Without this the in-repo .plg fails plugin-install MD5 verification.
md5=$(md5sum "$REPO_ROOT/claude-ssh.txz" 2>/dev/null | awk '{print $1}')
[ -z "$md5" ] && md5=$(md5 -q "$REPO_ROOT/claude-ssh.txz" 2>/dev/null)
if [ -z "$md5" ]; then
    echo "ERROR: neither md5sum nor md5 available" >&2
    exit 1
fi
PLG_RENDERED=$(mktemp)
trap 'rm -f "$PLG_RENDERED"' EXIT
sed "s/__MD5__/$md5/g" "$REPO_ROOT/claude-ssh.plg" > "$PLG_RENDERED"
if grep -q '__MD5__' "$PLG_RENDERED"; then
    echo "ERROR: __MD5__ placeholder still present after substitution" >&2
    exit 1
fi

echo "==> Uploading .txz and .plg to $NAS..."
PLG="/boot/config/plugins/claude-ssh/claude-ssh.plg"
SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-deploy-%r@%h -o ControlPersist=30s"

# shellcheck disable=SC2086
ssh $SSH_OPTS "$NAS" "mkdir -p /boot/config/plugins/claude-ssh"
# shellcheck disable=SC2086
scp $SSH_OPTS "$REPO_ROOT/claude-ssh.txz" "$NAS:/boot/config/plugins/claude-ssh/"
# shellcheck disable=SC2086
scp $SSH_OPTS "$PLG_RENDERED" "$NAS:$PLG"

echo "==> Running plugin install..."
# shellcheck disable=SC2086
ssh $SSH_OPTS "$NAS" "plugin install $PLG forced"

echo "==> Done"
