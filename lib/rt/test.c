/*
 * The test runner for macOS and Linux, linked into the binaries `helix test` builds. The compiler turns a spec's
 * `describe` and `test` blocks into functions and a table of them in source order; `hx_test_main` (test_core.inc)
 * walks that table.
 *
 * Every `describe` runs in its own forked process: it sets up its fixtures and runs `beforeAll`, then forks once
 * more for each test inside. So each test starts from a fresh copy of the fixtures, and a panic, crash or timeout
 * only ends that one process. The process that forked a test waits for it and records the result.
 *
 * A test's stdout and stderr go to a file that's printed only if the test fails. Failed `expect`s write their
 * report to descriptor 3. Results are appended to a shared details file, and the counters live in shared memory,
 * so the top process can print the header and the details once every test has run.
 */

#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <math.h>
#include <regex.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "test_core.inc"

static int details_fd;      // the shared details file
static regex_t filter;

/* ---- what test_core.inc needs ---- */

/** Writes all of `text` to `fd`, in as few writes as it takes. */
static void write_all(int fd, const char *text, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, text, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        text += n;
        len -= (size_t)n;
    }
}

/** Appends to the details file in one write, so records from different processes never mix. */
static void detail(const char *text, size_t len) {
    write_all(details_fd, text, len);
}

/** The whole contents of an open file, from the start. */
static char *slurp(int fd, size_t *len) {
    Buf b = { 0 };
    buf_add(&b, "", 0);
    lseek(fd, 0, SEEK_SET);
    char chunk[4096];
    ssize_t n;
    while ((n = read(fd, chunk, sizeof chunk)) > 0 || (n < 0 && errno == EINTR)) {
        if (n > 0) buf_add(&b, chunk, (size_t)n);
    }
    *len = b.len;
    return b.data;
}

static char *details_text(size_t *len) {
    return slurp(details_fd, len);
}

static void out_write(const char *text, size_t len) {
    fwrite(text, 1, len, stdout);
}

static void out_flush(void) {
    fflush(stdout);
}

static void err_write(const char *text, size_t len) {
    fflush(stdout);
    write_all(2, text, len);
}

static void report_write(const char *text, size_t len) {
    write_all(3, text, len);
}

static void write_file(const char *path, const char *text, size_t len) {
    FILE *f = fopen(path, "w");
    if (f) {
        fwrite(text, 1, len, f);
        fclose(f);
    }
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static bool stdout_is_terminal(void) {
    return isatty(1);
}

static bool glob_match(const char *pattern, const char *text) {
    return fnmatch(pattern, text, 0) == 0;
}

static bool filter_compile(const char *pattern) {
    return regcomp(&filter, pattern, REG_EXTENDED | REG_NOSUB) == 0;
}

static bool filter_matches(const char *name) {
    return regexec(&filter, name, 0, NULL, 0) == 0;
}

/** A temporary file, already unlinked; it disappears when the last process closes it. */
static int temp_file(void) {
    const char *dir = getenv("TMPDIR");
    char path[1024];
    snprintf(path, sizeof path, "%s/helix-test-XXXXXX", dir && *dir ? dir : "/tmp");
    int fd = mkstemp(path);
    if (fd < 0) {
        perror("helix test: cannot create a temporary file");
        exit(2);
    }
    unlink(path);
    int high = fcntl(fd, F_DUPFD, 10);   // clear of 0-3, which every test process redirects
    if (high >= 0) {
        close(fd);
        fd = high;
    }
    return fd;
}

static bool platform_init(void) {
    t.shared = mmap(NULL, sizeof(Shared), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (t.shared == MAP_FAILED) {
        perror("helix test: mmap");
        return false;
    }
    memset(t.shared, 0, sizeof(Shared));
    details_fd = temp_file();
    return true;
}

/** Every process here is a fork, never started on its own. */
static int platform_child(int argc, char **argv) {
    (void)argc;
    (void)argv;
    return -1;
}

/* ---- running ---- */

/** Runs one test inside its own process; never returns. */
static void hx_test_child(int64_t index, int out, int report) {
    dup2(out, 1);
    dup2(out, 2);
    dup2(report, 3);
    close(out);
    close(report);
    const Entry *e = &t.entries[index];
    int64_t timeout = e->timeout_ms ? e->timeout_ms : t.timeout_ms;
    if (timeout > 0) {
        struct itimerval timer = { .it_value = { .tv_sec = timeout / 1000, .tv_usec = (timeout % 1000) * 1000 } };
        setitimer(ITIMER_REAL, &timer, NULL);
    }
    bool passed = hx_test_body(index);
    fflush(stdout);
    fflush(stderr);
    _exit(passed ? 0 : 1);
}

static void hx_run_test(int64_t index) {
    int out = temp_file(), report = temp_file();
    fflush(NULL);
    double start = now_ms();
    pid_t pid = fork();
    if (pid < 0) {
        perror("helix test: fork");
        exit(2);
    }
    if (pid == 0) hx_test_child(index, out, report);

    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    Outcome o = { .ms = now_ms() - start };
    char *output = slurp(out, &o.output_len);
    char *text = slurp(report, &o.report_len);
    close(out);
    close(report);
    o.output = output;
    o.report = text;
    o.passed = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    o.panicked = WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT && panic_line(output, &(size_t){ 0 });
    o.timed_out = WIFSIGNALED(status) && WTERMSIG(status) == SIGALRM;
    if (WIFSIGNALED(status) && !o.panicked && !o.timed_out) o.crash = strsignal(WTERMSIG(status));
    hx_record_test(index, &o);
    free(output);
    free(text);
}

/** A describe in its own process: fixtures and `beforeAll`, the tests inside, then `afterAll`. */
static void hx_run_describe(int64_t index, int64_t end) {
    const Entry *e = &t.entries[index];
    int out = temp_file(), report = temp_file();
    int64_t before = hx_tests_reported();
    fflush(NULL);
    pid_t pid = fork();
    if (pid < 0) {
        perror("helix test: fork");
        exit(2);
    }
    if (pid == 0) {
        dup2(out, 1);
        dup2(out, 2);
        dup2(report, 3);
        if (t.depth < MAX_DEPTH) t.path[t.depth++] = (int)index;
        uint16_t code = e->fn ? e->fn() : 0;
        if (code) {
            char reason[512];
            snprintf(reason, sizeof reason, "beforeAll or a fixture failed with error: %s", t.error_name(code));
            fflush(stdout);
            size_t len;
            char *output = slurp(out, &len);
            hx_fail_unreported(index, end, hx_tests_reported() - before, reason, output, len);
            _exit(0);
        }
        hx_run_range(index + 1, end);
        code = t.entries[end].fn ? t.entries[end].fn() : 0;
        if (code) hx_report_after_all(index, t.error_name(code));
        fflush(NULL);
        _exit(0);
    }

    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    if (!WIFEXITED(status)) {
        size_t len;
        char *output = slurp(out, &len);
        char reason[256];
        snprintf(reason, sizeof reason, "the block %s outside its tests: %s",
                 WTERMSIG(status) == SIGABRT ? "panicked" : "crashed", strsignal(WTERMSIG(status)));
        if (t.depth < MAX_DEPTH) t.path[t.depth++] = (int)index;
        hx_fail_unreported(index, end, hx_tests_reported() - before, reason, output, len);
        t.depth--;
        free(output);
    }
    close(out);
    close(report);
}
