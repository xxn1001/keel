#!/usr/bin/env python3
"""Copy executables and their ELF dependency closure into an image tree.

Usage: collect-deps.py ROOT BIN_DIR LIB_DIR BINARY...
"""

import os
import shutil
import subprocess
import sys


def fail(message):
    print(f"collect-deps: {message}", file=sys.stderr)
    sys.exit(1)


def needed(path, readelf):
    result = subprocess.run(
        [readelf, "-d", path],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        fail(f"readelf failed for {path}: {result.stderr.strip()}")
    names = []
    for line in result.stdout.splitlines():
        if "(NEEDED)" in line:
            names.append(line.split("[", 1)[1].split("]", 1)[0])
    return names


def build_index(root):
    index = {}
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            index.setdefault(name, os.path.join(dirpath, name))
    return index


def copy_file(source, destination):
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    shutil.copy2(source, destination)


def main():
    if len(sys.argv) < 5:
        fail("usage: collect-deps.py ROOT BIN_DIR LIB_DIR BINARY...")
    root, bin_dir, lib_dir = sys.argv[1:4]
    binaries = sys.argv[4:]
    readelf = shutil.which("readelf")
    if readelf is None:
        fail("readelf not found in PATH")
    if not os.path.isdir(root):
        fail(f"root directory not found: {root}")

    index = build_index(root)
    os.makedirs(bin_dir, exist_ok=True)
    os.makedirs(lib_dir, exist_ok=True)

    queue = []
    for binary in binaries:
        if not os.path.isfile(binary):
            fail(f"binary not found: {binary}")
        copy_file(binary, os.path.join(bin_dir, os.path.basename(binary)))
        queue.append(binary)

    seen = set()
    while queue:
        source = queue.pop()
        if source in seen:
            continue
        seen.add(source)
        for name in needed(source, readelf):
            library = index.get(name)
            if library is None:
                fail(f"missing library {name} needed by {source}")
            copy_file(library, os.path.join(lib_dir, name))
            queue.append(library)

    loader = index.get("ld-linux-x86-64.so.2")
    if loader is None:
        fail("missing dynamic loader ld-linux-x86-64.so.2")
    copy_file(loader, os.path.join(lib_dir, "ld-linux-x86-64.so.2"))


if __name__ == "__main__":
    main()
