#!/usr/bin/env python3
"""Run one W-2 OVMF/systemd-boot boot and capture serial evidence."""

import argparse
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import time

REPO = "/home/admin/Projects/keel"
SPIKE = f"{REPO}/out/spike/w2"
DISK = f"{SPIKE}/disk.raw"
VARS = f"{SPIKE}/vars.fd"
VARS_TEMPLATE = "/usr/share/edk2/x64/OVMF_VARS.4m.fd"
OVMF_CODE = "/usr/share/edk2/x64/OVMF_CODE.4m.fd"

DEFAULT_PROBES = [
    "bootctl list",
    "ls -l /boot/EFI/Linux",
    "findmnt /boot",
    "cat /proc/cmdline",
    "cat /var/lib/keel/boot-ok 2>/dev/null",
    "systemctl --failed",
    "systemctl is-system-running",
    "systemctl is-enabled keel-boot-ok.service keel-boot-repair.service 2>&1",
    "cat /run/keel/boot-repair.log 2>/dev/null",
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True)
    parser.add_argument("--mode", choices=["normal", "shell", "commands"], default="normal")
    parser.add_argument("--commands", default="", help="file with guest shell commands")
    parser.add_argument("--shell-commands", default="", help="file with initrd shell commands")
    parser.add_argument("--timeout", type=int, default=240)
    parser.add_argument("--reset-vars", action="store_true")
    args = parser.parse_args()

    if not os.path.exists(DISK):
        print(f"missing disk: {DISK}", file=sys.stderr)
        return 1
    if not os.path.exists(OVMF_CODE):
        print(f"missing OVMF code: {OVMF_CODE}", file=sys.stderr)
        return 1
    if args.reset_vars or not os.path.exists(VARS):
        shutil.copyfile(VARS_TEMPLATE, VARS)

    commands = []
    if args.mode == "commands":
        if not args.commands:
            print("--mode commands needs --commands", file=sys.stderr)
            return 1
        with open(args.commands, encoding="utf-8") as f:
            commands = [line.rstrip("\n") for line in f if line.strip() and not line.lstrip().startswith("#")]
    elif args.mode == "normal":
        commands = list(DEFAULT_PROBES)

    shell_commands = []
    if args.shell_commands:
        with open(args.shell_commands, encoding="utf-8") as f:
            shell_commands = [line.rstrip("\n") for line in f if line.strip() and not line.lstrip().startswith("#")]

    cmd = [
        "qemu-system-x86_64",
        "-accel", "kvm",
        "-m", "2048",
        "-display", "none",
        "-serial", "stdio",
        "-monitor", "none",
        "-no-reboot",
        "-machine", "q35",
        "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
        "-drive", f"if=pflash,format=raw,file={VARS}",
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
    command_index = 0
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

    def text():
        return buf.decode("utf-8", "replace")

    def send(line):
        assert proc.stdin is not None
        proc.stdin.write((line + "\n").encode())
        proc.stdin.flush()

    try:
        while time.time() - started < args.timeout:
            pump()
            current = text()

            if args.mode == "shell":
                if stage == "boot" and ("dropping to shell" in current or re.search(r"(?m)^~ #\s*$", current)):
                    send("echo __W2_SHELL__")
                    stage = "shell"
                    sent_at = time.time()
                elif stage == "shell" and command_index < len(shell_commands) and time.time() - sent_at > 0.5:
                    command = shell_commands[command_index]
                    marker = f"__W2_SHELL_DONE_{command_index}__"
                    send(f"echo __W2_SHELL_BEGIN_{command_index}__; {command}; echo {marker}")
                    command_index += 1
                    sent_at = time.time()
                    deadline = time.time() + 30
                    while time.time() < deadline:
                        pump()
                        if marker in text():
                            break
                        time.sleep(0.1)
                    sent_at = time.time()
                elif stage == "shell" and command_index >= len(shell_commands) and "__W2_SHELL__" in current:
                    if shell_commands:
                        send("sync")
                        sent_at = time.time()
                        break
                    break
                if proc.poll() is not None:
                    break
                time.sleep(0.2)
                continue

            if stage == "boot" and "keel login:" in current:
                send("root")
                stage = "login"
                sent_at = time.time()
            elif stage == "login" and "Password:" in current:
                send("")
                sent_at = time.time()
            elif stage == "login" and re.search(r"(?m)^#\s*$", current):
                stage = "commands"
                sent_at = time.time()
            elif stage == "commands" and command_index < len(commands) and time.time() - sent_at > 0.5:
                command = commands[command_index]
                marker = f"__W2_DONE_{command_index}__"
                send(f"echo __W2_BEGIN_{command_index}__; {command}; echo {marker}")
                command_index += 1
                sent_at = time.time()
                deadline = time.time() + 30
                while time.time() < deadline:
                    pump()
                    if marker in text():
                        break
                    time.sleep(0.1)
                sent_at = time.time()
            elif stage == "commands" and command_index >= len(commands):
                send("sync; poweroff")
                stage = "poweroff"
                sent_at = time.time()

            if proc.poll() is not None:
                break
            time.sleep(0.2)

            if stage == "poweroff" and time.time() - sent_at > 15:
                break
    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        log.close()

    if args.mode == "shell":
        if "dropping to shell" not in text() and "__W2_SHELL__" not in text():
            print("missing initrd shell", file=sys.stderr)
            return 1
        missing = [f"__W2_SHELL_DONE_{i}__" for i in range(len(shell_commands)) if f"__W2_SHELL_DONE_{i}__" not in text()]
        if missing:
            print("missing shell command markers: " + ", ".join(missing), file=sys.stderr)
            return 1
        return 0

    missing = [f"__W2_DONE_{i}__" for i in range(len(commands)) if f"__W2_DONE_{i}__" not in text()]
    if missing:
        print("missing command markers: " + ", ".join(missing), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
