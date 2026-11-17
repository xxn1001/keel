keel W-1 storage spike
======================

One-time experiment. Do not merge this branch.

Build the rootfs (already includes lvm2, util-linux binaries, btrfs-progs,
and a BusyBox timeout fragment):

  make -C vendor/buildroot BR2_EXTERNAL="$PWD" O="$PWD/out" keel_qemu_x86_64_defconfig
  make -C out

Build the minimal initramfs:

  ./spike/w1/build-initrd.sh

Provision the raw sparse disk (requires sudo; host loop + LVM):

  sudo ~/Projects/proviledge/w1-storage-provision.sh

Run one normal boot:

  ./spike/w1/run-qemu.py --log out/spike/boot-1.log

Run one failure injection:

  ./spike/w1/run-qemu.py --fail root --expect-shell \
    --log out/spike/fail-root.log

Artifacts live in out/spike/. The provision script stops the VG and detaches
the loop device before QEMU is started.
