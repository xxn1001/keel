#ifndef KEEL_FS_H
#define KEEL_FS_H

#include <stddef.h>
#include <sys/types.h>

int keel_mkdir_p(const char *path, mode_t mode);
int keel_path_exists(const char *path);
unsigned long long keel_path_size(const char *path);
int keel_wait_for_path(const char *path, unsigned timeout);
void keel_sleep_ms(unsigned ms);
int keel_path_is_mounted(const char *path);
int keel_path_device_size(const char *path, unsigned long long *size);
int keel_path_sector_size(const char *path, unsigned *size);
int keel_path_has_partition_table(const char *path);
int keel_path_belongs_to(const char *path, const char *disk);
/* No timeout by design: bulk copy is bounded by progress, not total time. */
int keel_write_image(const char *source, const char *target,
                     unsigned long long *written);

#endif
