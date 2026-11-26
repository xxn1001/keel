#ifndef KEEL_PROC_H
#define KEEL_PROC_H

#include <stddef.h>
#include <sys/types.h>

void keel_set_progname(const char *name);
const char *keel_progname(void);
void keel_log(const char *fmt, ...);
void keel_err(const char *fmt, ...);
void keel_print_argv(const char *tag, char *const argv[]);
int keel_run(char *const argv[]);
int keel_run_input(char *const argv[], const char *input);
int keel_capture(char *const argv[], char *out, size_t out_size);
int keel_wait(pid_t pid);

#endif
