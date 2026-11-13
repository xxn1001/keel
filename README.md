# keel2

A minimal, self-built Linux system for a **headless server**:

- **erofs read-only root**, A/B on two LVM LVs in the `system` VG.
- **system VG** for root A/B and `/etc` (thick LVs).
- **data partition** for `/var` and `/home` (btrfs subvolumes).
- **physical recovery partition** for LVM/root/etc/data failures.
- **systemd** as the only init; initrd eventually uses systemd too.
- **Buildroot LTS** as the build system; no mkosi, no nix, no distro package manager on the host.
- **Compiled updater** (`keel-update`), no shell state machine.
- **podman** for userland software (later); VFIO is a future feature.

This repository is currently **design-only**. There is no bootable artifact yet.

## Start here

Read [`docs/README.md`](docs/README.md) for the document map and reading order.

## Document language

- Documents are written in Chinese.
- **Source code, comments, logs, error messages, unit descriptions, commit messages, file names, paths, usernames, hostnames, kernel cmdline, and config keys are English ASCII.**
- See [`docs/conventions.md`](docs/conventions.md) for the exact rules and the `tools/check-ascii.sh` check.

## Status

| Area | Status |
|---|---|
| Documentation framework | skeleton + design docs |
| Collaboration rules | workflow / testing / ci defined |
| Buildroot base | not started |
| Bootable image in QEMU | not started |
| A/B update / rollback | design |
| Installer / rescue | design |
| podman / VFIO | future |
