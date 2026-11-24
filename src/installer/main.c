#define _GNU_SOURCE
#include "installer.h"

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <linux/fs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>

#define GIB (1024ULL * 1024ULL * 1024ULL)
#define MIB (1024ULL * 1024ULL)
#define DISK_MIN (8ULL * GIB)
#define DISK_WARN (32ULL * GIB)

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
    fputs("usage: keel-install --disk <dev> --source <dir> "
          "[--dry-run] [--force] [--timeout <sec>]\n"
          "\n"
          "  --disk    target disk (real runs require a block device)\n"
          "  --source  directory with rootfs.erofs, recovery.erofs, "
          "keel-a.efi, keel-b.efi\n"
          "  --dry-run print the full plan; a regular file is accepted "
          "for planning\n"
          "  --force   overwrite an existing partition table\n"
          "  --timeout seconds to wait for a device (default 60)\n",
          out);
}

static int exec_argv(struct ctx *ctx, char *const argv[])
{
    if (ctx->dry_run) {
        print_argv("keel-install: plan: ", argv);
        return 0;
    }
    print_argv("keel-install: exec: ", argv);
    if (run_argv(argv) != 0) {
        fprintf(stderr, "keel-install: command failed: %s\n", argv[0]);
        return 4;
    }
    return 0;
}

static int exec_input(struct ctx *ctx, char *const argv[], const char *input)
{
    if (ctx->dry_run) {
        print_argv("keel-install: plan: ", argv);
        printf("keel-install: plan: stdin:\n%s", input);
        return 0;
    }
    print_argv("keel-install: exec: ", argv);
    if (run_argv_input(argv, input) != 0) {
        fprintf(stderr, "keel-install: command failed: %s\n", argv[0]);
        return 4;
    }
    return 0;
}

static int mount_fs(struct ctx *ctx, const char *source, const char *target,
                    const char *type, const char *options, int *flag)
{
    char *argv[] = { "mount", "-t", (char *)type, "-o", (char *)options,
                     (char *)source, (char *)target, NULL };
    int rc = exec_argv(ctx, argv);

    if (rc == 0)
        *flag = 1;
    return rc;
}

static int umount_fs(struct ctx *ctx, int *flag, const char *target)
{
    char *argv[] = { "umount", (char *)target, NULL };
    int rc;

    if (!*flag) {
        if (ctx->dry_run) {
            print_argv("keel-install: plan: ", argv);
        }
        return 0;
    }
    rc = exec_argv(ctx, argv);
    if (rc == 0)
        *flag = 0;
    return rc;
}

static int make_dir(struct ctx *ctx, const char *path, mode_t mode)
{
    if (ctx->dry_run) {
        printf("keel-install: plan: mkdir -p %s (mode %04o)\n", path, mode);
        return 0;
    }
    if (mkdir_p(path, mode) < 0) {
        fprintf(stderr, "keel-install: cannot create %s: %s\n", path,
                strerror(errno));
        return 4;
    }
    if (chmod(path, mode) < 0 && mode != 0755) {
        fprintf(stderr, "keel-install: cannot chmod %s: %s\n", path,
                strerror(errno));
        return 4;
    }
    return 0;
}

static const char *disk_basename(const char *disk)
{
    const char *slash = strrchr(disk, '/');

    return slash == NULL ? disk : slash + 1;
}

static int same_disk(const char *disk, dev_t dev)
{
    char link[PATH_MAX];
    char disk_path[PATH_MAX];
    char dev_path[PATH_MAX];
    size_t len;

    snprintf(link, sizeof(link), "/sys/class/block/%s", disk_basename(disk));
    if (realpath(link, disk_path) == NULL)
        return 0;
    snprintf(link, sizeof(link), "/sys/dev/block/%u:%u", major(dev), minor(dev));
    if (realpath(link, dev_path) == NULL)
        return 0;
    len = strlen(disk_path);
    return strcmp(disk_path, dev_path) == 0 ||
           (strncmp(disk_path, dev_path, len) == 0 && dev_path[len] == '/');
}

static int disk_is_mounted(const char *disk)
{
    struct stat st;
    FILE *fp;
    char line[4096];
    int mounted = 0;

    if (stat(disk, &st) < 0 || !S_ISBLK(st.st_mode))
        return 0;
    fp = fopen("/proc/self/mountinfo", "r");
    if (fp == NULL)
        return 0;
    while (fgets(line, sizeof(line), fp) != NULL) {
        unsigned maj, min;

        if (sscanf(line, "%*d %*d %u:%u", &maj, &min) != 2)
            continue;
        if (same_disk(disk, makedev(maj, min))) {
            mounted = 1;
            break;
        }
    }
    fclose(fp);
    return mounted;
}

static int disk_has_table(const char *disk)
{
    unsigned char buf[4096];
    ssize_t n;
    int fd = open(disk, O_RDONLY);

    if (fd < 0)
        return -1;
    n = pread(fd, buf, sizeof(buf), 0);
    close(fd);
    if (n < 512)
        return 0;
    if (buf[510] == 0x55 && buf[511] == 0xaa)
        return 1;
    if (n >= 520 && memcmp(buf + 512, "EFI PART", 8) == 0)
        return 1;
    return 0;
}

static int disk_size(const char *disk, unsigned long long *size)
{
    struct stat st;

    if (stat(disk, &st) < 0)
        return -1;
    if (S_ISREG(st.st_mode)) {
        *size = (unsigned long long)st.st_size;
        return 0;
    }
    if (S_ISBLK(st.st_mode)) {
        int fd = open(disk, O_RDONLY);

        if (fd < 0)
            return -1;
        if (ioctl(fd, BLKGETSIZE64, size) < 0) {
            close(fd);
            return -1;
        }
        close(fd);
        return 0;
    }
    return -1;
}

static int disk_has_vg(const char *disk)
{
    char out[4096];
    char *argv[] = { "pvs", "--noheadings", "--options",
                     "pv_name,vg_name", NULL };
    char *line;
    char *save = NULL;

    if (run_capture(argv, out, sizeof(out)) != 0)
        return -1;
    for (line = strtok_r(out, "\n", &save); line != NULL;
         line = strtok_r(NULL, "\n", &save)) {
        char *pv = line;
        char *vg;
        struct stat st;

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
        if (stat(pv, &st) == 0 && S_ISBLK(st.st_mode) &&
            same_disk(disk, st.st_rdev))
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
            fprintf(stderr, "keel-install: missing source file: %s\n", path);
            return 2;
        }
    }
    return 0;
}

static int check_disk(struct ctx *ctx)
{
    struct stat st;
    int table;

    if (stat(ctx->disk, &st) < 0) {
        fprintf(stderr, "keel-install: cannot stat disk %s: %s\n", ctx->disk,
                strerror(errno));
        return 3;
    }
    if (!ctx->dry_run && !S_ISBLK(st.st_mode)) {
        fprintf(stderr, "keel-install: not a block device: %s\n", ctx->disk);
        return 3;
    }
    if (ctx->dry_run && !S_ISBLK(st.st_mode) && !S_ISREG(st.st_mode)) {
        fprintf(stderr, "keel-install: not a disk or regular file: %s\n",
                ctx->disk);
        return 3;
    }
    if (disk_size(ctx->disk, &ctx->disk_size) < 0) {
        fprintf(stderr, "keel-install: cannot read disk size: %s\n", ctx->disk);
        return 3;
    }
    if (ctx->disk_size < DISK_MIN) {
        fprintf(stderr,
                "keel-install: disk too small: %s has %llu bytes, need 8 GiB\n",
                ctx->disk, ctx->disk_size);
        return 3;
    }
    if (ctx->disk_size < DISK_WARN)
        fprintf(stderr, "keel-install: warn: disk is smaller than 32 GiB; "
                        "data will be small\n");
    if (ctx->disk_size <= 8ULL * GIB + MIB) {
        fprintf(stderr,
                "keel-install: disk has no room for the data partition\n");
        return 3;
    }
    table = disk_has_table(ctx->disk);
    if (table < 0) {
        fprintf(stderr, "keel-install: cannot read %s: %s\n", ctx->disk,
                strerror(errno));
        return 3;
    }
    if (table && !ctx->force) {
        fprintf(stderr,
                "keel-install: disk already has a partition table; use --force\n");
        return 3;
    }
    if (!ctx->dry_run) {
        int vg;

        if (disk_is_mounted(ctx->disk)) {
            fprintf(stderr, "keel-install: disk is mounted: %s\n", ctx->disk);
            return 3;
        }
        vg = disk_has_vg(ctx->disk);
        if (vg < 0) {
            fprintf(stderr, "keel-install: cannot run pvs\n");
            return 4;
        }
        if (vg > 0) {
            fprintf(stderr, "keel-install: disk already has a VG: %s\n",
                    ctx->disk);
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
    printf("keel-install: disk=%s source=%s size=%llu force=%d timeout=%u\n",
           ctx->disk, ctx->source, ctx->disk_size, ctx->force, ctx->timeout);
    if (ctx->dry_run)
        printf("keel-install: plan: block-device, mount, and VG checks "
               "are skipped in dry-run\n");
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
        printf("keel-install: plan: gpt types: esp=EF00 recovery=8300 "
               "system=8E00 data=8300\n");
    rc = exec_input(ctx, sfdisk, sfdisk_script);
    if (rc != 0)
        return rc;
    /* Best effort: drop old kernel mappings before adding the new table. */
    if (ctx->dry_run) {
        print_argv("keel-install: plan: ", partx_drop);
    } else {
        print_argv("keel-install: exec: ", partx_drop);
        if (run_argv(partx_drop) < 0)
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
        print_argv("keel-install: plan: ", argv);
        for (i = 0; i < sizeof(part_labels) / sizeof(part_labels[0]); i++)
            printf("keel-install: plan: wait for %s\n", part_labels[i]);
        return 0;
    }
    printf("keel-install: discover: waiting for partition links\n");
    deadline = time(NULL) + (time_t)ctx->timeout;
    for (;;) {
        int ready;

        last_rc = run_argv(argv);
        ready = last_rc == 0;
        missing = "none";
        for (i = 0; ready && i < sizeof(part_labels) / sizeof(part_labels[0]);
             i++) {
            if (!path_exists(part_labels[i])) {
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
        sleep_ms(500);
    }
    fprintf(stderr,
            "keel-install: partition discovery timed out after %us "
            "(last status %d, missing %s)\n",
            ctx->timeout, last_rc, missing);
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
            printf("keel-install: plan: wait for %s\n", paths[i]);
            continue;
        }
        if (!wait_for_path(paths[i], ctx->timeout)) {
            fprintf(stderr,
                    "keel-install: timed out waiting for %s after %us\n",
                    paths[i], ctx->timeout);
            return 4;
        }
    }
    return 0;
}

static int write_all(int fd, const char *buf, size_t len)
{
    size_t done = 0;

    while (done < len) {
        ssize_t n = write(fd, buf + done, len - done);

        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        done += (size_t)n;
    }
    return 0;
}

static int write_image(struct ctx *ctx, const char *source,
                       const char *target)
{
    unsigned long long source_size = path_size(source);
    unsigned long long target_size = 0;
    char *buf;
    int in;
    int out;
    int rc = 0;

    if (ctx->dry_run) {
        printf("keel-install: plan: write %s -> %s (%llu bytes)\n", source,
               target, source_size);
        ctx->bytes_written += source_size;
        return 0;
    }
    in = open(source, O_RDONLY);
    if (in < 0) {
        fprintf(stderr, "keel-install: cannot open %s: %s\n", source,
                strerror(errno));
        return 4;
    }
    out = open(target, O_WRONLY);
    if (out < 0) {
        fprintf(stderr, "keel-install: cannot open %s: %s\n", target,
                strerror(errno));
        close(in);
        return 4;
    }
    if (ioctl(out, BLKGETSIZE64, &target_size) < 0) {
        fprintf(stderr, "keel-install: cannot size %s: %s\n", target,
                strerror(errno));
        close(in);
        close(out);
        return 4;
    }
    if (source_size > target_size) {
        fprintf(stderr, "keel-install: %s does not fit in %s\n", source,
                target);
        close(in);
        close(out);
        return 4;
    }
    buf = malloc(MIB);
    if (buf == NULL) {
        fprintf(stderr, "keel-install: out of memory\n");
        close(in);
        close(out);
        return 4;
    }
    for (;;) {
        ssize_t n = read(in, buf, MIB);

        if (n < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "keel-install: read %s: %s\n", source,
                    strerror(errno));
            rc = 4;
            break;
        }
        if (n == 0)
            break;
        if (write_all(out, buf, (size_t)n) < 0) {
            fprintf(stderr, "keel-install: write %s: %s\n", target,
                    strerror(errno));
            rc = 4;
            break;
        }
    }
    free(buf);
    if (rc == 0 && fsync(out) < 0) {
        fprintf(stderr, "keel-install: fsync %s: %s\n", target,
                strerror(errno));
        rc = 4;
    }
    if (close(out) < 0 && rc == 0) {
        fprintf(stderr, "keel-install: close %s: %s\n", target,
                strerror(errno));
        rc = 4;
    }
    close(in);
    if (rc == 0) {
        printf("keel-install: write: %s -> %s (%llu bytes)\n", source, target,
               source_size);
        ctx->bytes_written += source_size;
    }
    return rc;
}

static int step_write(struct ctx *ctx)
{
    char rootfs[PATH_MAX];
    char recovery[PATH_MAX];
    int rc;

    snprintf(rootfs, sizeof(rootfs), "%s/rootfs.erofs", ctx->source);
    snprintf(recovery, sizeof(recovery), "%s/recovery.erofs", ctx->source);
    rc = write_image(ctx, rootfs, "/dev/system/root_a");
    if (rc != 0)
        return rc;
    rc = write_image(ctx, rootfs, "/dev/system/root_b");
    if (rc != 0)
        return rc;
    return write_image(ctx, recovery, "/dev/disk/by-partlabel/recovery");
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
                  &ctx->mounted_root);
    if (rc != 0)
        return rc;
    rc = mount_fs(ctx, "/dev/system/etc", "/mnt/etc", "ext4", "rw,noatime",
                  &ctx->mounted_etc);
    if (rc != 0)
        return rc;
    rc = exec_argv(ctx, cp);
    if (rc != 0)
        return rc;
    rc = umount_fs(ctx, &ctx->mounted_etc, "/mnt/etc");
    if (rc != 0)
        return rc;
    return umount_fs(ctx, &ctx->mounted_root, "/mnt/root");
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
                  "rw,noatime", &ctx->mounted_data);
    if (rc != 0)
        return rc;
    rc = exec_argv(ctx, var);
    if (rc != 0)
        return rc;
    rc = exec_argv(ctx, home);
    if (rc != 0)
        return rc;
    rc = umount_fs(ctx, &ctx->mounted_data, "/mnt/data");
    if (rc != 0)
        return rc;
    rc = mount_fs(ctx, "/dev/disk/by-partlabel/data", "/mnt/var", "btrfs",
                  "rw,noatime,subvol=var", &ctx->mounted_var);
    if (rc != 0)
        return rc;
    rc = make_dir(ctx, "/mnt/var/lib/keel", 0755);
    if (rc != 0)
        return rc;
    rc = make_dir(ctx, "/mnt/var/log/journal", 0755);
    if (rc != 0)
        return rc;
    rc = umount_fs(ctx, &ctx->mounted_var, "/mnt/var");
    if (rc != 0)
        return rc;
    rc = mount_fs(ctx, "/dev/disk/by-partlabel/data", "/mnt/home", "btrfs",
                  "rw,noatime,subvol=home", &ctx->mounted_home);
    if (rc != 0)
        return rc;
    rc = make_dir(ctx, "/mnt/home/root", 0700);
    if (rc != 0)
        return rc;
    return umount_fs(ctx, &ctx->mounted_home, "/mnt/home");
}

static int step_finish(struct ctx *ctx)
{
    if (ctx->dry_run) {
        printf("keel-install: plan: sync\n");
        printf("keel-install: plan: complete disk=%s "
               "partitions=esp,recovery,system,data lvs=root_a,root_b,etc "
               "bytes=%llu\n",
               ctx->disk, ctx->bytes_written);
        return 0;
    }
    sync();
    printf("keel-install: complete disk=%s "
           "partitions=esp,recovery,system,data lvs=root_a,root_b,etc "
           "bytes=%llu\n",
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
        { "help", no_argument, NULL, 'h' },
        { NULL, 0, NULL, 0 },
    };
    struct ctx ctx;
    int opt;
    size_t i;

    memset(&ctx, 0, sizeof(ctx));
    ctx.timeout = 60;
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
                fprintf(stderr, "keel-install: invalid timeout: %s\n", optarg);
                return 2;
            }
            break;
        case 'h':
            usage(stdout);
            return 0;
        default:
            usage(stderr);
            return 2;
        }
    }
    if (optind != argc || ctx.disk == NULL || ctx.source == NULL) {
        usage(stderr);
        return 2;
    }
    for (i = 0; i < sizeof(steps) / sizeof(steps[0]); i++) {
        int rc = steps[i].run(&ctx);

        if (rc != 0) {
            fprintf(stderr, "keel-install: step %s failed (%d)\n",
                    steps[i].name, rc);
            cleanup_mounts(&ctx);
            return rc;
        }
    }
    cleanup_mounts(&ctx);
    return 0;
}
