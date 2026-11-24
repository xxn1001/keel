#ifndef KEEL_INSTALLER_H
#define KEEL_INSTALLER_H

#include <stddef.h>
#include <sys/types.h>

struct ctx {
    const char *disk;
    const char *source;
    int dry_run;
    int force;
    unsigned timeout;
    unsigned long long disk_size;
    unsigned long long bytes_written;
    int mounted_root;
    int mounted_etc;
    int mounted_data;
    int mounted_var;
    int mounted_home;
};

struct step {
    const char *name;
    int (*run)(struct ctx *ctx);
};

void print_argv(const char *prefix, char *const argv[]);
int run_argv(char *const argv[]);
int run_argv_input(char *const argv[], const char *input);
int run_capture(char *const argv[], char *out, size_t out_size);
void sleep_ms(unsigned ms);
int wait_for_path(const char *path, unsigned timeout);
int mkdir_p(const char *path, mode_t mode);
int path_exists(const char *path);
unsigned long long path_size(const char *path);
void cleanup_mounts(struct ctx *ctx);

#endif
