#!/usr/bin/env python3
"""Run one W-1 QEMU boot and capture serial evidence."""

import argparse
import os
import re
import select
import signal
import subprocess
import sys
import time

REPO = "/home/admin/Projects/keel"
DISK = f"{REPO}/out/spike/disk.raw"
KERNEL = f"{REPO}/out/images/bzImage"
INITRD = f"{REPO}/out/spike/initrd.cpio"

PROBES = [
    ("findmnt -R /", "__KEEL_FINDMNT__"),
    ("lvs", "__KEEL_LVS__"),
    ("cat /etc/machine-id", "__KEEL_MACHINE_ID__"),
    ("systemctl --failed", "__KEEL_FAILED__"),
    ("systemctl is-system-running", "__KEEL_STATE__"),
    ("uname -r", "__KEEL_UNAME__"),
    ("cat /proc/1/comm", "__KEEL_PID1__"),
    ("findmnt /boot", "__KEEL_BOOT__"),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fail", default="", help="keel.fail step")
    parser.add_argument("--log", required=True)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--expect-shell", action="store_true")
    args = parser.parse_args()

    append = "console=ttyS0,115200 root=/dev/system/root_a rootfstype=erofs panic=-1"
    if args.fail:
        append += f" keel.fail={args.fail}"

    cmd = [
        "qemu-system-x86_64",
        "-accel", "kvm",
        "-m", "2048",
        "-display", "none",
        "-serial", "stdio",
        "-monitor", "none",
        "-no-reboot",
        "-kernel", KERNEL,
        "-initrd", INITRD,
        "-append", append,
        "-drive", f"file={DISK},if=virtio,format=raw",
    ]

    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
    )
    assert proc.stdin is not None
    assert proc.stdout is not None
    os.set_blocking(proc.stdout.fileno(), False)

    log = open(args.log, "wb")
    buf = bytearray()
    stage = "boot"
    probe_index = 0
    password_sent = False
    sent_at = time.time()
    started = time.time()

    def pump():
        while True:
            readable, _, _ = select.select([proc.stdout], [], [], 0.2)
            if not readable:
                return
            data = os.read(proc.stdout.fileno(), 4096)
            if not data:
                return
            log.write(data)
            log.flush()
            buf.extend(data)
            sys.stdout.write(data.decode("utf-8", "replace"))
            sys.stdout.flush()

    try:
        while time.time() - started < args.timeout:
            pump()
            text = buf.decode("utf-8", "replace")

            if args.expect_shell:
                if stage == "boot" and "dropping to shell" in text:
                    if re.search(r"(?m)^~ #\s*$", text):
                        proc.stdin.write(b"echo __KEEL_SHELL__\n")
                        proc.stdin.flush()
                        stage = "shell"
                        sent_at = time.time()
                if stage == "shell" and time.time() - sent_at > 1.0:
                    if "__KEEL_SHELL__" in text:
                        proc.stdin.write(b"echo __KEEL_CMD__; cat /proc/cmdline; echo __KEEL_CMD_END__\n")
                        proc.stdin.flush()
                        stage = "done"
                        sent_at = time.time()
                if stage == "done" and "__KEEL_CMD_END__" in text:
                    break
            else:
                if stage == "boot" and "keel login:" in text:
                    proc.stdin.write(b"root\n")
                    proc.stdin.flush()
                    stage = "login"
                    sent_at = time.time()
                if stage == "login" and not password_sent and "Password:" in text:
                    proc.stdin.write(b"\n")
                    proc.stdin.flush()
                    password_sent = True
                if stage == "login" and re.search(r"(?m)^#\s*$", text):
                    stage = "probe"
                    sent_at = time.time()
                if stage == "probe" and probe_index < len(PROBES) and time.time() - sent_at > 1.0:
                    probe, marker = PROBES[probe_index]
                    proc.stdin.write(
                        f"echo {marker}_BEGIN; {probe}; echo {marker}_END\n".encode()
                    )
                    proc.stdin.flush()
                    deadline = time.time() + 20
                    while time.time() < deadline:
                        pump()
                        if f"{marker}_END" in buf.decode("utf-8", "replace"):
                            break
                        time.sleep(0.1)
                    probe_index += 1
                    sent_at = time.time()
                if stage == "probe" and probe_index >= len(PROBES):
                    proc.stdin.write(b"poweroff\n")
                    proc.stdin.flush()
                    stage = "poweroff"
                    sent_at = time.time()
                if stage == "poweroff" and proc.poll() is not None:
                    break

            if proc.poll() is not None:
                break
            time.sleep(0.2)
    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        log.close()

    text = buf.decode("utf-8", "replace")
    if args.expect_shell:
        if "keel: injecting failure" not in text and args.fail:
            print("missing injection marker", file=sys.stderr)
            return 1
        if "__KEEL_SHELL__" not in text:
            print("missing initrd shell", file=sys.stderr)
            return 1
        return 0

    missing = [m for _, m in PROBES if f"{m}_END" not in text]
    if missing:
        print("missing markers: " + ", ".join(missing), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
