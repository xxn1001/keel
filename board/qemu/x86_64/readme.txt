keel2 W-0 QEMU x86_64 image
============================

Build:
  tools/bootstrap-buildroot.sh
  # Optional: keep the Buildroot version string free of the outer git suffix.
  export GIT_CEILING_DIRECTORIES="$PWD/vendor"
  make -C vendor/buildroot BR2_EXTERNAL="$PWD" O="$PWD/out" keel_qemu_x86_64_defconfig
  make -C out

Run:
  qemu-system-x86_64 -accel kvm -m 2048 -display none -serial stdio -monitor none \
    -no-reboot -kernel out/images/bzImage -initrd out/images/rootfs.cpio \
    -append "console=ttyS0,115200 panic=-1"

Login: root, empty password. This is a test-only image; do not use it on real hardware.
Outputs: out/images/bzImage, out/images/rootfs.cpio, out/images/rootfs.tar.
