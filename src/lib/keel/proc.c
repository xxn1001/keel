#define _GNU_SOURCE
#include "proc.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>

static const char *progname = "keel";

void keel_set_progname(const char *name)
{
    progname = name != NULL && *name != '\0' ? name : "keel";
}

const char *keel_progname(void)
{
    return progname;
}

void keel_log(const char *fmt, ...)
{
    va_list ap;

    printf("%s: ", progname);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
}

void keel_err(const char *fmt, ...)
{
    va_list ap;

    fprintf(stderr, "%s: ", progname);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

void keel_print_argv(const char *tag, char *const argv[])
{
    size_t i;

    printf("%s: %s:", progname, tag);
    for (i = 0; argv[i] != NULL; i++)
        printf(" %s", argv[i]);
    putchar('\n');
}

static void sleep_ms(unsigned ms)
{
    struct timespec ts;

    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR)
        ;
}

static int exit_code(int status)
{
    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    return 128 + WTERMSIG(status);
}

static pid_t spawn(char *const argv[])
{
    pid_t pid = fork();

    if (pid < 0) {
        keel_err("fork: %s", strerror(errno));
        return -1;
    }
    if (pid == 0) {
        (void)setpgid(0, 0);
        execvp(argv[0], argv);
        fprintf(stderr, "%s: exec %s: %s\n", progname, argv[0],
                strerror(errno));
        _exit(127);
    }
    (void)setpgid(pid, pid);
    return pid;
}

int keel_wait(pid_t pid)
{
    int status;

    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR)
            continue;
        keel_err("waitpid: %s", strerror(errno));
        return -1;
    }
    return exit_code(status);
}

/* Kill the child's process group, not just the child. Shell helpers such as
 * keel-discover may leave grandchildren (blkid) holding the disk. */
static int kill_and_reap(pid_t pid)
{
    int status;
    pid_t rc;
    time_t deadline;

    if (kill(-pid, SIGTERM) < 0)
        (void)kill(pid, SIGTERM);
    deadline = time(NULL) + 2;
    for (;;) {
        rc = waitpid(pid, &status, WNOHANG);
        if (rc == pid)
            return 124;
        if (rc < 0 && errno != EINTR)
            break;
        if (time(NULL) >= deadline)
            break;
        sleep_ms(100);
    }
    if (kill(-pid, SIGKILL) < 0)
        (void)kill(pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
        ;
    return 124;
}

int keel_wait_timeout(pid_t pid, unsigned timeout_sec)
{
    time_t deadline = timeout_sec ? time(NULL) + (time_t)timeout_sec : 0;

    for (;;) {
        int status;
        pid_t rc = waitpid(pid, &status, WNOHANG);

        if (rc == pid)
            return exit_code(status);
        if (rc < 0) {
            if (errno == EINTR)
                continue;
            keel_err("waitpid: %s", strerror(errno));
            return -1;
        }
        if (timeout_sec && time(NULL) >= deadline)
            return kill_and_reap(pid);
        sleep_ms(50);
    }
}

int keel_run_timeout(char *const argv[], unsigned timeout_sec)
{
    pid_t pid = spawn(argv);

    return pid < 0 ? -1 : keel_wait_timeout(pid, timeout_sec);
}

int keel_run(char *const argv[])
{
    return keel_run_timeout(argv, 0);
}

int keel_run_input_timeout(char *const argv[], const char *input,
                           unsigned timeout_sec)
{
    int fds[2];
    pid_t pid;
    size_t len = strlen(input);
    size_t done = 0;

    if (pipe(fds) < 0) {
        keel_err("pipe: %s", strerror(errno));
        return -1;
    }
    pid = fork();
    if (pid < 0) {
        keel_err("fork: %s", strerror(errno));
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    if (pid == 0) {
        (void)setpgid(0, 0);
        close(fds[1]);
        if (dup2(fds[0], STDIN_FILENO) < 0)
            _exit(127);
        close(fds[0]);
        execvp(argv[0], argv);
        fprintf(stderr, "%s: exec %s: %s\n", progname, argv[0],
                strerror(errno));
        _exit(127);
    }
    (void)setpgid(pid, pid);
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
    return keel_wait_timeout(pid, timeout_sec);
}

int keel_run_input(char *const argv[], const char *input)
{
    return keel_run_input_timeout(argv, input, 0);
}

static int capture_timeout(pid_t pid, int fd, char *out, size_t out_size,
                           unsigned timeout_sec)
{
    time_t deadline = timeout_sec ? time(NULL) + (time_t)timeout_sec : 0;
    size_t used = 0;
    int flags = fcntl(fd, F_GETFL);

    if (flags >= 0)
        (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    for (;;) {
        int status;
        pid_t rc;

        for (;;) {
            ssize_t n;

            if (used + 1 >= out_size)
                break;
            n = read(fd, out + used, out_size - used - 1);
            if (n > 0) {
                used += (size_t)n;
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            break;
        }
        rc = waitpid(pid, &status, WNOHANG);
        if (rc == pid) {
            while (used + 1 < out_size) {
                ssize_t n = read(fd, out + used, out_size - used - 1);

                if (n > 0) {
                    used += (size_t)n;
                    continue;
                }
                if (n < 0 && errno == EINTR)
                    continue;
                break;
            }
            out[used] = '\0';
            close(fd);
            return exit_code(status);
        }
        if (rc < 0) {
            if (errno == EINTR)
                continue;
            keel_err("waitpid: %s", strerror(errno));
            out[used] = '\0';
            close(fd);
            return -1;
        }
        if (timeout_sec && time(NULL) >= deadline) {
            out[used] = '\0';
            close(fd);
            return kill_and_reap(pid);
        }
        sleep_ms(50);
    }
}

int keel_capture_timeout(char *const argv[], char *out, size_t out_size,
                         unsigned timeout_sec)
{
    int fds[2];
    pid_t pid;

    if (out_size == 0)
        return -1;
    out[0] = '\0';
    if (pipe(fds) < 0) {
        keel_err("pipe: %s", strerror(errno));
        return -1;
    }
    pid = fork();
    if (pid < 0) {
        keel_err("fork: %s", strerror(errno));
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    if (pid == 0) {
        (void)setpgid(0, 0);
        close(fds[0]);
        if (dup2(fds[1], STDOUT_FILENO) < 0)
            _exit(127);
        close(fds[1]);
        execvp(argv[0], argv);
        fprintf(stderr, "%s: exec %s: %s\n", progname, argv[0],
                strerror(errno));
        _exit(127);
    }
    (void)setpgid(pid, pid);
    close(fds[1]);
    return capture_timeout(pid, fds[0], out, out_size, timeout_sec);
}

int keel_capture(char *const argv[], char *out, size_t out_size)
{
    return keel_capture_timeout(argv, out, out_size, 0);
}
