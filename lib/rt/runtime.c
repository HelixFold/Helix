/*
 * The Helix runtime for the alpha: the output functions `print` compiles to. It is plain C on purpose and will be
 * rewritten in Helix together with the standard library.
 *
 * Output goes through stdio, so it is buffered and flushed at exit. The panic handler flushes it too, so text
 * printed before a panic appears before the panic message.
 */

#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE   // REG_RIP in <ucontext.h>, for the fault handler
#endif
#ifndef __wasi__
#include <dlfcn.h>
#endif
#include <errno.h>
#if defined(__APPLE__) || defined(__GLIBC__)
#include <execinfo.h>
#define HX_HAVE_BACKTRACE 1
#endif
#include <fcntl.h>
#include <limits.h>
#include <inttypes.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#ifndef __wasi__   // WASI has no processes
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
#endif

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

static FILE *stream(int32_t fd) {
    return fd == 2 ? stderr : stdout;
}

/** Descriptors 1 and 2 go through stdio; others (a test's failure report is 3) are written directly. */
void hx_write(int32_t fd, const char *bytes, size_t len) {
    if (len == 0) return;
    if (fd <= 2) {
        fwrite(bytes, 1, len, stream(fd));
        return;
    }
    while (len > 0) {
        ssize_t n = write(fd, bytes, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        bytes += n;
        len -= (size_t)n;
    }
}

#define HX_I64 "lld"
#define HX_U64 "llu"
#define HX_X64 "llx"
#include "format.inc"

/* ---- files ---- */

/*
 * Thin wrappers over POSIX for `std/fs`. They take Helix strings (pointer and length, not NUL-terminated), retry
 * on EINTR, and turn errno into small codes that mean the same on every platform. A negative result is -code:
 *
 *   1 NotFound   2 AccessDenied   3 IsDirectory   4 AlreadyExists   5 NoSpace   6 NameTooLong   7 Unexpected
 */

enum { FS_NOT_FOUND = 1, FS_ACCESS_DENIED, FS_IS_DIRECTORY, FS_ALREADY_EXISTS, FS_NO_SPACE, FS_NAME_TOO_LONG, FS_UNEXPECTED };

static int64_t fs_error(void) {
    switch (errno) {
    case ENOENT: case ENOTDIR: return -FS_NOT_FOUND;
    case EACCES: case EPERM: case EROFS: return -FS_ACCESS_DENIED;
    case EISDIR: return -FS_IS_DIRECTORY;
    case EEXIST: return -FS_ALREADY_EXISTS;
    case ENOSPC: case EDQUOT: return -FS_NO_SPACE;
    case ENAMETOOLONG: return -FS_NAME_TOO_LONG;
    default: return -FS_UNEXPECTED;
    }
}

static bool fs_path(char *out, const char *path, size_t len) {
    if (len >= PATH_MAX || memchr(path, 0, len)) return false;
    memcpy(out, path, len);
    out[len] = '\0';
    return true;
}

/** Opens a file. `mode`: 0 read, 1 write (create or truncate), 2 append (create), 3 create new (fails if it exists). */
int64_t hx_fs_open(const char *path, size_t len, int32_t mode) {
    char name[PATH_MAX];
    if (!fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    static const int flags[] = {
        O_RDONLY,
        O_WRONLY | O_CREAT | O_TRUNC,
        O_WRONLY | O_CREAT | O_APPEND,
        O_WRONLY | O_CREAT | O_EXCL,
    };
    if (mode < 0 || mode > 3) return -FS_UNEXPECTED;
    int fd;
    do fd = open(name, flags[mode] | O_CLOEXEC, 0666);
    while (fd < 0 && errno == EINTR);
    if (fd < 0) return fs_error();
    struct stat st;
    if (mode == 0 && fstat(fd, &st) == 0 && S_ISDIR(st.st_mode)) {
        close(fd);
        return -FS_IS_DIRECTORY;
    }
    return fd;
}

/** Reads up to `len` bytes; 0 at the end of the file. */
int64_t hx_fs_read(int32_t fd, char *buf, size_t len) {
    ssize_t n;
    do n = read(fd, buf, len);
    while (n < 0 && errno == EINTR);
    return n < 0 ? fs_error() : n;
}

/** Writes all `len` bytes, or fails. */
int64_t hx_fs_write(int32_t fd, const char *bytes, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, bytes, len);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return fs_error();
        bytes += n;
        len -= (size_t)n;
    }
    return 0;
}

void hx_fs_close(int32_t fd) {
    close(fd);
}

/** The size of an open file, for reading it whole. */
int64_t hx_fs_size(int32_t fd) {
    struct stat st;
    return fstat(fd, &st) == 0 ? (int64_t)st.st_size : fs_error();
}

/** `mkdir -p`: the folder and any missing parents. */
int64_t hx_fs_make_path(const char *path, size_t len) {
    char name[PATH_MAX];
    if (!fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    for (char *p = name + 1;; p++) {
        if (*p != '/' && *p != '\0') continue;
        char saved = *p;
        *p = '\0';
        if (mkdir(name, 0777) != 0 && errno != EEXIST) return fs_error();
        *p = saved;
        if (!saved) return 0;
    }
}

/** Copies a file, keeping its permissions (an executable stays executable). */
int64_t hx_fs_copy(const char *from, size_t from_len, const char *to, size_t to_len) {
    char src[PATH_MAX], dst[PATH_MAX];
    if (!fs_path(src, from, from_len) || !fs_path(dst, to, to_len)) return -FS_NAME_TOO_LONG;
    int in = open(src, O_RDONLY | O_CLOEXEC);
    if (in < 0) return fs_error();
    struct stat st;
    if (fstat(in, &st) != 0) {
        int64_t err = fs_error();
        close(in);
        return err;
    }
    unlink(dst);   // a running program may hold the old file; replace it rather than writing into it
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, st.st_mode & 0777);
    if (out < 0) {
        int64_t err = fs_error();
        close(in);
        return err;
    }
    char buf[65536];
    int64_t result = 0;
    for (;;) {
        ssize_t n = read(in, buf, sizeof buf);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            if (n < 0) result = fs_error();
            break;
        }
        for (ssize_t done = 0; done < n;) {
            ssize_t w = write(out, buf + done, (size_t)(n - done));
            if (w < 0 && errno == EINTR) continue;
            if (w < 0) {
                result = fs_error();
                break;
            }
            done += w;
        }
        if (result) break;
    }
    close(in);
    close(out);
    return result;
}

int64_t hx_fs_delete(const char *path, size_t len) {
    char name[PATH_MAX];
    if (!fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    return unlink(name) == 0 ? 0 : fs_error();
}

/** What `hx_fs_stat` reports. `kind`: 0 file, 1 folder, 2 symbolic link, 3 something else. */
typedef struct {
    int64_t size;
    int64_t mtime;      // seconds since 1970
    int32_t kind;
    uint32_t mode;      // the permission bits
} HxStat;

/** `stat`, or with `follow` 0 `lstat` (a link is reported as itself). */
int64_t hx_fs_stat(const char *path, size_t len, int32_t follow, HxStat *out) {
    char name[PATH_MAX];
    if (!fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    struct stat st;
    if ((follow ? stat(name, &st) : lstat(name, &st)) != 0) return fs_error();
    out->size = (int64_t)st.st_size;
    out->mtime = (int64_t)st.st_mtime;
    out->kind = S_ISREG(st.st_mode) ? 0 : S_ISDIR(st.st_mode) ? 1 : S_ISLNK(st.st_mode) ? 2 : 3;
    out->mode = (uint32_t)(st.st_mode & 07777);
    return 0;
}

/** Opens a folder for listing: a handle for `hx_fs_dir_next`, or an error. */
int64_t hx_fs_dir_open(const char *path, size_t len) {
    char name[PATH_MAX];
    if (!fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    DIR *d = opendir(name);
    return d == NULL ? fs_error() : (int64_t)(intptr_t)d;
}

/** The next name in the folder (without `.` and `..`) copied into `out`: its length, 0 at the end. */
int64_t hx_fs_dir_next(int64_t handle, char *out, size_t cap) {
    DIR *d = (DIR *)(intptr_t)handle;
    for (;;) {
        errno = 0;
        struct dirent *e = readdir(d);
        if (e == NULL) return errno ? fs_error() : 0;
        if (e->d_name[0] == '.' && (e->d_name[1] == 0 || (e->d_name[1] == '.' && e->d_name[2] == 0))) continue;
        size_t n = strlen(e->d_name);
        if (n > cap) return -FS_NAME_TOO_LONG;
        memcpy(out, e->d_name, n);
        return (int64_t)n;
    }
}

void hx_fs_dir_close(int64_t handle) {
    closedir((DIR *)(intptr_t)handle);
}

/** Renames (or moves, on the same file system) a file or folder, replacing a file at `to`. */
int64_t hx_fs_rename(const char *from, size_t from_len, const char *to, size_t to_len) {
    char src[PATH_MAX], dst[PATH_MAX];
    if (!fs_path(src, from, from_len) || !fs_path(dst, to, to_len)) return -FS_NAME_TOO_LONG;
    return rename(src, dst) == 0 ? 0 : fs_error();
}

static int64_t delete_tree(char *path, size_t len) {
    struct stat st;
    if (lstat(path, &st) != 0) return errno == ENOENT ? 0 : fs_error();
    if (!S_ISDIR(st.st_mode)) return unlink(path) == 0 ? 0 : fs_error();   // a link goes, never what it points at
    DIR *d = opendir(path);
    if (d == NULL) return fs_error();
    int64_t result = 0;
    struct dirent *e;
    while (result == 0 && (e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.' && (e->d_name[1] == 0 || (e->d_name[1] == '.' && e->d_name[2] == 0))) continue;
        size_t n = strlen(e->d_name);
        if (len + 1 + n >= PATH_MAX) {
            result = -FS_NAME_TOO_LONG;
            break;
        }
        path[len] = '/';
        memcpy(path + len + 1, e->d_name, n + 1);
        result = delete_tree(path, len + 1 + n);
        path[len] = '\0';
    }
    closedir(d);
    if (result == 0 && rmdir(path) != 0) result = fs_error();
    return result;
}

/** `rm -rf`: the file or folder and everything in it. A symbolic link is removed itself. Missing is fine. */
int64_t hx_fs_delete_tree(const char *path, size_t len) {
    char name[PATH_MAX];
    if (!fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    return delete_tree(name, len);
}

/** A symbolic link at `path` holding `target`. */
int64_t hx_fs_symlink(const char *target, size_t target_len, const char *path, size_t len) {
    char t[PATH_MAX], name[PATH_MAX];
    if (!fs_path(t, target, target_len) || !fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    return symlink(t, name) == 0 ? 0 : fs_error();
}

/** What the symbolic link holds, copied into `out`: its length. */
int64_t hx_fs_read_link(const char *path, size_t len, char *out, size_t cap) {
    char name[PATH_MAX];
    if (!fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    ssize_t n = readlink(name, out, cap);
    return n < 0 ? fs_error() : n;
}

/** The environment variable `name`, or NULL. */
const char *hx_getenv(const char *name, size_t len) {
    char key[256];
    if (len >= sizeof key || memchr(name, 0, len)) return NULL;
    memcpy(key, name, len);
    key[len] = '\0';
    return getenv(key);
}

/* ---- processes ---- */

/** A Helix string: pointer and length. */
typedef struct {
    const char *ptr;
    size_t len;
} HxString;

#ifdef __wasi__
int64_t hx_process_run(const HxString *argv, size_t count) {
    if (count > 0) fprintf(stderr, "error: cannot run '%.*s': WASI programs can't start other programs\n", (int)argv[0].len, argv[0].ptr);
    return -1;
}

int64_t hx_process_capture(const HxString *argv, size_t count, char **out, size_t *out_len) {
    *out = NULL;
    *out_len = 0;
    return hx_process_run(argv, count);
}

int64_t hx_process_capture_all(const HxString *argv, size_t count, const char *dir, size_t dir_len, int64_t timeout_ms,
                               char **out, size_t *out_len, char **err, size_t *err_len) {
    (void)dir;
    (void)dir_len;
    (void)timeout_ms;
    *err = NULL;
    *err_len = 0;
    return hx_process_capture(argv, count, out, out_len);
}

/** WebAssembly code can't read its own call stack; the host (wasmtime, Node) prints it when the program traps. */
void hx_stack_trace(void) {}
#else
extern char **environ;

/**
 * Runs a program and waits for it: `argv[0]` is looked up in PATH. Returns its exit status, 128 + the signal that
 * killed it, or -1 if it couldn't start (the reason is printed).
 */
int64_t hx_process_run(const HxString *argv, size_t count) {
    if (count == 0) return -1;
    char **args = calloc(count + 1, sizeof(char *));
    if (!args) return -1;
    for (size_t i = 0; i < count; i++) args[i] = strndup(argv[i].ptr, argv[i].len);
    fflush(NULL);   // output printed so far comes before the child's
    pid_t pid;
    int err = posix_spawnp(&pid, args[0], NULL, NULL, args, environ);
    int64_t result = -1;
    if (err != 0) {
        fprintf(stderr, "error: cannot run '%s': %s\n", args[0], strerror(err));
    } else {
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        result = WIFEXITED(status) ? WEXITSTATUS(status) : WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1;
    }
    for (size_t i = 0; i < count; i++) free(args[i]);
    free(args);
    return result;
}

/**
 * Like `hx_process_run`, with the program's stdout captured: `*out` gets malloc'ed bytes (`*out_len` of them),
 * which the caller frees. stderr and stdin are inherited.
 */
int64_t hx_process_capture(const HxString *argv, size_t count, char **out, size_t *out_len) {
    *out = NULL;
    *out_len = 0;
    if (count == 0) return -1;
    int fds[2];
    if (pipe(fds) != 0) return -1;
    char **args = calloc(count + 1, sizeof(char *));
    if (!args) return -1;
    for (size_t i = 0; i < count; i++) args[i] = strndup(argv[i].ptr, argv[i].len);
    fflush(NULL);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], 1);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);
    pid_t pid;
    int err = posix_spawnp(&pid, args[0], &actions, NULL, args, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);
    int64_t result = -1;
    if (err != 0) {
        fprintf(stderr, "error: cannot run '%s': %s\n", args[0], strerror(err));
    } else {
        size_t cap = 4096, len = 0;
        char *buf = malloc(cap);
        for (;;) {
            if (len == cap) buf = realloc(buf, cap *= 2);
            ssize_t n = read(fds[0], buf + len, cap - len);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            len += (size_t)n;
        }
        *out = buf;
        *out_len = len;
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        result = WIFEXITED(status) ? WEXITSTATUS(status) : WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1;
    }
    close(fds[0]);
    for (size_t i = 0; i < count; i++) free(args[i]);
    free(args);
    return result;
}

/** Milliseconds on a clock that only goes forward. */
static int64_t monotonic_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

/**
 * Like `hx_process_capture`, with the program's stderr captured too: `*err` gets malloc'ed bytes (`*err_len` of
 * them), which the caller frees. Both pipes are read as they fill, so a program that writes a lot to one of them
 * while the other is quiet doesn't block. The program starts in `dir` when `dir_len` isn't 0, and is killed once
 * `timeout_ms` (when above 0) has passed, which makes its status 128 + 9.
 */
int64_t hx_process_capture_all(const HxString *argv, size_t count, const char *dir, size_t dir_len, int64_t timeout_ms,
                               char **out, size_t *out_len, char **err, size_t *err_len) {
    *out = NULL;
    *out_len = 0;
    *err = NULL;
    *err_len = 0;
    if (count == 0) return -1;
    int out_fds[2], err_fds[2];
    if (pipe(out_fds) != 0) return -1;
    if (pipe(err_fds) != 0) {
        close(out_fds[0]);
        close(out_fds[1]);
        return -1;
    }
    char **args = calloc(count + 1, sizeof(char *));
    if (!args) return -1;
    for (size_t i = 0; i < count; i++) args[i] = strndup(argv[i].ptr, argv[i].len);
    fflush(NULL);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, out_fds[1], 1);
    posix_spawn_file_actions_adddup2(&actions, err_fds[1], 2);
    posix_spawn_file_actions_addclose(&actions, out_fds[0]);
    posix_spawn_file_actions_addclose(&actions, out_fds[1]);
    posix_spawn_file_actions_addclose(&actions, err_fds[0]);
    posix_spawn_file_actions_addclose(&actions, err_fds[1]);
    char *folder = dir_len > 0 ? strndup(dir, dir_len) : NULL;
#pragma clang diagnostic push   // macOS 26 adds posix_spawn_file_actions_addchdir, but programs run on older macOS too
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (folder) posix_spawn_file_actions_addchdir_np(&actions, folder);
#pragma clang diagnostic pop
    pid_t pid;
    int failed = posix_spawnp(&pid, args[0], &actions, NULL, args, environ);
    free(folder);
    posix_spawn_file_actions_destroy(&actions);
    close(out_fds[1]);
    close(err_fds[1]);
    int64_t result = -1;
    if (failed != 0) {
        fprintf(stderr, "error: cannot run '%s': %s\n", args[0], strerror(failed));
    } else {
        struct pollfd ends[2] = { { out_fds[0], POLLIN, 0 }, { err_fds[0], POLLIN, 0 } };
        char *bufs[2] = { malloc(4096), malloc(4096) };
        size_t caps[2] = { 4096, 4096 }, lens[2] = { 0, 0 };
        int open = 2;
        int64_t deadline = timeout_ms > 0 ? monotonic_ms() + timeout_ms : 0;
        int stop_after_drain = 0;
        while (open > 0) {
            int wait_ms = -1;
            if (deadline > 0) {
                int64_t left = deadline - monotonic_ms();
                if (left <= 0) {
                    // its own children may keep the pipes open, so take what is there now and stop reading
                    kill(pid, SIGKILL);
                    deadline = 0;
                    stop_after_drain = 1;
                    continue;
                }
                wait_ms = (int)left;
            }
            int ready = poll(ends, 2, stop_after_drain ? 0 : wait_ms);
            if (ready == 0) {
                if (stop_after_drain) break;
                continue;
            }
            if (ready < 0) {
                if (errno == EINTR) continue;
                break;
            }
            for (int i = 0; i < 2; i++) {
                if (ends[i].fd < 0 || !(ends[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
                if (lens[i] == caps[i]) bufs[i] = realloc(bufs[i], caps[i] *= 2);
                ssize_t n = read(ends[i].fd, bufs[i] + lens[i], caps[i] - lens[i]);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) {
                    ends[i].fd = -1;   // poll skips it from now on
                    open--;
                } else {
                    lens[i] += (size_t)n;
                }
            }
        }
        *out = bufs[0];
        *out_len = lens[0];
        *err = bufs[1];
        *err_len = lens[1];
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        result = WIFEXITED(status) ? WEXITSTATUS(status) : WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1;
    }
    close(out_fds[0]);
    close(err_fds[0]);
    for (size_t i = 0; i < count; i++) free(args[i]);
    free(args);
    return result;
}

/* ---- stack traces ---- */

/*
 * A panic prints the call stack. With debug info the frames are symbolized by the platform's tool - `atos` on
 * macOS, `addr2line` elsewhere - into "at function (file.hx:line)". Without it, function names and offsets are
 * printed instead. Zig parses DWARF itself; the alpha leans on the system tools until the runtime is rewritten.
 */

#define MAX_FRAMES 64

/** Prints one atos/addr2line line as "  at name (file:line)", skipping frames outside Helix code. */
static void print_symbolized(const char *line) {
    char name[256] = { 0 };
    const char *location = strrchr(line, '(');
    const char *space = strstr(line, " (in ");   // atos: "name (in binary) (file:line)"; names may hold spaces
    if (!space) space = strchr(line, ' ');
    if (!space) return;
    size_t len = (size_t)(space - line) < sizeof name - 1 ? (size_t)(space - line) : sizeof name - 1;
    memcpy(name, line, len);
    if (strcmp(name, "main") == 0 || strncmp(name, "0x", 2) == 0) return;   // the C entry wrapper, system code
    if (strncmp(name, "helix.", 6) == 0 || strncmp(name, "hx_", 3) == 0) return;   // the panic machinery itself
    if (location && strstr(location, ".hx:")) {
        char where[512];
        snprintf(where, sizeof where, "%s", location + 1);
        char *close = strrchr(where, ')');
        if (close) *close = '\0';
        fprintf(stderr, "  at %s (%s)\n", name, where);
    } else {
        fprintf(stderr, "  at %s\n", name);
    }
}

static int symbolize(void **frames, int count) {
    char command[8192];
    size_t used;
#ifdef __APPLE__
    char exe[4096];
    uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0) return 0;
    const void *base = _dyld_get_image_header(0);
    used = (size_t)snprintf(command, sizeof command, "atos -o '%s' -l %p", exe, base);
    for (int i = 0; i < count && used < sizeof command - 32; i++) used += (size_t)snprintf(command + used, sizeof command - used, " %p", frames[i]);
#else
    // a position-independent program is asked about offsets from where it's loaded; a static one (what Helix
    // links for Linux) about the addresses themselves
    Dl_info info;
    uintptr_t base = dladdr(frames[0], &info) && info.dli_fname ? (uintptr_t)info.dli_fbase : 0;
    used = (size_t)snprintf(command, sizeof command, "addr2line -f -p -e /proc/self/exe");
    for (int i = 0; i < count && used < sizeof command - 32; i++) {
        used += (size_t)snprintf(command + used, sizeof command - used, " 0x%" PRIxPTR, (uintptr_t)frames[i] - base);
    }
#endif
    used += (size_t)snprintf(command + used, sizeof command - used, " 2>/dev/null");
    FILE *pipe = popen(command, "r");
    if (!pipe) return 0;
    char line[1024];
    int lines = 0;
    while (fgets(line, sizeof line, pipe)) {
        line[strcspn(line, "\n")] = '\0';
#ifndef __APPLE__
        // addr2line -p prints "name at file:line"; reshape it like atos: "name (file:line)"
        char *at = strstr(line, " at ");
        if (at) {
            char shaped[1024];
            snprintf(shaped, sizeof shaped, "%.*s (%s)", (int)(at - line), line, at + 4);
            print_symbolized(shaped);
            lines++;
            continue;
        }
#endif
        print_symbolized(line);
        lines++;
    }
    return pclose(pipe) == 0 && lines > 0;
}

#if defined(__linux__)
#include <elf.h>

/**
 * Without addr2line (Alpine and most containers don't have it), the function names come from the program's own
 * symbol table. Helix links Linux programs statically and not position-independent, so an address in the program
 * is the address the symbol table lists.
 */
static void print_from_symtab(void **frames, int count) {
    FILE *f = fopen("/proc/self/exe", "rb");
    Elf64_Ehdr eh;
    Elf64_Shdr *sections = NULL;
    Elf64_Sym *symbols = NULL;
    char *names = NULL;
    size_t symbol_count = 0;
    if (f && fread(&eh, sizeof eh, 1, f) == 1 && memcmp(eh.e_ident, ELFMAG, SELFMAG) == 0 && eh.e_shentsize == sizeof(Elf64_Shdr)) {
        sections = calloc(eh.e_shnum, sizeof(Elf64_Shdr));
        if (sections && fseek(f, (long)eh.e_shoff, SEEK_SET) == 0 && fread(sections, sizeof(Elf64_Shdr), eh.e_shnum, f) == eh.e_shnum) {
            for (int i = 0; i < eh.e_shnum && !symbols; i++) {
                if (sections[i].sh_type != SHT_SYMTAB || sections[i].sh_link >= eh.e_shnum) continue;
                const Elf64_Shdr *strtab = &sections[sections[i].sh_link];
                symbol_count = sections[i].sh_size / sizeof(Elf64_Sym);
                symbols = malloc(sections[i].sh_size);
                names = malloc(strtab->sh_size + 1);
                if (!symbols || !names || fseek(f, (long)sections[i].sh_offset, SEEK_SET) != 0 ||
                    fread(symbols, sizeof(Elf64_Sym), symbol_count, f) != symbol_count ||
                    fseek(f, (long)strtab->sh_offset, SEEK_SET) != 0 || fread(names, 1, strtab->sh_size, f) != strtab->sh_size) {
                    symbol_count = 0;
                } else {
                    names[strtab->sh_size] = '\0';
                }
            }
        }
    }
    for (int i = 0; i < count; i++) {
        uintptr_t at = (uintptr_t)frames[i];
        const char *best = NULL;
        for (size_t k = 0; k < symbol_count; k++) {
            const Elf64_Sym *sym = &symbols[k];
            if (ELF64_ST_TYPE(sym->st_info) != STT_FUNC || at < sym->st_value || at >= sym->st_value + sym->st_size) continue;
            best = names + sym->st_name;
            break;
        }
        if (!best) {
            fprintf(stderr, "  at %p\n", frames[i]);
            continue;
        }
        if (strcmp(best, "main") == 0 || strncmp(best, "helix.", 6) == 0 || strncmp(best, "hx_", 3) == 0 ||
            strncmp(best, "__libc", 6) == 0 || strcmp(best, "_start_c") == 0 || strcmp(best, "_start") == 0) continue;
        fprintf(stderr, "  at %s\n", best);
    }
    free(sections);
    free(symbols);
    free(names);
    if (f) fclose(f);
}
#endif

/** The return addresses on the stack, innermost first. */
static int capture(void **frames, int max) {
#ifdef HX_HAVE_BACKTRACE
    return backtrace(frames, max);
#else
    // musl has no backtrace(): follow the frame pointers, which Helix keeps in debug and release-safe builds.
    // On x86-64 and aarch64 a frame starts with the caller's frame pointer, then the return address.
    void **fp = __builtin_frame_address(0);
    int count = 0;
    while (fp && count < max) {
        void *ret = fp[1];
        if (!ret) break;
        frames[count++] = ret;
        void **next = fp[0];
        if (next <= fp) break;   // the stack grows down, so callers' frames are at higher addresses
        fp = next;
    }
    return count;
#endif
}

/** The trace from `frames[first]` on: return addresses, each stepped back into its call; `pc`, if set, goes first as it is. */
static void print_trace(void **frames, int first, int count, void *pc) {
    fputs("stack trace:\n", stderr);
    void *callers[MAX_FRAMES + 1];
    int n = 0;
    if (pc != NULL) callers[n++] = pc;
    // Return addresses point after the call; step back one byte so lines point at the call itself.
    for (int i = first; i < count; i++) callers[n++] = (char *)frames[i] - 1;
    if (n > 0 && symbolize(callers, n)) return;
#if defined(__linux__)
    print_from_symtab(callers, n);
#else
    for (int i = 0; i < n; i++) fprintf(stderr, "  at %p\n", callers[i]);
#endif
}

/**
 * The trace of a fault in `handler`: from the faulting instruction `pc` (not a return address, so not stepped back),
 * then its callers. The handler's frame and the signal trampoline after it are left out.
 */
void hx_stack_trace_fault(void *pc, void *handler) {
    void *frames[MAX_FRAMES];
    int count = capture(frames, MAX_FRAMES);
    int first = count;
    for (int i = 0; i < count; i++) {
        Dl_info info;
        if (dladdr(frames[i], &info) && info.dli_saddr == handler) {
            first = i + 2;   // past the handler and the trampoline that called it
            break;
        }
    }
    // right after the trampoline comes the link register at the fault: for a function that calls others, a stale
    // return address inside the faulting function itself, which isn't a caller
    Dl_info at_pc, next;
    if (first < count && dladdr(pc, &at_pc) && dladdr(frames[first], &next) && at_pc.dli_saddr == next.dli_saddr) first++;
    // the interrupted function, when it made a frame, shows up again as its own caller's return: once is enough
    int kept = first;
    for (int i = first; i < count; i++) {
        if (i > first && frames[i] == frames[i - 1]) continue;
        frames[kept++] = frames[i];
    }
    print_trace(frames, first, kept, pc);
}

void hx_stack_trace(void) {
    void *frames[MAX_FRAMES];
    int count = capture(frames, MAX_FRAMES);
    fputs("stack trace:\n", stderr);
    // Return addresses point after the call; step back one byte so lines point at the call itself.
    void *callers[MAX_FRAMES];
    for (int i = 1; i < count; i++) callers[i - 1] = (char *)frames[i] - 1;
    if (count > 1 && symbolize(callers, count - 1)) return;
#if defined(__linux__)
    print_from_symtab(callers, count - 1);
#elif defined(HX_HAVE_BACKTRACE)
    backtrace_symbols_fd(frames + 1, count - 1, 2);
#else
    for (int i = 1; i < count; i++) fprintf(stderr, "  at %p\n", frames[i]);
#endif
}
#endif

/* ---- guarded memory, for std's DebugAllocator ---- */

/*
 * Each block gets pages of its own, placed so that it ends right before an inaccessible guard page: reading or
 * writing past its end faults. A freed block's pages are made inaccessible too and kept out of reuse (the most
 * recent HX_QUARANTINE of them), so a pointer kept after `free` - or into an ArrayList that has since grown and
 * moved - faults on its next use instead of reading someone else's data. The fault handler says which it was.
 */
#if defined(__APPLE__) || defined(__linux__)
#include <signal.h>
#include <sys/mman.h>
#if defined(__APPLE__)
#include <sys/ucontext.h>
#else
#include <ucontext.h>
#endif

#define HX_QUARANTINE 16384

typedef struct {
    uintptr_t start, end;   // the block's pages, its guard page excluded
    size_t size;
} HxGuarded;

static HxGuarded quarantine[HX_QUARANTINE];
static size_t quarantine_next, quarantine_count;
static size_t guard_page;

/** Where the fault happened: the program counter in the interrupted context. */
static void *fault_pc(void *context) {
    ucontext_t *uc = context;
#if defined(__APPLE__) && defined(__aarch64__)
    return (void *)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);   // arm64e signs it
#elif defined(__APPLE__) && defined(__x86_64__)
    return (void *)uc->uc_mcontext->__ss.__rip;
#elif defined(__linux__) && defined(__x86_64__)
    return (void *)uc->uc_mcontext.gregs[REG_RIP];
#elif defined(__linux__) && defined(__aarch64__)
    return (void *)uc->uc_mcontext.pc;
#else
    (void)uc;
    return NULL;
#endif
}

static void guard_fault(int sig, siginfo_t *info, void *context) {
    uintptr_t at = (uintptr_t)info->si_addr;
    fflush(stdout);
    const HxGuarded *freed = NULL;
    for (size_t i = 0; i < quarantine_count; i++) {
        if (at >= quarantine[i].start && at < quarantine[i].end + guard_page) freed = &quarantine[i];
    }
    if (freed != NULL) {
        dprintf(2, "panic: use after free: this memory (%zu bytes) was freed, or moved when it grew\n", freed->size);
    } else {
        dprintf(2, "panic: invalid memory access at 0x%" PRIxPTR " (%s)\n", at,
                sig == SIGBUS ? "bus error" : "past the end of an allocation, a null or dangling pointer");
    }
    void *pc = fault_pc(context);
    if (pc != NULL) hx_stack_trace_fault(pc, (void *)guard_fault);
    else hx_stack_trace();
    signal(SIGABRT, SIG_DFL);
    abort();
}

static void guard_setup(void) {
    if (guard_page != 0) return;
    guard_page = (size_t)sysconf(_SC_PAGESIZE);
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = guard_fault;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGBUS, &action, NULL);
}

void *hx_guard_alloc(size_t size, size_t align) {
    guard_setup();
    size_t pages = (size + guard_page - 1) / guard_page;
    if (pages == 0) pages = 1;
    char *base = mmap(NULL, (pages + 1) * guard_page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (base == MAP_FAILED) return NULL;
    mprotect(base + pages * guard_page, guard_page, PROT_NONE);
    uintptr_t end = (uintptr_t)(base + pages * guard_page);
    if (align == 0) align = 1;
    return (void *)((end - (size == 0 ? 1 : size)) & ~(uintptr_t)(align - 1));   // as close to the guard page as alignment allows
}

void hx_guard_free(void *memory, size_t size) {
    uintptr_t start = (uintptr_t)memory & ~(uintptr_t)(guard_page - 1);
    uintptr_t end = ((uintptr_t)memory + (size == 0 ? 1 : size) + guard_page - 1) & ~(uintptr_t)(guard_page - 1);
    mprotect((void *)start, end - start, PROT_NONE);
    if (quarantine_count == HX_QUARANTINE) {   // the oldest block leaves quarantine, and its address can be reused
        HxGuarded old = quarantine[quarantine_next];
        munmap((void *)old.start, old.end - old.start + guard_page);
    } else {
        quarantine_count++;
    }
    quarantine[quarantine_next] = (HxGuarded){start, end, size};
    quarantine_next = (quarantine_next + 1) % HX_QUARANTINE;
}
#else
/* Elsewhere (WASI, Windows) there are no page protections to use: plain malloc, and freed memory is just freed. */
void *hx_guard_alloc(size_t size, size_t align) {
    (void)align;
    return malloc(size == 0 ? 1 : size);
}

void hx_guard_free(void *memory, size_t size) {
    (void)size;
    free(memory);
}
#endif
