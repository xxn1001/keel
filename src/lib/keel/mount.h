#ifndef KEEL_MOUNT_H
#define KEEL_MOUNT_H

#include <limits.h>
#include <stddef.h>

struct keel_mount {
    int active;
    char target[PATH_MAX];
};

int keel_mount(const char *source, const char *target, const char *type,
               const char *options, struct keel_mount *m);
int keel_umount(struct keel_mount *m);
void keel_cleanup_mounts(struct keel_mount *list, size_t n);

#endif
