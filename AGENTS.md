# AGENTS.md

This file is the entry point for any agent working on keel2. Read it before touching anything.

## 1. Read order

1. [`docs/README.md`](docs/README.md) - document map.
2. [`docs/outline.md`](docs/outline.md) - what the system is.
3. [`docs/conventions.md`](docs/conventions.md) - language, naming, document rules.
4. [`docs/workflow.md`](docs/workflow.md) - branches, commits, design PR, review, merge.
5. [`docs/testing.md`](docs/testing.md) - unit, build, integration, evidence.
6. [`docs/ci.md`](docs/ci.md) - GitHub Actions, no-KVM limits, `ci:build`.
7. The **one** feature document you are working on, plus the ADRs it links to.
8. [`docs/lessons.md`](docs/lessons.md) - general failure patterns; read the entries that apply.
9. [`docs/verification.md`](docs/verification.md) - what is actually verified, and in which environment.

Do not assume the reader has seen a previous project. Every document must be self-contained.

## 2. Language and encoding (non-negotiable)

- Documents: Chinese is allowed.
- Source code, comments, logs, error messages, `printf` strings, unit `Description=`, commit messages, branch names, file names, directory names, paths, usernames, hostnames, kernel cmdline, and config keys: **English ASCII only**.
- No Chinese, full-width punctuation, smart quotes, or em dashes inside source files or code blocks.
- Run `tools/check-ascii.sh` before committing.
- See [`docs/conventions.md`](docs/conventions.md) for details.

## 3. Document ownership

| File | Who may edit |
|---|---|
| `docs/outline.md`, `docs/roadmap.md` | maintainer only |
| `docs/decisions/ADR-*.md` | append-only; new decision = new ADR |
| `docs/open/Q-*.md` | anyone; close only when the decision is recorded |
| `docs/features/F-*.md` | the feature owner or one agent |
| `docs/layout.md`, `docs/initrd.md` | maintainer only |
| `docs/lessons.md`, `docs/conventions.md`, `docs/workflow.md`, `docs/testing.md`, `docs/ci.md` | maintainer only |
| `docs/verification.md` | the person/agent who ran the test |

Rules:

- One agent = one feature file. Do not edit outline, roadmap, or accepted ADRs in the same change.
- Accepted ADRs are immutable. If a decision changes, write a new ADR and mark the old one `Superseded by ADR-xxxx`.
- Use links, not copies. One fact lives in exactly one file.
- Keep a document under roughly 300 lines; split by feature or topic if it grows.

## 4. Git and PR rules

- Work from `main` on a short-lived branch. Never push directly to `main`.
- Branch format: `<type>/<slug>`, for example `feat/ab-update-rollback`, `fix/esp-space-check`, `docs/design-ab-update-rollback`.
- Branch and commit messages **do not carry `F-xxx`**. Feature IDs are documentation only. Use an area scope such as `feat(update): ...`.
- Design PR is mandatory for `feat/*`, `refactor/*`, and architectural `ci/*`/`chore/*`. Merge the design PR before code. Link it as `Design-PR: #123` in the implementation PR.
- `fix/*` does not need a separate design PR unless it changes architecture, interfaces, or an ADR.
- One PR = one concern. Do not mix feature, refactor, formatting, or dependency bumps.
- Every code PR includes unit tests; every bug fix includes a regression test. `cmocka` is the C framework.
- The maintainer reviews every PR. Agents cannot self-approve or merge.
- Squash merge only; linear history; delete the branch after merge.

## 5. Quality rules

- **No shell state machines.** Shell is allowed only as thin glue. Critical logic (partition writes, update order, boot entry selection, status) is compiled (C, C++, or Rust).
- **No machine identity in the repository or image**: no `machine-id`, no SSH host keys, no real passwords, no private keys, no `authorized_keys` for a specific person.
- **No "verified" without evidence.** A command returning 0 is not evidence. Record `findmnt`, `lvs`, `bootctl list`, `efibootmgr`, `journalctl -b`, or equivalent output in `docs/verification.md`.
- **Walking skeleton first.** Do not add a feature until the previous gate in `docs/roadmap.md` is met.
- **One change, one boot.** Every storage/boot change must be followed by a boot test in the declared environment before the next change.
- **Keep a known-good slot.** Never overwrite both A and B in one operation.
- **Ask before changing an architectural decision.** If you think an ADR is wrong, write a proposal in `docs/open/`; do not silently change the design.
- **CI is a check, not an approval.** The maintainer decides. `ci:build` is a manual label for the expensive Buildroot build; PRs default to lint + unit.
- **No KVM on GitHub-hosted runners.** TCG smoke is E1 only; destructive tests stay manual until a self-hosted runner exists.

## 6. What this project is not

- Not a desktop/laptop OS in v1.
- Not a fleet/management system.
- Not signed, not verity-protected, not Secure Boot in v1.
- Not a package-manager-based distro. The host is rebuilt, not upgraded package by package.
