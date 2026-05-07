# Install

## Prerequisites

- Unraid 7.0 or later. Currently exercised against 7.2; earlier 7.x
  releases should work but haven't been verified. Not supported on Unraid
  6.x.
- Root SSH access to the box (you'll need it to bootstrap the SSH key for the
  filtered user, and as an escape hatch if anything misconfigures).
- A workstation with an SSH client and the ability to generate ED25519 keys.

## Install via the Unraid web UI

1. **Generate an SSH key on your workstation** (skip if you already have one
   you want to use for this purpose):

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/claude_unraid -C "claude-ssh@$(hostname)"
   ```

2. **Install the plugin** from the Unraid web UI → **Plugins** → **Install
   Plugin**, paste the URL of the `.plg`. Always use a release URL — the
   `main`-branch `.plg` is a template with an unrendered `__MD5__` placeholder
   and won't install:

   ```
   https://github.com/ctrlbreak/unraid-claude-ssh-plugin/releases/latest/download/claude-ssh.plg
   ```

   For production, pin to a specific release tag:

   ```
   https://github.com/ctrlbreak/unraid-claude-ssh-plugin/releases/download/v2026.05.06c/claude-ssh.plg
   ```

   The plugin downloads the matching `.txz` package, extracts it to
   `/usr/local/emhttp/plugins/claude-ssh/`, and runs `install-runtime.sh`.

3. **Add your SSH public key** to the filtered user's authorized_keys. From a
   root SSH session on the NAS:

   ```bash
   mkdir -p /home/claude/.ssh
   chown claude:users /home/claude/.ssh
   chmod 700 /home/claude/.ssh
   cat >> /home/claude/.ssh/authorized_keys << 'KEY'
   ssh-ed25519 AAAA... claude-ssh@workstation
   KEY
   chown claude:users /home/claude/.ssh/authorized_keys
   chmod 600 /home/claude/.ssh/authorized_keys
   ```

   (Substitute `claude` with your configured username if you set
   `CLAUDE_SSH_USERNAME` — see [the username section in the README](../README.md#configurable-ssh-username).)

4. **Smoke-test from your workstation**:

   ```bash
   ssh -i ~/.ssh/claude_unraid claude@<nas-ip> 'claude-shell ping'
   # → expects "pong" or similar; rejected commands print a structured BLOCKED line.

   echo "hello world" | ssh -i ~/.ssh/claude_unraid claude@<nas-ip> \
     'claude-write scratch hello.txt'
   # → expects "claude-write: OK" with size + sha256 confirmation.
   ```

5. **Configure the allowlist**. Defaults to default-deny — no plugin or
   container writes succeed until you add entries. Either edit the file
   directly (`/boot/config/plugins/claude-ssh/allowlist.cfg`) or use the
   Settings → Claude SSH → Allowlist editor in the web UI.

## Install via shell (without the web UI)

If you need to install on an Unraid box without the WebUI accessible:

```bash
# 1. Place the .plg + .txz on flash (the install URL points here).
mkdir -p /boot/config/plugins/claude-ssh
curl -fsSL <plg-url> -o /boot/config/plugins/claude-ssh/claude-ssh.plg
curl -fsSL <txz-url> -o /boot/config/plugins/claude-ssh/claude-ssh.txz

# 2. Run the install hook from the .plg manually.
plugin install /boot/config/plugins/claude-ssh/claude-ssh.plg
```

## What gets installed

Files laid down on the flash drive:

```
/boot/config/plugins/claude-ssh/
├── claude-ssh.plg                  # Plugin manifest (preserved across upgrades)
├── claude-ssh.txz                  # Cached package (preserved)
├── allowlist.cfg                   # Runtime allowlist (seeded once, never overwritten)
└── username                        # Configured SSH username (seeded once, never overwritten)
```

Files laid down in RAM (re-rendered on every boot by the `/boot/config/go` hook):

```
/usr/local/emhttp/plugins/claude-ssh/    # plugin tree (page, dashboard, exec.php, scripts)
/usr/local/bin/claude-write              # thin wrapper, callable by the SSH user
/usr/local/sbin/claude-write-priv        # privileged writer (re-validates argv)
/etc/sudoers.d/claude-write              # NOPASSWD grant for the principal
/home/<user>/                            # SSH user home, with shell-filter.sh
```

Boot persistence:

```
/boot/config/go      # single line: bash /usr/local/emhttp/plugins/claude-ssh/scripts/install-runtime.sh
```

## Verify the install

After install, the **Settings → Claude SSH** tab should show:

- **Health KPI:** "User &lt;configured&gt; ready" with a green dot.
- **Filter version:** `v9` (parsed from the live `/home/<user>/shell-filter.sh`).
- **Writer version:** `v4` (parsed from the live `/usr/local/sbin/claude-write-priv`).
- **Audit Log:** empty until the first write happens.

If any of these are missing, see [troubleshooting.md](troubleshooting.md).
