---
name: Bug report
about: Something is broken or behaving unexpectedly
labels: bug
---

## What happened?

<!-- A short description of the bug. Include exact error messages where you saw them. -->

## What did you expect to happen?

<!-- Briefly. -->

## How to reproduce

<!-- Minimal command sequence. Include the exact `claude-write` / `claude-shell`
invocation if relevant. Redact any sensitive content from stdin. -->

```bash

```

## Versions

Please paste the versions from **Settings → Claude SSH → Status**:

- Plugin version: `2026.0X.XX`
- Filter version: `vN`
- Writer version: `vN`
- Unraid version:

## Environment

- Plugin installed via: [ ] web UI / [ ] manual `.plg` URL / [ ] from-source `make && deploy.sh --full`
- SSH username (if you customised it): `claude` / other
- Allowlist size: ~N plugin lines, ~N container lines

## Logs

If the failure is at install or runtime:

```bash
grep -E "claude-(ssh-plugin|write|shell)" /var/log/syslog | tail -50
```

<!-- Paste the relevant lines below, redacted as needed. -->

```

```

## Did you check the troubleshooting guide?

- [ ] [`docs/troubleshooting.md`](../docs/troubleshooting.md)
