#define _GNU_SOURCE
#include "installer.h"

#include <keel/fs.h>
#include <keel/proc.h>

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define GIB (1024ULL * 1024ULL * 1024ULL)
#define MIB (1024ULL * 1024ULL)
#define DISK_MIN (8ULL * GIB)
#define DISK_WARN (32ULL * GIB)

enum {
    M_ROOT,
    M_ETC,
    M_DATA,
    M_VAR,
    M_HOME,
    M_ESP,
    M_COUNT
};

static const char *const mount_targets[M_COUNT] = {
    "/mnt/root", "/mnt/etc", "/mnt/data", "/mnt/var", "/mnt/home",
    "/mnt/esp",
};

static const char *const source_files[] = {
    "rootfs.erofs",
    "recovery.erofs",
    "keel-a.efi",
    "keel-b.efi",
};

static const char *const part_labels[] = {
    "/dev/disk/by-partlabel/esp",
    "/dev/disk/by-partlabel/recovery",
    "/dev/disk/by-partlabel/system",
    "/dev/disk/by-partlabel/data",
};

static const char sfdisk_script[] =
    "label: gpt\n"
    "unit: sectors\n"
    "start=2048, size=2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=\"esp\"\n"
    "start=2099200, size=2097152, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=\"recovery\"\n"
    "start=4196352, size=12582912, type=E6D6D379-F507-44C2-A23C-238F2A3DF928, name=\"system\"\n"
    "start=16779264, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=\"data\"\n";

static void usage(FILE *out)
{
    fprintf(out,
            "usage: %s --disk <dev> --source <dir> "
            "[--dry-run] [--force] [--timeout <sec>]\n"
            "\n"
            "  --disk    target disk (real runs require a block device)\n"
            "  --source  directory with rootfs.erofs, recovery.erofs, "
            "keel-a.efi, keel-b.efi\n"
            "  --dry-run print the full plan; a regular file is accepted "
            "for planning\n"
            "  --force   overwrite an existing partition table\n"
            "  --timeout seconds to wait for a device (default 60)\n",
            keel_progname());
}

static int exec_argv(struct ctx *ctx, char *const argv[])
{
    if (ctx->dry_run) {
        keel_print_argv("plan", argv);
        return 0;
    }
    keel_print_argv("exec", argv);
    {
        int rc = keel_run_timeout(argv, ctx->timeout);

        if (rc == 124) {
            keel_err("timed out after %us: %s", ctx->timeout, argv[0]);
            return 4;
        }
        if (rc != 0) {
            keel_err("command failed: %s", argv[0]);
            return 4;
        }
    }
    return 0;
}

static int exec_input(struct ctx *ctx, char *const argv[], const char *input)
{
    if (ctx->dry_run) {
        keel_print_argv("plan", argv);
        printf("%s: plan: stdin:\n%s", keel_progname(), input);
        return 0;
    }
    keel_print_argv("exec", argv);
    {
        int rc = keel_run_input_timeout(argv, input, ctx->timeout);

        if (rc == 124) {
            keel_err("timed out after %us: %s", ctx->timeout, argv[0]);
            return 4;
        }
        if (rc != 0) {
            keel_err("command failed: %s", argv[0]);
            return 4;
        }
    }
    return 0;
}

static int mount_fs(struct ctx *ctx, const char *source, const char *target,
                    const char *type, const char *options,
                    struct keel_mount *m)
{
    char *argv[] = { "mount", "-t", (char *)type, "-o", (char *)options,
                     (char *)source, (char *)target, NULL };

    if (ctx->dry_run) {
        keel_print_argv("plan", argv);
        return 0;
    }
    return keel_mount(source, target, type, options, m, ctx->timeout) == 0
               ? 0
               : 4;
}

static int umount_fs(struct ctx *ctx, struct keel_mount *m)
{
    char *argv[] = { "umount", m->target, NULL };

    if (ctx->dry_run) {
        keel_print_argv("plan", argv);
        return 0;
    }
    return keel_umount(m, ctx->timeout) == 0 ? 0 : 4;
}

static int make_dir(struct ctx *ctx, const char *path, mode_t mode)
{
    if (ctx->dry_run) {
        keel_log("plan: mkdir -p %s (mode %04o)", path, mode);
        return 0;
    }
    if (keel_mkdir_p(path, mode) < 0) {
        keel_err("cannot create %s: %s", path, strerror(errno));
        return 4;
    }
    if (mode != 0755 && chmod(path, mode) < 0) {
        keel_err("cannot chmod %s: %s", path, strerror(errno));
        return 4;
    }
    return 0;
}

static int disk_has_vg(const char *disk, unsigned timeout)
{
    char out[4096];
    char *argv[] = { "pvs", "--noheadings", "--options",
                     "pv_name,vg_name", NULL };
    char *line;
    char *save = NULL;

    {
        int rc = keel_capture_timeout(argv, out, sizeof(out), timeout);

        if (rc != 0)
            return rc == 124 ? 124 : -1;
    }
    for (line = strtok_r(out, "\n", &save); line != NULL;
         line = strtok_r(NULL, "\n", &save)) {
        char *pv = line;
        char *vg;
        while (*pv == ' ' || *pv == '\t')
            pv++;
        if (*pv == '\0')
            continue;
        vg = pv;
        while (*vg != '\0' && *vg != ' ' && *vg != '\t')
            vg++;
        if (*vg == '\0')
            continue;
        *vg++ = '\0';
        while (*vg == ' ' || *vg == '\t')
            vg++;
        if (*vg == '\0')
            continue;
        if (keel_path_belongs_to(pv, disk))
            return 1;
    }
    return 0;
}

static int check_source(struct ctx *ctx)
{
    size_t i;

    for (i = 0; i < sizeof(source_files) / sizeof(source_files[0]); i++) {
        char path[PATH_MAX];
        struct stat st;

        snprintf(path, sizeof(path), "%s/%s", ctx->source, source_files[i]);
        if (stat(path, &st) < 0 || !S_ISREG(st.st_mode)) {
            keel_err("missing source file: %s", path);
            return 2;
        }
    }
    return 0;
}

static int check_disk(struct ctx *ctx)
{
    struct stat st;
    unsigned sector;
    int table;

    if (stat(ctx->disk, &st) < 0) {
        keel_err("cannot stat disk %s: %s", ctx->disk, strerror(errno));
        return 3;
    }
    if (!ctx->dry_run && !S_ISBLK(st.st_mode)) {
        keel_err("not a block device: %s", ctx->disk);
        return 3;
    }
    if (ctx->dry_run && !S_ISBLK(st.st_mode) && !S_ISREG(st.st_mode)) {
        keel_err("not a disk or regular file: %s", ctx->disk);
        return 3;
    }
    if (keel_path_device_size(ctx->disk, &ctx->disk_size) < 0) {
        keel_err("cannot read disk size: %s", ctx->disk);
        return 3;
    }
    if (keel_path_sector_size(ctx->disk, &sector) < 0) {
        keel_err("cannot read logical sector size: %s", ctx->disk);
        return 3;
    }
    if (sector != 512) {
        keel_err("unsupported logical sector size %u; need 512", sector);
        return 3;
    }
    if (ctx->disk_size < DISK_MIN) {
        keel_err("disk too small: %s has %llu bytes, need 8 GiB",
                 ctx->disk, ctx->disk_size);
        return 3;
    }
    if (ctx->disk_size < DISK_WARN)
        keel_err("warn: disk is smaller than 32 GiB; data will be small");
    if (ctx->disk_size <= 8ULL * GIB + MIB) {
        keel_err("disk has no room for the data partition");
        return 3;
    }
    table = keel_path_has_partition_table(ctx->disk);
    if (table < 0) {
        keel_err("cannot read %s: %s", ctx->disk, strerror(errno));
        return 3;
    }
    if (table && !ctx->force) {
        keel_err("disk already has a partition table; use --force");
        return 3;
    }
    if (!ctx->dry_run) {
        int vg;

        if (keel_path_is_mounted(ctx->disk)) {
            keel_err("disk is mounted: %s", ctx->disk);
            return 3;
        }
        vg = disk_has_vg(ctx->disk, ctx->timeout);
        if (vg == 124) {
            keel_err("pvs timed out after %us", ctx->timeout);
            return 4;
        }
        if (vg < 0) {
            keel_err("cannot run pvs");
            return 4;
        }
        if (vg > 0) {
            keel_err("disk already has a VG: %s", ctx->disk);
            return 3;
        }
    }
    return 0;
}

static int step_validate(struct ctx *ctx)
{
    int rc = check_source(ctx);

    if (rc != 0)
        return rc;
    rc = check_disk(ctx);
    if (rc != 0)
        return rc;
    keel_log("disk=%s source=%s size=%llu force=%d timeout=%u", ctx->disk,
             ctx->source, ctx->disk_size, ctx->force, ctx->timeout);
    if (ctx->dry_run)
        keel_log("plan: block-device, mount, and VG checks are skipped in "
                 "dry-run");
    return 0;
}

static int step_partition(struct ctx *ctx)
{
    char *wipefs[] = { "wipefs", "-a", (char *)ctx->disk, NULL };
    char *sfdisk[] = { "sfdisk", "--no-tell-kernel", (char *)ctx->disk, NULL };
    char *partx_drop[] = { "partx", "-d", (char *)ctx->disk, NULL };
    char *partx[] = { "partx", "-a", (char *)ctx->disk, NULL };
    int rc;

    rc = exec_argv(ctx, wipefs);
    if (rc != 0)
        return rc;
    if (ctx->dry_run)
        keel_log("plan: gpt types: esp=EF00 recovery=8300 system=8E00 "
                 "data=8300");
    rc = exec_input(ctx, sfdisk, sfdisk_script);
    if (rc != 0)
        return rc;
    /*
     * partx uses BLKPG, which creates partition devices without a PARTNAME
     * attribute in sysfs. Discovery therefore relies on the blkid PARTLABEL
     * fallback until the kernel rescans at the next boot. Keep the kernel
     * re-read out of this step; blockdev --rereadpt has not been verified.
     */
    if (ctx->dry_run) {
        keel_print_argv("plan", partx_drop);
    } else {
        keel_print_argv("exec", partx_drop);
        if (keel_run_timeout(partx_drop, ctx->timeout) < 0)
            return 4;
    }
    return exec_argv(ctx, partx);
}

static int step_discover(struct ctx *ctx)
{
    char *argv[] = { "/sbin/keel-discover", NULL };
    size_t i;
    time_t deadline;
    int last_rc = -1;
    const char *missing = "none";

    if (ctx->dry_run) {
        keel_print_argv("plan", argv);
        for (i = 0; i < sizeof(part_labels) / sizeof(part_labels[0]); i++)
            keel_log("plan: wait for %s", part_labels[i]);
        return 0;
    }
    keel_log("discover: waiting for partition links");
    deadline = time(NULL) + (time_t)ctx->timeout;
    for (;;) {
        time_t now = time(NULL);
        unsigned remaining;
        int ready;

        if (now >= deadline)
            break;
        remaining = (unsigned)(deadline - now);
        last_rc = keel_run_timeout(argv, remaining);
        if (last_rc == 124) {
            keel_err("keel-discover timed out after %us", remaining);
            return 4;
        }
        ready = last_rc == 0;
        missing = "none";
        for (i = 0; ready && i < sizeof(part_labels) / sizeof(part_labels[0]);
             i++) {
            if (!keel_path_exists(part_labels[i])) {
                missing = part_labels[i];
                ready = 0;
            }
        }
        if (ready)
            return 0;
        if (last_rc < 0)
            return 4;
        if (time(NULL) >= deadline)
            break;
        keel_sleep_ms(500);
    }
    keel_err("partition discovery timed out after %us (last status %d, "
             "missing %s)", ctx->timeout, last_rc, missing);
    return 4;
}

static int step_lvm(struct ctx *ctx)
{
    char *pvcreate[] = { "pvcreate", "--yes", "--force",
                         "/dev/disk/by-partlabel/system", NULL };
    char *vgcreate[] = { "vgcreate", "system",
                         "/dev/disk/by-partlabel/system", NULL };
    char *root_a[] = { "lvcreate", "--yes", "--name", "root_a",
                       "--size", "2G", "system", NULL };
    char *root_b[] = { "lvcreate", "--yes", "--name", "root_b",
                       "--size", "2G", "system", NULL };
    char *etc[] = { "lvcreate", "--yes", "--name", "etc",
                    "--size", "1G", "system", NULL };
    char *nodes[] = { "vgmknodes", "system", NULL };
    char *paths[] = { "/dev/system/root_a", "/dev/system/root_b",
                      "/dev/system/etc" };
    char *const *commands[] = { pvcreate, vgcreate, root_a, root_b, etc, nodes };
    size_t i;
    int rc;

    for (i = 0; i < sizeof(commands) / sizeof(commands[0]); i++) {
        rc = exec_argv(ctx, commands[i]);
        if (rc != 0)
            return rc;
    }
    for (i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (ctx->dry_run) {
            keel_log("plan: wait for %s", paths[i]);
            continue;
        }
        if (!keel_wait_for_path(paths[i], ctx->timeout)) {
            keel_err("timed out waiting for %s after %us", paths[i],
                     ctx->timeout);
            return 4;
        }
    }
    return 0;
}

static int plan_write(struct ctx *ctx, const char *source,
                      const char *target)
{
    unsigned long long size = keel_path_size(source);

    keel_log("plan: write %s -> %s (%llu bytes)", source, target, size);
    ctx->bytes_written += size;
    return 0;
}

static int step_write(struct ctx *ctx)
{
    char rootfs[PATH_MAX];
    char recovery[PATH_MAX];
    int rc;

    snprintf(rootfs, sizeof(rootfs), "%s/rootfs.erofs", ctx->source);
    snprintf(recovery, sizeof(recovery), "%s/recovery.erofs", ctx->source);
    if (ctx->dry_run) {
        plan_write(ctx, rootfs, "/dev/system/root_a");
        plan_write(ctx, rootfs, "/dev/system/root_b");
        return plan_write(ctx, recovery, "/dev/disk/by-partlabel/recovery");
    }
    rc = keel_write_image(rootfs, "/dev/system/root_a",
                          &ctx->bytes_written);
    if (rc != 0)
        return 4;
    rc = keel_write_image(rootfs, "/dev/system/root_b",
                          &ctx->bytes_written);
    if (rc != 0)
        return 4;
    return keel_write_image(recovery, "/dev/disk/by-partlabel/recovery",
                            &ctx->bytes_written) == 0 ? 0 : 4;
}

static int step_etc(struct ctx *ctx)
{
    char *mkfs[] = { "mkfs.ext4", "-F", "-L", "etc", "/dev/system/etc", NULL };
    char *cp[] = { "cp", "-a", "/mnt/root/etc/.", "/mnt/etc/", NULL };
    int rc;

    rc = make_dir(ctx, "/mnt/root", 0755);
    if (rc != 0)
        return rc;
    rc = make_dir(ctx, "/mnt/etc", 0755);
    if (rc != 0)
        return rc;
    rc = exec_argv(ctx, mkfs);
    if (rc != 0)
        return rc;
    rc = mount_fs(ctx, "/dev/system/root_a", "/mnt/root", "erofs", "ro",
                  &ctx->mounts[M_ROOT]);
    if (rc != 0)
        return rc;
    rc = mount_fs(ctx, "/dev/system/etc", "/mnt/etc", "ext4", "rw,noatime",
                  &ctx->mounts[M_ETC]);
    if (rc != 0)
        return rc;
    rc = exec_argv(ctx, cp);
    if (rc != 0)
        return rc;
    rc = umount_fs(ctx, &ctx->mounts[M_ETC]);
    if (rc != 0)
        return rc;
    return umount_fs(ctx, &ctx->mounts[M_ROOT]);
}

static int step_data(struct ctx *ctx)
{
    char *mkfs[] = { "mkfs.btrfs", "-f", "-L", "data",
                     "/dev/disk/by-partlabel/data", NULL };
    char *var[] = { "btrfs", "subvolume", "create", "/mnt/data/var", NULL };
    char *home[] = { "btrfs", "subvolume", "create", "/mnt/data/home", NULL };
    int rc;

    rc = make_dir(ctx, "/mnt/data", 0755);
    if (rc != 0)
        return rc;
    rc = make_dir(ctx, "/mnt/var", 0755);
    if (rc != 0)
        return rc;
    rc = make_dir(ctx, "/mnt/home", 0755);
    if (rc != 0)
        return rc;
    rc = exec_argv(ctx, mkfs);
    if (rc != 0)
        return rc;
    rc = mount_fs(ctx, "/dev/disk/by-partlabel/data", "/mnt/data", "btrfs",
                  "rw,noatime", &ctx->mounts[M_DATA]);
    if (rc != 0)
        return rc;
    rc = exec_argv(ctx, var);
    if (rc != 0)
        return rc;
    rc = exec_argv(ctx, home);
    if (rc != 0)
        return rc;
    rc = umount_fs(ctx, &ctx->mounts[M_DATA]);
    if (rc != 0)
        return rc;
    rc = mount_fs(ctx, "/dev/disk/by-partlabel/data", "/mnt/var", "btrfs",
                  "rw,noatime,subvol=var", &ctx->mounts[M_VAR]);
    if (rc != 0)
        return rc;
    rc = make_dir(ctx, "/mnt/var/lib/keel", 0755);
    if (rc != 0)
        return rc;
    rc = make_dir(ctx, "/mnt/var/log/journal", 0755);
    if (rc != 0)
        return rc;
    rc = umount_fs(ctx, &ctx->mounts[M_VAR]);
    if (rc != 0)
        return rc;
    rc = mount_fs(ctx, "/dev/disk/by-partlabel/data", "/mnt/home", "btrfs",
                  "rw,noatime,subvol=home", &ctx->mounts[M_HOME]);
    if (rc != 0)
        return rc;
    rc = make_dir(ctx, "/mnt/home/root", 0700);
    if (rc != 0)
        return rc;
    return umount_fs(ctx, &ctx->mounts[M_HOME]);
}

static int write_text(struct ctx *ctx, const char *path, const char *text)
{
    size_t len = strlen(text);
    size_t done = 0;
    int fd;

    if (ctx->dry_run) {
        keel_log("plan: write %s", path);
        fputs(text, stdout);
        return 0;
    }
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        keel_err("cannot write %s: %s", path, strerror(errno));
        return -1;
    }
    while (done < len) {
        ssize_t n = write(fd, text + done, len - done);

        if (n < 0) {
            if (errno == EINTR)
                continue;
            keel_err("cannot write %s: %s", path, strerror(errno));
            close(fd);
            return -1;
        }
        done += (size_t)n;
    }
    if (fsync(fd) < 0) {
        keel_err("cannot sync %s: %s", path, strerror(errno));
        close(fd);
        return -1;
    }
    if (close(fd) < 0) {
        keel_err("cannot close %s: %s", path, strerror(errno));
        return -1;
    }
    keel_log("write: %s", path);
    return 0;
}

static int esp_fail(const char *what)
{
    keel_err("disk is written but not bootable: %s", what);
    return 4;
}

static int step_esp(struct ctx *ctx)
{
    char *mkfs[] = { "mkfs.vfat", "-F", "32", "-n", "KEELESP",
                     "/dev/disk/by-partlabel/esp", NULL };
    char *bootctl[] = { "bootctl", "--esp-path=/mnt/esp", "install", NULL };
    char source_a[PATH_MAX];
    char source_b[PATH_MAX];
    char *cp_a[] = { "cp", "-a", source_a,
                     "/mnt/esp/EFI/Linux/keel-a+10.efi", NULL };
    char *cp_b[] = { "cp", "-a", source_b,
                     "/mnt/esp/EFI/Linux/keel-b+10.efi", NULL };
    int rc;

    snprintf(source_a, sizeof(source_a), "%s/keel-a.efi", ctx->source);
    snprintf(source_b, sizeof(source_b), "%s/keel-b.efi", ctx->source);
    rc = make_dir(ctx, "/mnt/esp", 0755);
    if (rc != 0)
        return esp_fail("cannot create ESP mount point");
    rc = exec_argv(ctx, mkfs);
    if (rc != 0)
        return esp_fail("mkfs.vfat failed");
    rc = mount_fs(ctx, "/dev/disk/by-partlabel/esp", "/mnt/esp", "vfat", "rw",
                  &ctx->mounts[M_ESP]);
    if (rc != 0)
        return esp_fail("ESP mount failed");
    rc = make_dir(ctx, "/mnt/esp/EFI/Linux", 0755);
    if (rc != 0)
        return esp_fail("cannot create EFI/Linux");
    rc = make_dir(ctx, "/mnt/esp/loader", 0755);
    if (rc != 0)
        return esp_fail("cannot create loader");
    rc = exec_argv(ctx, cp_a);
    if (rc != 0)
        return esp_fail("cannot copy keel-a.efi");
    rc = exec_argv(ctx, cp_b);
    if (rc != 0)
        return esp_fail("cannot copy keel-b.efi");
    rc = write_text(ctx, "/mnt/esp/loader/loader.conf",
                    "default keel-a*\ntimeout 3\n");
    if (rc != 0)
        return esp_fail("cannot write loader.conf");
    rc = exec_argv(ctx, bootctl);
    if (rc != 0)
        return esp_fail("bootctl install failed");
    if (!ctx->dry_run &&
        (!keel_path_exists("/mnt/esp/EFI/Linux/keel-a+10.efi") ||
         !keel_path_exists("/mnt/esp/EFI/Linux/keel-b+10.efi")))
        return esp_fail("UKIs missing after bootctl install");
    rc = umount_fs(ctx, &ctx->mounts[M_ESP]);
    if (rc != 0)
        return esp_fail("ESP unmount failed");
    return 0;
}

static int step_finish(struct ctx *ctx)
{
    if (ctx->dry_run) {
        keel_log("plan: sync");
        keel_log("plan: complete disk=%s partitions=esp,recovery,system,data "
                 "lvs=root_a,root_b,etc bytes=%llu",
                 ctx->disk, ctx->bytes_written);
        return 0;
    }
    sync();
    keel_log("complete disk=%s partitions=esp,recovery,system,data "
             "lvs=root_a,root_b,etc bytes=%llu",
             ctx->disk, ctx->bytes_written);
    return 0;
}

static const struct step steps[] = {
    { "validate", step_validate },
    { "partition", step_partition },
    { "discover", step_discover },
    { "lvm", step_lvm },
    { "write", step_write },
    { "etc", step_etc },
    { "data", step_data },
    { "esp", step_esp },
    { "finish", step_finish },
};

static int parse_timeout(const char *text, unsigned *timeout)
{
    char *end;
    unsigned long value;

    errno = 0;
    value = strtoul(text, &end, 10);
    if (errno != 0 || *text == '\0' || *end != '\0' || value < 1 ||
        value > 86400)
        return -1;
    *timeout = (unsigned)value;
    return 0;
}

int main(int argc, char **argv)
{
    static const struct option options[] = {
        { "disk", required_argument, NULL, 'd' },
        { "source", required_argument, NULL, 's' },
        { "dry-run", no_argument, NULL, 'n' },
        { "force", no_argument, NULL, 'f' },
        { "timeout", required_argument, NULL, 't' },
        { "self-test-timeout", required_argument, NULL, 1000 },
        { "help", no_argument, NULL, 'h' },
        { NULL, 0, NULL, 0 },
    };
    struct ctx ctx;
    int opt;
    int self_test = 0;
    unsigned self_test_timeout = 0;
    size_t i;

    keel_set_progname("keel-install");
    memset(&ctx, 0, sizeof(ctx));
    ctx.timeout = 60;
    for (i = 0; i < M_COUNT; i++)
        snprintf(ctx.mounts[i].target, sizeof(ctx.mounts[i].target), "%s",
                 mount_targets[i]);
    while ((opt = getopt_long(argc, argv, "d:s:nft:h", options, NULL)) != -1) {
        switch (opt) {
        case 'd':
            ctx.disk = optarg;
            break;
        case 's':
            ctx.source = optarg;
            break;
        case 'n':
            ctx.dry_run = 1;
            break;
        case 'f':
            ctx.force = 1;
            break;
        case 't':
            if (parse_timeout(optarg, &ctx.timeout) < 0) {
                keel_err("invalid timeout: %s", optarg);
                return 2;
            }
            break;
        case 1000:
            if (parse_timeout(optarg, &self_test_timeout) < 0) {
                keel_err("invalid self-test timeout: %s", optarg);
                return 2;
            }
            self_test = 1;
            break;
        case 'h':
            usage(stdout);
            return 0;
        default:
            usage(stderr);
            return 2;
        }
    }
    if (self_test) {
        char *argv[] = { "sleep", "30", NULL };
        int rc = keel_run_timeout(argv, self_test_timeout);

        keel_log("self-test-timeout: rc=%d", rc);
        return rc == 124 ? 0 : 1;
    }
    if (optind != argc || ctx.disk == NULL || ctx.source == NULL) {
        usage(stderr);
        return 2;
    }
    for (i = 0; i < sizeof(steps) / sizeof(steps[0]); i++) {
        int rc = steps[i].run(&ctx);

        if (rc != 0) {
            keel_err("step %s failed (%d)", steps[i].name, rc);
            keel_cleanup_mounts(ctx.mounts, M_COUNT, ctx.timeout);
            return rc;
        }
    }
    keel_cleanup_mounts(ctx.mounts, M_COUNT, ctx.timeout);
    return 0;
}
