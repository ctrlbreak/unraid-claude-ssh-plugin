---
name: Feature request
about: Propose a new category, configuration knob, or behaviour
labels: enhancement
---

## What problem are you trying to solve?

<!-- Describe the workflow that doesn't fit today. Example: "I want to deploy
configuration files to a custom location at /mnt/disk1/foo, which the existing
categories don't cover." -->

## What's your proposed change?

<!-- A new category? A configuration knob? A relaxed validation rule? Be
specific about argv shape, target directory, allowed extensions, allowlist
gating. -->

## Why does this need to live in the plugin (vs. a separate tool)?

<!-- The category set is small by design — every addition is a security
surface. Help the maintainer decide whether this belongs in `claude-write` or
in your client / a separate transport. -->

## Have you read the threat model?

- [ ] [`docs/threat-model.md`](../docs/threat-model.md) — particularly the
  "What this does NOT protect against" section.

If your proposal expands what an SSH key holder can write into, please call
out the new code-execution scope explicitly.
