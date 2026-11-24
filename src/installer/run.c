#define _GNU_SOURCE
#include "installer.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

void print_argv(const char *prefix, char *const argv[])
{
    size_t i;

    fputs(prefix, stdout);
    for (i = 0; argv[i] != NULL; i++) {
        if (i != 0)
            putchar(' ');
        fputs(argv[i], stdout);
    }
    putchar('\n');
}

static int wait_child(pid_t pid)
{
    int status;

    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR)
            continue;
        perror("keel-install: waitpid");
        return -1;
    }
    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    return 128 + WTERMSIG(status);
}

static pid_t spawn(char *const argv[])
{
    pid_t pid = fork();

    if (pid < 0) {
        perror("keel-install: fork");
        return -1;
    }
    if (pid == 0) {
        execvp(argv[0], argv);
        fprintf(stderr, "keel-install: exec %s: %s\n", argv[0],
                strerror(errno));
        _exit(127);
    }
    return pid;
}

int run_argv(char *const argv[])
{
    pid_t pid = spawn(argv);

    return pid < 0 ? -1 : wait_child(pid);
}

int run_argv_input(char *const argv[], const char *input)
{
    int fds[2];
    pid_t pid;
    size_t len = strlen(input);
    size_t done = 0;
    int status;

    if (pipe(fds) < 0) {
        perror("keel-install: pipe");
        return -1;
    }
    pid = fork();
    if (pid < 0) {
        perror("keel-install: fork");
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    if (pid == 0) {
        close(fds[1]);
        if (dup2(fds[0], STDIN_FILENO) < 0)
            _exit(127);
        close(fds[0]);
        execvp(argv[0], argv);
        fprintf(stderr, "keel-install: exec %s: %s\n", argv[0],
                strerror(errno));
        _exit(127);
    }
    close(fds[0]);
    while (done < len) {
        ssize_t n = write(fds[1], input + done, len - done);

        if (n < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        done += (size_t)n;
    }
    close(fds[1]);
    status = wait_child(pid);
    return status;
}

int run_capture(char *const argv[], char *out, size_t out_size)
{
    int fds[2];
    pid_t pid;
    size_t used = 0;

    if (out_size == 0)
        return -1;
    out[0] = '\0';
    if (pipe(fds) < 0) {
        perror("keel-install: pipe");
        return -1;
    }
    pid = fork();
    if (pid < 0) {
        perror("keel-install: fork");
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    if (pid == 0) {
        close(fds[0]);
        if (dup2(fds[1], STDOUT_FILENO) < 0)
            _exit(127);
        close(fds[1]);
        execvp(argv[0], argv);
        fprintf(stderr, "keel-install: exec %s: %s\n", argv[0],
                strerror(errno));
        _exit(127);
    }
    close(fds[1]);
    for (;;) {
        ssize_t n;

        if (used + 1 >= out_size)
            break;
        n = read(fds[0], out + used, out_size - used - 1);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (n == 0)
            break;
        used += (size_t)n;
    }
    close(fds[0]);
    out[used] = '\0';
    return wait_child(pid);
}

void sleep_ms(unsigned ms)
{
    struct timespec ts;

    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR)
        ;
}

int wait_for_path(const char *path, unsigned timeout)
{
    time_t deadline = time(NULL) + (time_t)timeout;

    while (!path_exists(path)) {
        if (time(NULL) >= deadline)
            return 0;
        sleep_ms(250);
    }
    return 1;
}

int mkdir_p(const char *path, mode_t mode)
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

int path_exists(const char *path)
{
    return access(path, F_OK) == 0;
}

unsigned long long path_size(const char *path)
{
    struct stat st;

    if (stat(path, &st) < 0)
        return 0;
    return (unsigned long long)st.st_size;
}

static void unmount_one(int *flag, const char *path)
{
    char *argv[] = { "umount", (char *)path, NULL };

    if (!*flag)
        return;
    if (run_argv(argv) == 0)
        *flag = 0;
    else
        fprintf(stderr, "keel-install: warn: cannot unmount %s\n", path);
}

void cleanup_mounts(struct ctx *ctx)
{
    unmount_one(&ctx->mounted_home, "/mnt/home");
    unmount_one(&ctx->mounted_var, "/mnt/var");
    unmount_one(&ctx->mounted_data, "/mnt/data");
    unmount_one(&ctx->mounted_etc, "/mnt/etc");
    unmount_one(&ctx->mounted_root, "/mnt/root");
}
