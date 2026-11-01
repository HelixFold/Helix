/*
 * The operating system under the compiler (os.hx): what differs between macOS, Linux and Windows, behind one set of
 * functions that take plain types. Paths come back with `/` on every system; Windows takes them that way too.
 *
 * Processes are handles (a pid, or a Windows process handle) and their results exit codes: 128 + the signal for one
 * a signal killed, -1 when waiting failed.
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32)
#include <direct.h>
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#else
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <ftw.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#include <sys/sysctl.h>
#endif
extern char **environ;
#endif

int hx_os_errno(void) {
    return errno;
}

FILE *hx_os_stdout(void) {
    return stdout;
}

FILE *hx_os_stderr(void) {
    return stderr;
}

int hx_os_isatty(int fd) {
#if defined(_WIN32)
    return _isatty(fd);
#else
    return isatty(fd);
#endif
}

int hx_os_pid(void) {
#if defined(_WIN32)
    return (int)GetCurrentProcessId();
#else
    return (int)getpid();
#endif
}

#if defined(_WIN32)
/** `\` to `/`, in place. */
static void forward_slashes(char *path) {
    for (char *p = path; *p; p++) {
        if (*p == '\\') *p = '/';
    }
}

/** UTF-8 to a new UTF-16 string, or NULL. */
static wchar_t *wide(const char *text) {
    int n = MultiByteToWideChar(CP_UTF8, 0, text, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = malloc((size_t)n * sizeof(wchar_t));
    if (w) MultiByteToWideChar(CP_UTF8, 0, text, -1, w, n);
    return w;
}

/** UTF-16 to UTF-8 in `buf`; false when it doesn't fit. */
static int narrow(const wchar_t *text, char *buf, size_t cap) {
    int n = WideCharToMultiByte(CP_UTF8, 0, text, -1, buf, (int)cap, NULL, NULL);
    return n > 0;
}
#endif

/** The current folder into `buf`; 0 when it doesn't fit. */
int hx_os_cwd(char *buf, size_t cap) {
#if defined(_WIN32)
    wchar_t w[32768];
    if (!GetCurrentDirectoryW(32768, w) || !narrow(w, buf, cap)) return 0;
    forward_slashes(buf);
    return 1;
#else
    return getcwd(buf, cap) != NULL;
#endif
}

int hx_os_chdir(const char *path) {
#if defined(_WIN32)
    wchar_t *w = wide(path);
    int ok = w && SetCurrentDirectoryW(w);
    free(w);
    return ok;
#else
    return chdir(path) == 0;
#endif
}

/** The absolute path with links resolved into `buf`; 0 when it doesn't exist. */
int hx_os_realpath(const char *path, char *buf, size_t cap) {
#if defined(_WIN32)
    wchar_t *w = wide(path);
    if (!w) return 0;
    HANDLE h = CreateFileW(w, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                           FILE_FLAG_BACKUP_SEMANTICS, NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) return 0;
    wchar_t full[32768];
    DWORD n = GetFinalPathNameByHandleW(h, full, 32768, FILE_NAME_NORMALIZED);
    CloseHandle(h);
    if (n == 0 || n >= 32768) return 0;
    const wchar_t *start = full;
    if (wcsncmp(start, L"\\\\?\\UNC\\", 8) == 0) {   // \\?\UNC\server\share -> //server/share
        start += 6;
        full[6] = L'\\';
    } else if (wcsncmp(start, L"\\\\?\\", 4) == 0) {
        start += 4;
    }
    if (!narrow(start, buf, cap)) return 0;
    forward_slashes(buf);
    return 1;
#else
    char resolved[4096];
    if (!realpath(path, resolved) || strlen(resolved) >= cap) return 0;
    strcpy(buf, resolved);
    return 1;
#endif
}

/** Whether the path exists (`what` 0), can be read (4), or run (1). */
int hx_os_access(const char *path, int what) {
#if defined(_WIN32)
    wchar_t *w = wide(path);
    if (!w) return 0;
    DWORD attributes = GetFileAttributesW(w);
    free(w);
    if (attributes == INVALID_FILE_ATTRIBUTES) return 0;
    return what != 1 || !(attributes & FILE_ATTRIBUTE_DIRECTORY);   // anything that's a file can be run
#else
    return access(path, what) == 0;
#endif
}

/**
 * `stat` (`follow`) or `lstat`: the mode in POSIX's bits (0170000 the kind, 0777 the permissions) and the time of
 * the last change, in seconds. 0 when the path doesn't exist.
 */
int hx_os_stat(const char *path, int follow, uint32_t *mode, int64_t *mtime) {
#if defined(_WIN32)
    wchar_t *w = wide(path);
    if (!w) return 0;
    WIN32_FILE_ATTRIBUTE_DATA data;
    int ok = GetFileAttributesExW(w, GetFileExInfoStandard, &data);
    free(w);
    if (!ok) return 0;
    uint32_t kind = data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY ? 0040000 : 0100000;
    if (!follow && (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) kind = 0120000;
    *mode = kind | (data.dwFileAttributes & FILE_ATTRIBUTE_READONLY ? 0555 : 0777);
    uint64_t ticks = ((uint64_t)data.ftLastWriteTime.dwHighDateTime << 32) | data.ftLastWriteTime.dwLowDateTime;
    *mtime = (int64_t)(ticks / 10000000) - 11644473600LL;   // 100 ns since 1601 -> seconds since 1970
    return 1;
#else
    struct stat st;
    if ((follow ? stat(path, &st) : lstat(path, &st)) != 0) return 0;
    *mode = (uint32_t)st.st_mode;
    *mtime = (int64_t)st.st_mtime;
    return 1;
#endif
}

/** A folder; 1 when it was made, or (with `exist_ok`) is there already. */
int hx_os_mkdir(const char *path, int exist_ok) {
#if defined(_WIN32)
    wchar_t *w = wide(path);
    int ok = w && CreateDirectoryW(w, NULL);
    if (!ok && exist_ok && GetLastError() == ERROR_ALREADY_EXISTS) ok = 1;
    if (!ok) errno = GetLastError() == ERROR_ALREADY_EXISTS ? EEXIST : ENOENT;
    free(w);
    return ok;
#else
    return mkdir(path, 0777) == 0 || (exist_ok && errno == EEXIST);
#endif
}

int hx_os_chmod(const char *path, uint32_t mode) {
#if defined(_WIN32)
    (void)path;
    (void)mode;
    return 1;   // Windows has no permission bits to copy
#else
    return chmod(path, (mode_t)mode) == 0;
#endif
}

/* ---- folders ---- */

typedef struct {
#if defined(_WIN32)
    HANDLE find;
    WIN32_FIND_DATAW data;
    int first;
#else
    DIR *dir;
#endif
} Dir;

/** A folder to list with hx_os_dir_next, or NULL. */
void *hx_os_dir_open(const char *path) {
    Dir *d = calloc(1, sizeof(Dir));
    if (!d) return NULL;
#if defined(_WIN32)
    size_t n = strlen(path);
    char *pattern = malloc(n + 3);
    memcpy(pattern, path, n);
    memcpy(pattern + n, "/*", 3);
    wchar_t *w = wide(pattern);
    free(pattern);
    d->find = w ? FindFirstFileW(w, &d->data) : INVALID_HANDLE_VALUE;
    free(w);
    if (d->find == INVALID_HANDLE_VALUE) {
        free(d);
        return NULL;
    }
    d->first = 1;
#else
    d->dir = opendir(path);
    if (!d->dir) {
        free(d);
        return NULL;
    }
#endif
    return d;
}

/** The next name (`.` and `..` included) into `buf`; 0 at the end. */
int hx_os_dir_next(void *handle, char *buf, size_t cap) {
    Dir *d = handle;
#if defined(_WIN32)
    if (!d->first && !FindNextFileW(d->find, &d->data)) return 0;
    d->first = 0;
    return narrow(d->data.cFileName, buf, cap);
#else
    struct dirent *entry = readdir(d->dir);
    if (!entry || strlen(entry->d_name) >= cap) return 0;
    strcpy(buf, entry->d_name);
    return 1;
#endif
}

void hx_os_dir_close(void *handle) {
    Dir *d = handle;
#if defined(_WIN32)
    FindClose(d->find);
#else
    closedir(d->dir);
#endif
    free(d);
}

/** `rm -rf`: a link is removed itself, never what it points at. */
void hx_os_remove_tree(const char *path) {
    uint32_t mode;
    int64_t mtime;
    if (!hx_os_stat(path, 0, &mode, &mtime)) return;
    if ((mode & 0170000) != 0040000) {
        remove(path);
        return;
    }
    void *d = hx_os_dir_open(path);
    if (d) {
        char name[4096];
        while (hx_os_dir_next(d, name, sizeof name)) {
            if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
            size_t n = strlen(path) + strlen(name) + 2;
            char *child = malloc(n);
            snprintf(child, n, "%s/%s", path, name);
            hx_os_remove_tree(child);
            free(child);
        }
        hx_os_dir_close(d);
    }
#if defined(_WIN32)
    wchar_t *w = wide(path);
    if (w) RemoveDirectoryW(w);
    free(w);
#else
    rmdir(path);
#endif
}

/* ---- processes ---- */

#if defined(_WIN32)
/** An argument as the C runtime's parser reads it back: quoted, with `\` before quotes doubled. */
static void quote_arg(char **out, size_t *len, size_t *cap, const char *arg) {
    size_t need = *len + strlen(arg) * 2 + 4;
    if (need > *cap) {
        *cap = need * 2;
        *out = realloc(*out, *cap);
    }
    char *o = *out + *len;
    if (*len) *o++ = ' ';
    int plain = *arg != 0;
    for (const char *p = arg; *p; p++) {
        if (*p == ' ' || *p == '\t' || *p == '"') plain = 0;
    }
    if (plain) {
        size_t n = strlen(arg);
        memcpy(o, arg, n);
        o += n;
    } else {
        *o++ = '"';
        size_t backslashes = 0;
        for (const char *p = arg;; p++) {
            if (*p == '\\') {
                backslashes++;
                continue;
            }
            if (*p == '"' || *p == 0) backslashes *= 2;   // they now come before a quote
            while (backslashes) {
                *o++ = '\\';
                backslashes--;
            }
            if (*p == 0) break;
            if (*p == '"') *o++ = '\\';
            *o++ = *p;
        }
        *o++ = '"';
    }
    *len = (size_t)(o - *out);
    *o = 0;
}

/** The handles hx_os_spawn started and nobody has waited for: what hx_os_wait_any waits on. */
static HANDLE running[MAXIMUM_WAIT_OBJECTS];
static int running_count;

static void forget(HANDLE h) {
    for (int i = 0; i < running_count; i++) {
        if (running[i] == h) {
            running[i] = running[--running_count];
            return;
        }
    }
}

static int64_t exit_code_of(HANDLE h) {
    DWORD code = 0;
    if (!GetExitCodeProcess(h, &code)) return -1;
    return code >= 0xC0000000u ? 128 + 6 : (int64_t)code;   // an exception (a crash) reads like SIGABRT
}
#endif

/**
 * Starts `argv[0]` (looked up in PATH) with the arguments; `quiet` sends its stderr nowhere, `out` (when not NULL)
 * its stdout to that file. The process's handle, or -1 when it can't start (errno says why).
 */
int64_t hx_os_spawn(const char *const *argv, size_t count, int quiet, const char *out) {
#if defined(_WIN32)
    char *line = NULL;
    size_t len = 0, cap = 0;
    for (size_t i = 0; i < count; i++) quote_arg(&line, &len, &cap, argv[i]);
    wchar_t *wline = wide(line ? line : "");
    free(line);
    SECURITY_ATTRIBUTES inherit = { sizeof inherit, NULL, TRUE };
    STARTUPINFOW si;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    HANDLE null_file = INVALID_HANDLE_VALUE, out_file = INVALID_HANDLE_VALUE;
    if (quiet) {
        null_file = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_WRITE, &inherit, OPEN_EXISTING, 0, NULL);
        si.hStdError = null_file;
    }
    if (out) {
        wchar_t *wout = wide(out);
        out_file = CreateFileW(wout, GENERIC_WRITE, FILE_SHARE_READ, &inherit, CREATE_ALWAYS, 0, NULL);
        free(wout);
        si.hStdOutput = out_file;
    }
    PROCESS_INFORMATION pi;
    BOOL ok = wline && running_count < MAXIMUM_WAIT_OBJECTS &&
              CreateProcessW(NULL, wline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);
    free(wline);
    if (null_file != INVALID_HANDLE_VALUE) CloseHandle(null_file);
    if (out_file != INVALID_HANDLE_VALUE) CloseHandle(out_file);
    if (!ok) {
        errno = ENOENT;
        return -1;
    }
    CloseHandle(pi.hThread);
    running[running_count++] = pi.hProcess;
    return (int64_t)(intptr_t)pi.hProcess;
#else
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    if (quiet) posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    if (out) posix_spawn_file_actions_addopen(&actions, 1, out, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    char **args = calloc(count + 1, sizeof(char *));
    for (size_t i = 0; i < count; i++) args[i] = (char *)argv[i];
    pid_t child = 0;
    int err = posix_spawnp(&child, args[0], &actions, NULL, args, environ);
    free(args);
    posix_spawn_file_actions_destroy(&actions);
    if (err != 0) {
        errno = err;
        return -1;
    }
    return child;
#endif
}

#if !defined(_WIN32)
static int64_t exit_code_of(int status) {
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}
#endif

/** Waits for a process hx_os_spawn started: its exit code. */
int64_t hx_os_wait(int64_t child) {
#if defined(_WIN32)
    HANDLE h = (HANDLE)(intptr_t)child;
    if (WaitForSingleObject(h, INFINITE) != WAIT_OBJECT_0) return -1;
    int64_t code = exit_code_of(h);
    forget(h);
    CloseHandle(h);
    return code;
#else
    int status = 0;
    while (waitpid((pid_t)child, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return exit_code_of(status);
#endif
}

/** Waits for whichever started process ends first: its handle, and its exit code in `code`. -1 when none is left. */
int64_t hx_os_wait_any(int64_t *code) {
#if defined(_WIN32)
    if (running_count == 0) return -1;
    DWORD which = WaitForMultipleObjects((DWORD)running_count, running, FALSE, INFINITE);
    if (which >= WAIT_OBJECT_0 + (DWORD)running_count) return -1;
    HANDLE h = running[which - WAIT_OBJECT_0];
    *code = exit_code_of(h);
    forget(h);
    CloseHandle(h);
    return (int64_t)(intptr_t)h;
#else
    int status = 0;
    for (;;) {
        pid_t child = wait(&status);
        if (child >= 0) {
            *code = exit_code_of(status);
            return child;
        }
        if (errno != EINTR) return -1;
    }
#endif
}

/* ---- the machine ---- */

int64_t hx_os_cpu_count(void) {
#if defined(_WIN32)
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    return info.dwNumberOfProcessors;
#else
    return sysconf(_SC_NPROCESSORS_ONLN);
#endif
}

double hx_os_seconds(void) {
#if defined(_WIN32)
    LARGE_INTEGER frequency, now;
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&now);
    return (double)now.QuadPart / (double)frequency.QuadPart;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
#endif
}

#if defined(_WIN32)
/** fnmatch without flags: `*`, `?` and `[...]` (with `!` or `^` to negate, and ranges). */
static int glob_match(const char *p, const char *s) {
    for (; *p; p++, s++) {
        if (*p == '*') {
            while (p[1] == '*') p++;
            for (const char *t = s;; t++) {
                if (glob_match(p + 1, t)) return 1;
                if (!*t) return 0;
            }
        }
        if (!*s) return 0;
        if (*p == '?') continue;
        if (*p == '[') {
            const char *q = p + 1;
            int negate = *q == '!' || *q == '^';
            if (negate) q++;
            int found = 0;
            for (int first = 1; *q && (first || *q != ']'); q++, first = 0) {
                if (q[1] == '-' && q[2] && q[2] != ']') {
                    if (*s >= *q && *s <= q[2]) found = 1;
                    q += 2;
                } else if (*s == *q) {
                    found = 1;
                }
            }
            if (*q != ']' || found == negate) return 0;
            p = q;
            continue;
        }
        if (*p != *s) return 0;
    }
    return *s == 0;
}
#endif

/** Whether `name` matches the shell pattern. */
int hx_os_matches(const char *pattern, const char *name) {
#if defined(_WIN32)
    return glob_match(pattern, name);
#else
    return fnmatch(pattern, name, 0) == 0;
#endif
}

/** The compiler's own executable into `buf` (not resolved); 0 when it doesn't fit. */
int hx_os_exe_path(char *buf, size_t cap) {
#if defined(_WIN32)
    wchar_t w[32768];
    DWORD n = GetModuleFileNameW(NULL, w, 32768);
    if (n == 0 || n >= 32768 || !narrow(w, buf, cap)) return 0;
    forward_slashes(buf);
    return 1;
#elif defined(__APPLE__)
    uint32_t len = (uint32_t)cap;
    return _NSGetExecutablePath(buf, &len) == 0;
#else
    ssize_t n = readlink("/proc/self/exe", buf, cap - 1);
    if (n <= 0) return 0;
    buf[n] = 0;
    return 1;
#endif
}

/** The version of macOS this runs on ("27.0") into `buf`; 0 elsewhere. */
int hx_os_macos_version(char *buf, size_t cap) {
#if defined(__APPLE__)
    size_t len = cap;
    return sysctlbyname("kern.osproductversion", buf, &len, NULL, 0) == 0;
#else
    (void)buf;
    (void)cap;
    return 0;
#endif
}

/** The file of the library (or program) holding the function `symbol`, into `buf`; 0 when it can't be found. */
int hx_os_image_of(const void *symbol, char *buf, size_t cap) {
#if defined(_WIN32)
    HMODULE module;
    wchar_t w[32768];
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCWSTR)symbol, &module))
        return 0;
    DWORD n = GetModuleFileNameW(module, w, 32768);
    if (n == 0 || n >= 32768 || !narrow(w, buf, cap)) return 0;
    forward_slashes(buf);
    return 1;
#else
    Dl_info info;
    if (!dladdr(symbol, &info) || !info.dli_fname || strlen(info.dli_fname) >= cap) return 0;
    strcpy(buf, info.dli_fname);
    return 1;
#endif
}

/** C's stdin, for fread. */
FILE *hx_os_stdin(void) {
    return stdin;
}

/* ---- text in memory ---- */

#if defined(_WIN32)
/** What hx_os_memstream_close fills in for a stream: Windows has no open_memstream, so it's a temporary file. */
static struct {
    FILE *file;
    char **buf;
    size_t *size;
} memstreams[16];
#endif

/** A stream whose text ends up in `*buf` (malloc'd, NUL-terminated) and `*size` when hx_os_memstream_close closes it. */
FILE *hx_os_memstream(char **buf, size_t *size) {
#if defined(_WIN32)
    FILE *f = tmpfile();
    if (!f) return NULL;
    for (int i = 0; i < 16; i++) {
        if (!memstreams[i].file) {
            memstreams[i].file = f;
            memstreams[i].buf = buf;
            memstreams[i].size = size;
            return f;
        }
    }
    fclose(f);
    return NULL;
#else
    return open_memstream(buf, size);
#endif
}

void hx_os_memstream_close(FILE *f) {
#if defined(_WIN32)
    for (int i = 0; i < 16; i++) {
        if (memstreams[i].file != f) continue;
        fflush(f);
        long n = ftell(f);
        char *text = malloc(n > 0 ? (size_t)n + 1 : 1);
        rewind(f);
        size_t got = text && n > 0 ? fread(text, 1, (size_t)n, f) : 0;
        if (text) text[got] = 0;
        *memstreams[i].buf = text;
        *memstreams[i].size = got;
        memstreams[i].file = NULL;
        break;
    }
#endif
    fclose(f);
}
