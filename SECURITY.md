# Security policy

## Reporting a vulnerability

If you've found a security issue in this plugin, **please don't file a public
issue**. The contents of `claude-write` and the SSH filter are the entire
point of the project — a public issue is essentially a 0-day disclosure to
every user who's installed the plugin.

Instead, report privately via **GitHub Security Advisories**:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Fill out the form. Include a proof-of-concept where possible.

The maintainer will acknowledge within a few days, work with you on a fix,
and coordinate disclosure. Public credit on resolution unless you opt out.

## What counts as a security issue

- Allowlist bypass (e.g. writing to a plugin or container that isn't in
  `allowlist.cfg`).
- Path traversal that escapes the configured target directory for a
  category.
- Privilege escalation beyond what `/etc/sudoers.d/claude-write` grants.
- The SSH filter accepting a command that should have been BLOCKED.
- The writer accepting input that should have been REJECTED.
- Any way an SSH-key holder can do more than what
  [`docs/threat-model.md`](docs/threat-model.md) describes.

## What doesn't count as a security issue

- Bugs in code-execution categories (`plugin-script`, `appdata-script`) being
  used as designed. The threat model explicitly notes that allowlisting a
  plugin or container grants code-execution scope inside that namespace —
  that's not a vulnerability, it's the contract.
- Root-on-the-NAS scenarios. If an attacker has root, this plugin doesn't
  matter.
- Issues in dependencies (Unraid base, sshd, sudo, bash). Report those
  upstream.

## Supported versions

Only the latest plugin version receives security fixes. Older versions are
unsupported the moment a new release ships. Pin your install to the latest
release tag and check for updates regularly.
