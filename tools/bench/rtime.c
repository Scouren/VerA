/* rtime: run a command; write wall seconds, cpu seconds, peak RSS MiB and exit status as one TSV line
   to $RTIME_OUT (appended), else fd 3, else stderr. $RTIME_QUIET sends the command's own output to /dev/null.
   A tiny parent on purpose: a child's ru_maxrss starts at its parent's size at fork, so a Python or shell
   parent reports its own 15 to 25 MiB for any smaller child. Build: zig cc -O2 -o rtime tools/bench/rtime.c */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/resource.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    pid_t pid = fork();
    if (pid == 0) {
        if (getenv("RTIME_QUIET")) { int n = open("/dev/null", O_WRONLY); dup2(n, 1); dup2(n, 2); }
        execvp(argv[1], argv + 1);
        _exit(127);
    }
    int st; struct rusage ru;
    wait4(pid, &st, 0, &ru);
    clock_gettime(CLOCK_MONOTONIC, &b);
    double wall = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
    double cpu = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
    const char *path = getenv("RTIME_OUT");
    FILE *out = path ? fopen(path, "a") : fdopen(3, "w");
    if (!out) out = stderr;
    fprintf(out, "%.4f\t%.4f\t%.1f\t%d\n", wall, cpu, ru.ru_maxrss / 1024.0, WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st));
    return 0;
}
