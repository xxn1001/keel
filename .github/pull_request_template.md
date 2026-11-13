## Summary

One or two sentences. What does this PR change?

## Design PR

<!-- Required for feat/*, refactor/*, and architectural ci/* or chore/*. -->
<!-- Write "N/A" for fix/*, docs/*, test/*. -->

Design-PR: #

## What changed

- ...

## Why

What problem does this solve? Link the feature doc or ADR if relevant.

## Tests

- [ ] `make lint`
- [ ] `make test-unit`
- [ ] Buildroot build (`ci:build` label or local)
- [ ] QEMU smoke (serial login, mounts, `systemctl --failed`)
- [ ] Failure drill / destructive test (if applicable)

## Evidence

Commands and key output. Do not write only "works".

```text
...
```

## Docs

- [ ] Feature doc updated
- [ ] ADR/Q updated or added
- [ ] No duplicated facts

## Risk / rollback

What can break? How do we revert? Any data/partition risk?

## Checklist

- [ ] Branch name follows `<type>/<slug>`, no `F-xxx`.
- [ ] Commits follow Conventional Commits, no `F-xxx` scope.
- [ ] One concern only; no unrelated refactor/formatting.
- [ ] Source ASCII; `tools/check-ascii.sh` passes.
- [ ] No secrets, machine-id, SSH host keys, or generated artifacts.
- [ ] `main` is not modified directly.
- [ ] The maintainer has reviewed and approved; the author does not merge.
