#define _GNU_SOURCE
#include "mount.h"
#include "proc.h"

#include <stdio.h>
#include <string.h>

int keel_mount(const char *source, const char *target, const char *type,
               const char *options, struct keel_mount *m,
               unsigned timeout_sec)
{
    char *argv[] = { "mount", "-t", (char *)type, "-o", (char *)options,
                     (char *)source, (char *)target, NULL };
    int rc;

    if (m->active)
        return 0;
    snprintf(m->target, sizeof(m->target), "%s", target);
    rc = keel_run_timeout(argv, timeout_sec);
    if (rc == 124) {
        keel_err("mount %s timed out after %us", target, timeout_sec);
        return -1;
    }
    if (rc != 0) {
        keel_err("mount %s failed", target);
        return -1;
    }
    m->active = 1;
    return 0;
}

int keel_umount(struct keel_mount *m, unsigned timeout_sec)
{
    char *argv[] = { "umount", m->target, NULL };
    int rc;

    if (!m->active)
        return 0;
    rc = keel_run_timeout(argv, timeout_sec);
    if (rc == 124) {
        keel_err("umount %s timed out after %us", m->target, timeout_sec);
        return -1;
    }
    if (rc != 0) {
        keel_err("warn: cannot unmount %s", m->target);
        return -1;
    }
    m->active = 0;
    return 0;
}

void keel_cleanup_mounts(struct keel_mount *list, size_t n,
                         unsigned timeout_sec)
{
    size_t i;

    for (i = n; i > 0; i--)
        keel_umount(&list[i - 1], timeout_sec);
}
