#ifndef KEEL_INSTALLER_H
#define KEEL_INSTALLER_H

#include <keel/mount.h>

struct ctx {
    const char *disk;
    const char *source;
    int dry_run;
    int force;
    unsigned timeout;
    unsigned long long disk_size;
    unsigned long long bytes_written;
    struct keel_mount mounts[5];
};

struct step {
    const char *name;
    int (*run)(struct ctx *ctx);
};

#endif
