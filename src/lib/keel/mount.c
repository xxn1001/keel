#define _GNU_SOURCE
#include <keel/mount.h>
#include <keel/proc.h>

#include <stdio.h>
#include <string.h>

int keel_mount(const char *source, const char *target, const char *type,
               const char *options, struct keel_mount *m)
{
    char *argv[] = { "mount", "-t", (char *)type, "-o", (char *)options,
                     (char *)source, (char *)target, NULL };

    if (m->active)
        return 0;
    snprintf(m->target, sizeof(m->target), "%s", target);
    if (keel_run(argv) != 0) {
        keel_err("mount %s failed", target);
        return -1;
    }
    m->active = 1;
    return 0;
}

int keel_umount(struct keel_mount *m)
{
    char *argv[] = { "umount", m->target, NULL };

    if (!m->active)
        return 0;
    if (keel_run(argv) != 0) {
        keel_err("warn: cannot unmount %s", m->target);
        return -1;
    }
    m->active = 0;
    return 0;
}

void keel_cleanup_mounts(struct keel_mount *list, size_t n)
{
    size_t i;

    for (i = n; i > 0; i--)
        keel_umount(&list[i - 1]);
}
