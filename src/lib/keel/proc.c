#define _GNU_SOURCE
#include <keel/proc.h>

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

static pid_t spawn(char *const argv[])
{
    pid_t pid = fork();

    if (pid < 0) {
        keel_err("fork: %s", strerror(errno));
        return -1;
    }
    if (pid == 0) {
        execvp(argv[0], argv);
        fprintf(stderr, "%s: exec %s: %s\n", progname, argv[0],
                strerror(errno));
        _exit(127);
    }
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
    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    return 128 + WTERMSIG(status);
}

int keel_run(char *const argv[])
{
    pid_t pid = spawn(argv);

    return pid < 0 ? -1 : keel_wait(pid);
}

int keel_run_input(char *const argv[], const char *input)
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
        close(fds[1]);
        if (dup2(fds[0], STDIN_FILENO) < 0)
            _exit(127);
        close(fds[0]);
        execvp(argv[0], argv);
        fprintf(stderr, "%s: exec %s: %s\n", progname, argv[0],
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
    return keel_wait(pid);
}

int keel_capture(char *const argv[], char *out, size_t out_size)
{
    int fds[2];
    pid_t pid;
    size_t used = 0;

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
        close(fds[0]);
        if (dup2(fds[1], STDOUT_FILENO) < 0)
            _exit(127);
        close(fds[1]);
        execvp(argv[0], argv);
        fprintf(stderr, "%s: exec %s: %s\n", progname, argv[0],
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
    return keel_wait(pid);
}
