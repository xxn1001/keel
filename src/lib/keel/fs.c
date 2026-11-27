#define _GNU_SOURCE
#include "fs.h"
#include "proc.h"

#include <errno.h>
#include <fcntl.h>
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

void keel_sleep_ms(unsigned ms)
{
    struct timespec ts;

    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR)
        ;
}

int keel_path_exists(const char *path)
{
    return access(path, F_OK) == 0;
}

unsigned long long keel_path_size(const char *path)
{
    struct stat st;

    if (stat(path, &st) < 0)
        return 0;
    return (unsigned long long)st.st_size;
}

static int same_device(const char *path, dev_t dev)
{
    char link[PATH_MAX];
    char path_sys[PATH_MAX];
    char dev_sys[PATH_MAX];
    const char *base;
    size_t len;

    base = strrchr(path, '/');
    base = base == NULL ? path : base + 1;
    snprintf(link, sizeof(link), "/sys/class/block/%s", base);
    if (realpath(link, path_sys) == NULL)
        return 0;
    snprintf(link, sizeof(link), "/sys/dev/block/%u:%u", major(dev), minor(dev));
    if (realpath(link, dev_sys) == NULL)
        return 0;
    len = strlen(path_sys);
    return strcmp(path_sys, dev_sys) == 0 ||
           (strncmp(path_sys, dev_sys, len) == 0 && dev_sys[len] == '/');
}

int keel_path_is_mounted(const char *path)
{
    struct stat st;
    FILE *fp;
    char line[4096];
    int mounted = 0;

    if (stat(path, &st) < 0 || !S_ISBLK(st.st_mode))
        return 0;
    fp = fopen("/proc/self/mountinfo", "r");
    if (fp == NULL)
        return 0;
    while (fgets(line, sizeof(line), fp) != NULL) {
        unsigned maj, min;

        if (sscanf(line, "%*d %*d %u:%u", &maj, &min) != 2)
            continue;
        if (same_device(path, makedev(maj, min))) {
            mounted = 1;
            break;
        }
    }
    fclose(fp);
    return mounted;
}

int keel_path_device_size(const char *path, unsigned long long *size)
{
    struct stat st;

    if (stat(path, &st) < 0)
        return -1;
    if (S_ISREG(st.st_mode)) {
        *size = (unsigned long long)st.st_size;
        return 0;
    }
    if (S_ISBLK(st.st_mode)) {
        int fd = open(path, O_RDONLY);

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

int keel_path_sector_size(const char *path, unsigned *size)
{
    struct stat st;
    int fd;
    int value;

    if (stat(path, &st) < 0)
        return -1;
    if (S_ISREG(st.st_mode)) {
        *size = 512;
        return 0;
    }
    if (!S_ISBLK(st.st_mode))
        return -1;
    fd = open(path, O_RDONLY);
    if (fd < 0)
        return -1;
    if (ioctl(fd, BLKSSZGET, &value) < 0) {
        close(fd);
        return -1;
    }
    close(fd);
    *size = (unsigned)value;
    return 0;
}

int keel_path_belongs_to(const char *path, const char *disk)
{
    struct stat st;

    if (stat(path, &st) < 0 || !S_ISBLK(st.st_mode))
        return 0;
    return same_device(disk, st.st_rdev);
}

int keel_path_has_partition_table(const char *path)
{
    unsigned char buf[4096];
    ssize_t n;
    int fd = open(path, O_RDONLY);

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

int keel_wait_for_path(const char *path, unsigned timeout)
{
    time_t deadline = time(NULL) + (time_t)timeout;

    while (!keel_path_exists(path)) {
        if (time(NULL) >= deadline)
            return 0;
        keel_sleep_ms(250);
    }
    return 1;
}

int keel_mkdir_p(const char *path, mode_t mode)
{
    char *copy = strdup(path);
    char *p;
    int rc = 0;

    if (copy == NULL)
        return -1;
    for (p = copy + 1; *p != '\0'; p++) {
        if (*p != '/')
            continue;
        *p = '\0';
        if (mkdir(copy, mode) < 0 && errno != EEXIST) {
            rc = -1;
            break;
        }
        *p = '/';
    }
    if (rc == 0 && mkdir(copy, mode) < 0 && errno != EEXIST)
        rc = -1;
    free(copy);
    return rc;
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

static int write_image_impl(const char *source, const char *target,
                            unsigned long long *written)
{
    unsigned long long source_size = keel_path_size(source);
    unsigned long long target_size = 0;
    char *buf;
    int in;
    int out;
    int rc = 0;
    const size_t chunk = 1024U * 1024U;

    in = open(source, O_RDONLY);
    if (in < 0) {
        keel_err("cannot open %s: %s", source, strerror(errno));
        return -1;
    }
    out = open(target, O_WRONLY);
    if (out < 0) {
        keel_err("cannot open %s: %s", target, strerror(errno));
        close(in);
        return -1;
    }
    if (ioctl(out, BLKGETSIZE64, &target_size) < 0) {
        keel_err("cannot size %s: %s", target, strerror(errno));
        close(in);
        close(out);
        return -1;
    }
    if (source_size > target_size) {
        keel_err("%s does not fit in %s", source, target);
        close(in);
        close(out);
        return -1;
    }
    buf = malloc(chunk);
    if (buf == NULL) {
        keel_err("out of memory");
        close(in);
        close(out);
        return -1;
    }
    for (;;) {
        ssize_t n = read(in, buf, chunk);

        if (n < 0) {
            if (errno == EINTR)
                continue;
            keel_err("read %s: %s", source, strerror(errno));
            rc = -1;
            break;
        }
        if (n == 0)
            break;
        if (write_all(out, buf, (size_t)n) < 0) {
            keel_err("write %s: %s", target, strerror(errno));
            rc = -1;
            break;
        }
    }
    free(buf);
    if (rc == 0 && fsync(out) < 0) {
        keel_err("fsync %s: %s", target, strerror(errno));
        rc = -1;
    }
    if (close(out) < 0 && rc == 0) {
        keel_err("close %s: %s", target, strerror(errno));
        rc = -1;
    }
    close(in);
    if (rc == 0) {
        keel_log("write: %s -> %s (%llu bytes)", source, target, source_size);
        if (written != NULL)
            *written += source_size;
    }
    return rc;
}

int keel_write_image(const char *source, const char *target,
                     unsigned long long *written)
{
    return write_image_impl(source, target, written);
}

int keel_write_image_timeout(const char *source, const char *target,
                             unsigned long long *written,
                             unsigned timeout_sec)
{
    unsigned long long size = keel_path_size(source);
    pid_t pid;
    int rc;

    pid = fork();
    if (pid < 0) {
        keel_err("fork: %s", strerror(errno));
        return -1;
    }
    if (pid == 0) {
        (void)setpgid(0, 0);
        _exit(write_image_impl(source, target, NULL) == 0 ? 0 : 1);
    }
    (void)setpgid(pid, pid);
    rc = keel_wait_timeout(pid, timeout_sec);
    if (rc == 124) {
        keel_err("write %s -> %s timed out after %us", source, target,
                 timeout_sec);
        return -1;
    }
    if (rc != 0)
        return -1;
    if (written != NULL)
        *written += size;
    return 0;
}
