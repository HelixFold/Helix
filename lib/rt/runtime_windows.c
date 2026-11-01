/*
 * The Helix runtime for Windows. Programs import from msvcrt.dll and kernel32.dll, which every Windows has, so they
 * need no C library of their own. This file declares exactly what it uses from them instead of including Windows'
 * headers, so building for Windows needs nothing but LLVM. It provides the same functions as runtime.c, plus what
 * the C startup files would: the entry point, and the C functions generated code calls that msvcrt lacks
 * (`dprintf`, a C99 `snprintf`).
 *
 * With HX_WITH_C_RUNTIME, for a program linked with mingw-w64's C runtime (the compiler itself, whose LLVM is C++),
 * the entry point and what that runtime has are left to it.
 */

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ---- what msvcrt.dll and kernel32.dll provide ---- */

#if defined(HX_WITH_C_RUNTIME)   /* the C runtime's import libraries say where each function is */
#define IMPORT
#define _vsnprintf vsnprintf     /* the UCRT has C99's, and no _vsnprintf to import */
#else
#define IMPORT __declspec(dllimport)
#endif

typedef void *HANDLE;
typedef uint32_t DWORD;

IMPORT HANDLE __stdcall GetStdHandle(DWORD which);
IMPORT int __stdcall WriteFile(HANDLE file, const void *bytes, DWORD len, DWORD *written, void *overlapped);
IMPORT uint16_t __stdcall RtlCaptureStackBackTrace(DWORD skip, DWORD count, void **frames, DWORD *hash);
IMPORT void *__stdcall GetModuleHandleA(const char *name);
IMPORT int __stdcall CopyFileA(const char *from, const char *to, int fail_if_exists);
IMPORT DWORD __stdcall GetLastError(void);

typedef struct { DWORD low, high; } FileTime;

typedef struct {
    DWORD attributes;
    FileTime created, accessed, written;
    DWORD size_high, size_low;
} FileAttributeData;

typedef struct {
    DWORD attributes;
    FileTime created, accessed, written;
    DWORD serial, size_high, size_low, links, index_high, index_low;
} FileInformation;

typedef struct {
    DWORD attributes;
    FileTime created, accessed, written;
    DWORD size_high, size_low, reserved0, reserved1;
    char name[260];
    char short_name[14];
} FindData;

typedef struct {
    DWORD length;
    void *descriptor;
    int inherit;
} SecurityAttributes;

typedef struct {
    DWORD cb;
    char *reserved, *desktop, *title;
    DWORD x, y, x_size, y_size, x_chars, y_chars, fill, flags;
    uint16_t show_window, reserved2_size;
    uint8_t *reserved2;
    HANDLE input, output, error;
} StartupInfoA;

typedef struct {
    HANDLE process, thread;
    DWORD process_id, thread_id;
} ProcessInformation;

IMPORT int __stdcall GetFileAttributesExA(const char *name, int level, FileAttributeData *out);
IMPORT DWORD __stdcall GetFileAttributesA(const char *name);
IMPORT HANDLE __stdcall CreateFileA(const char *name, DWORD access, DWORD share, SecurityAttributes *security,
                                    DWORD disposition, DWORD flags, HANDLE templ);
IMPORT int __stdcall GetFileInformationByHandle(HANDLE file, FileInformation *out);
IMPORT int __stdcall CloseHandle(HANDLE handle);
IMPORT HANDLE __stdcall FindFirstFileA(const char *pattern, FindData *out);
IMPORT int __stdcall FindNextFileA(HANDLE find, FindData *out);
IMPORT int __stdcall FindClose(HANDLE find);
IMPORT int __stdcall MoveFileExA(const char *from, const char *to, DWORD flags);
IMPORT int __stdcall DeleteFileA(const char *name);
IMPORT int __stdcall RemoveDirectoryA(const char *name);
IMPORT uint8_t __stdcall CreateSymbolicLinkA(const char *link, const char *target, DWORD flags);
IMPORT int __stdcall DeviceIoControl(HANDLE device, DWORD code, void *in, DWORD in_size, void *out, DWORD out_size,
                                     DWORD *returned, void *overlapped);
IMPORT int __stdcall WideCharToMultiByte(unsigned page, DWORD flags, const uint16_t *wide, int wide_len, char *out,
                                         int out_len, const char *fallback, int *used_fallback);
IMPORT int __stdcall CreatePipe(HANDLE *read, HANDLE *write, SecurityAttributes *security, DWORD size);
IMPORT int __stdcall SetHandleInformation(HANDLE handle, DWORD mask, DWORD flags);
IMPORT int __stdcall ReadFile(HANDLE file, void *buf, DWORD len, DWORD *read, void *overlapped);
IMPORT int __stdcall CreateProcessA(const char *app, char *command_line, SecurityAttributes *process,
                                    SecurityAttributes *thread, int inherit, DWORD flags, void *environment,
                                    const char *dir, StartupInfoA *startup, ProcessInformation *info);
IMPORT DWORD __stdcall WaitForSingleObject(HANDLE handle, DWORD ms);
IMPORT int __stdcall GetExitCodeProcess(HANDLE process, DWORD *code);
IMPORT DWORD __stdcall GetTempPathA(DWORD size, char *buf);
IMPORT int __stdcall PeekNamedPipe(HANDLE pipe, void *buf, DWORD size, DWORD *read, DWORD *available, DWORD *left);
IMPORT uint64_t __stdcall GetTickCount64(void);
IMPORT int __stdcall TerminateProcess(HANDLE process, unsigned code);
IMPORT void __stdcall Sleep(DWORD ms);
IMPORT unsigned __stdcall GetTempFileNameA(const char *dir, const char *prefix, unsigned unique, char *name);

#define INVALID_HANDLE ((HANDLE)(intptr_t)-1)
#define INVALID_ATTRIBUTES ((DWORD)-1)
#define ATTRIBUTE_READONLY 0x1u
#define ATTRIBUTE_DIRECTORY 0x10u
#define ATTRIBUTE_REPARSE_POINT 0x400u

#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define STD_ERROR_HANDLE ((DWORD)-12)

typedef struct { int newmode; } StartupInfo;
IMPORT int __getmainargs(int *argc, char ***argv, char ***env, int glob, StartupInfo *info);
IMPORT void exit(int code);
IMPORT void abort(void);
IMPORT int _vsnprintf(char *buf, size_t size, const char *fmt, va_list args);
IMPORT double strtod(const char *text, char **end);
IMPORT char *strchr(const char *text, int c);
IMPORT size_t strlen(const char *text);
IMPORT void *memmove(void *to, const void *from, size_t n);
IMPORT void *memcpy(void *to, const void *from, size_t n);
IMPORT int atoi(const char *text);
IMPORT char *getenv(const char *name);
IMPORT int *_errno(void);
IMPORT int _open(const char *path, int flags, ...);
IMPORT int _read(int fd, void *buf, unsigned len);
IMPORT int _write(int fd, const void *buf, unsigned len);
IMPORT int _close(int fd);
IMPORT int64_t _filelengthi64(int fd);
IMPORT int _unlink(const char *path);
IMPORT int _mkdir(const char *path);
IMPORT intptr_t _spawnvp(int mode, const char *file, const char *const *argv);
IMPORT void *malloc(size_t size);
IMPORT void *realloc(void *p, size_t size);
IMPORT void free(void *p);
IMPORT int memcmp(const void *a, const void *b, size_t n);

/* ---- what the C startup files and a C99 library would provide ---- */

#if !defined(HX_WITH_C_RUNTIME)
int main(int argc, char **argv);

/** The entry point: what crt2.o is for MinGW programs. */
void mainCRTStartup(void) {
    int argc;
    char **argv, **env;
    StartupInfo info = { 0 };
    __getmainargs(&argc, &argv, &env, 0, &info);
    exit(main(argc, argv));
}

/** MinGW's code generation calls `__main` at the top of `main` to run constructors; Helix has none. */
void __main(void) {}

/** C99 `snprintf`, which always NUL-terminates and returns the full length (msvcrt's `_snprintf` doesn't). */
int snprintf(char *buf, size_t size, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int n = _vsnprintf(buf, size, fmt, args);
    va_end(args);
    if (size > 0 && (n < 0 || (size_t)n >= size)) {
        buf[size - 1] = '\0';
        if (n < 0) {   // too small: measure with a bigger buffer
            char big[1024];
            va_start(args, fmt);
            n = _vsnprintf(big, sizeof big, fmt, args);
            va_end(args);
            if (n < 0) n = (int)sizeof big;
        }
    }
    return n;
}
#else
int snprintf(char *buf, size_t size, const char *fmt, ...);   /* the C runtime's, a C99 one */
#endif

static void write_handle(DWORD which, const char *bytes, size_t len) {
    HANDLE h = GetStdHandle(which);
    while (len > 0) {
        DWORD written = 0;
        if (!WriteFile(h, bytes, (DWORD)len, &written, NULL) || written == 0) return;
        bytes += written;
        len -= written;
    }
}

/** `dprintf(2, ...)`: the panic handler's output. */
int dprintf(int fd, const char *fmt, ...) {
    char buf[4096];
    va_list args;
    va_start(args, fmt);
    int n = _vsnprintf(buf, sizeof buf, fmt, args);
    va_end(args);
    if (n < 0 || n >= (int)sizeof buf) n = (int)sizeof buf - 1;
    write_handle(fd == 1 ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE, buf, (size_t)n);
    return n;
}

#if !defined(HX_WITH_C_RUNTIME)
/** Output isn't buffered here, so there's nothing to flush; generated code calls it before a panic. */
int fflush(void *stream) {
    (void)stream;
    return 0;
}
#endif

static float strtof_(const char *text, char **end) {
    return (float)strtod(text, end);
}
#define strtof strtof_

/* ---- output and formatting ---- */

void hx_write(int32_t fd, const char *bytes, size_t len) {
    if (len == 0) return;
    if (fd <= 2) {
        write_handle(fd == 2 ? STD_ERROR_HANDLE : STD_OUTPUT_HANDLE, bytes, len);
        return;
    }
    _write(fd, bytes, (unsigned)len);
}

#define HX_I64 "I64d"
#define HX_U64 "I64u"
#define HX_X64 "I64x"
#include "format.inc"

/* ---- files ---- */

enum { FS_NOT_FOUND = 1, FS_ACCESS_DENIED, FS_IS_DIRECTORY, FS_ALREADY_EXISTS, FS_NO_SPACE, FS_NAME_TOO_LONG, FS_UNEXPECTED };

/** The same codes, for a kernel32 call that failed: from GetLastError. */
static int64_t fs_win_error(void) {
    switch (GetLastError()) {
    case 2: case 3: case 267: return -FS_NOT_FOUND;     // file, path not found; not a folder
    case 5: case 32: return -FS_ACCESS_DENIED;          // access denied; in use by another process
    case 80: case 183: return -FS_ALREADY_EXISTS;
    case 112: return -FS_NO_SPACE;
    case 206: return -FS_NAME_TOO_LONG;
    default: return -FS_UNEXPECTED;
    }
}

static int64_t fs_error(void) {
    switch (*_errno()) {
    case 2: return -FS_NOT_FOUND;        // ENOENT
    case 13: return -FS_ACCESS_DENIED;   // EACCES
    case 21: return -FS_IS_DIRECTORY;    // EISDIR
    case 17: return -FS_ALREADY_EXISTS;  // EEXIST
    case 28: return -FS_NO_SPACE;        // ENOSPC
    case 38: return -FS_NAME_TOO_LONG;   // ENAMETOOLONG
    default: return -FS_UNEXPECTED;
    }
}

/** A Helix string as a C string, in `out` (MAX_PATH-sized paths are plenty here). */
static bool fs_path(char *out, const char *path, size_t len) {
    if (len >= 4096) return false;
    memcpy(out, path, len);
    out[len] = '\0';
    return true;
}

int64_t hx_fs_open(const char *path, size_t len, int32_t mode) {
    // the same modes as runtime.c: read, create (truncate), append, create only if new
    static const int flags[] = { 0x8000, 0x8000 | 0x1 | 0x100 | 0x200, 0x8000 | 0x1 | 0x100 | 0x8, 0x8000 | 0x1 | 0x100 | 0x400 };
    char name[4096];
    if (!fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    if (mode < 0 || mode > 3) return -FS_UNEXPECTED;
    int fd = _open(name, flags[mode], 0x180);   // _S_IREAD | _S_IWRITE
    return fd < 0 ? fs_error() : fd;
}

int64_t hx_fs_read(int32_t fd, char *buf, size_t len) {
    int n = _read(fd, buf, (unsigned)(len > 0x7fffffff ? 0x7fffffff : len));
    return n < 0 ? fs_error() : n;
}

int64_t hx_fs_write(int32_t fd, const char *bytes, size_t len) {
    while (len > 0) {
        int n = _write(fd, bytes, (unsigned)(len > 0x7fffffff ? 0x7fffffff : len));
        if (n <= 0) return fs_error();
        bytes += n;
        len -= (size_t)n;
    }
    return 0;
}

void hx_fs_close(int32_t fd) {
    _close(fd);
}

int64_t hx_fs_size(int32_t fd) {
    int64_t size = _filelengthi64(fd);
    return size < 0 ? fs_error() : size;
}

int64_t hx_fs_make_path(const char *path, size_t len) {
    char name[4096];
    if (!fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    for (char *p = name + 1;; p++) {
        if (*p != '/' && *p != '\\' && *p != '\0') continue;
        char saved = *p;
        *p = '\0';
        if (_mkdir(name) != 0 && *_errno() != 17) return fs_error();
        *p = saved;
        if (!saved) return 0;
    }
}

int64_t hx_fs_copy(const char *from, size_t from_len, const char *to, size_t to_len) {
    char src[4096], dst[4096];
    if (!fs_path(src, from, from_len) || !fs_path(dst, to, to_len)) return -FS_NAME_TOO_LONG;
    if (CopyFileA(src, dst, 0)) return 0;
    return GetLastError() == 2 || GetLastError() == 3 ? -FS_NOT_FOUND : -FS_UNEXPECTED;
}

int64_t hx_fs_delete(const char *path, size_t len) {
    char name[4096];
    if (!fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    return _unlink(name) == 0 ? 0 : fs_error();
}

/** What `hx_fs_stat` reports (HxStat in runtime.c). `kind`: 0 file, 1 folder, 2 symbolic link, 3 something else. */
typedef struct {
    int64_t size;
    int64_t mtime;      // seconds since 1970
    int32_t kind;
    uint32_t mode;      // the permission bits, as POSIX would show them
} HxStat;

/** A FILETIME (100 ns since 1601) in seconds since 1970. */
static int64_t unix_seconds(FileTime t) {
    return (int64_t)((((uint64_t)t.high << 32) | t.low) / 10000000u) - 11644473600;
}

static void fill_stat(HxStat *out, DWORD attributes, FileTime written, DWORD size_high, DWORD size_low, bool link) {
    bool folder = (attributes & ATTRIBUTE_DIRECTORY) != 0;
    out->size = folder ? 0 : (int64_t)(((uint64_t)size_high << 32) | size_low);
    out->mtime = unix_seconds(written);
    out->kind = link ? 2 : folder ? 1 : 0;
    out->mode = folder ? 0755 : (attributes & ATTRIBUTE_READONLY) ? 0444 : 0644;
}

/** `stat`, or with `follow` 0 `lstat` (a symbolic link or junction is reported as itself). */
int64_t hx_fs_stat(const char *path, size_t len, int32_t follow, HxStat *out) {
    char name[4096];
    if (!fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    FileAttributeData data;
    if (!GetFileAttributesExA(name, 0 /* GetFileExInfoStandard */, &data)) return fs_win_error();
    bool link = (data.attributes & ATTRIBUTE_REPARSE_POINT) != 0;
    if (!link || !follow) {
        fill_stat(out, data.attributes, data.written, data.size_high, data.size_low, link);
        return 0;
    }
    // what the link points at: opening it follows the link
    HANDLE h = CreateFileA(name, 0, 0x7 /* share all */, NULL, 3 /* OPEN_EXISTING */, 0x02000000 /* backup semantics, for folders */, NULL);
    if (h == INVALID_HANDLE) return fs_win_error();
    FileInformation info;
    int ok = GetFileInformationByHandle(h, &info);
    CloseHandle(h);
    if (!ok) return fs_win_error();
    fill_stat(out, info.attributes, info.written, info.size_high, info.size_low, false);
    return 0;
}

typedef struct {
    HANDLE find;
    bool pending;       // `data` holds a name not yet returned
    FindData data;
} HxDir;

/** Opens a folder for listing: a handle for `hx_fs_dir_next`, or an error. */
int64_t hx_fs_dir_open(const char *path, size_t len) {
    char pattern[4096];
    if (len + 3 > sizeof pattern || !fs_path(pattern, path, len)) return -FS_NAME_TOO_LONG;
    const char *all = len > 0 && (path[len - 1] == '/' || path[len - 1] == '\\') ? "*" : "\\*";
    memcpy(pattern + len, all, strlen(all) + 1);
    HxDir *d = malloc(sizeof *d);
    if (!d) return -FS_UNEXPECTED;
    d->find = FindFirstFileA(pattern, &d->data);
    if (d->find == INVALID_HANDLE) {
        int64_t error = fs_win_error();
        free(d);
        return error;
    }
    d->pending = true;
    return (int64_t)(intptr_t)d;
}

/** The next name in the folder (without `.` and `..`) copied into `out`: its length, 0 at the end. */
int64_t hx_fs_dir_next(int64_t handle, char *out, size_t cap) {
    HxDir *d = (HxDir *)(intptr_t)handle;
    for (;;) {
        if (!d->pending) {
            if (!FindNextFileA(d->find, &d->data)) return GetLastError() == 18 /* no more files */ ? 0 : fs_win_error();
        }
        d->pending = false;
        const char *n = d->data.name;
        if (n[0] == '.' && (n[1] == 0 || (n[1] == '.' && n[2] == 0))) continue;
        size_t len = strlen(n);
        if (len > cap) return -FS_NAME_TOO_LONG;
        memcpy(out, n, len);
        return (int64_t)len;
    }
}

void hx_fs_dir_close(int64_t handle) {
    HxDir *d = (HxDir *)(intptr_t)handle;
    FindClose(d->find);
    free(d);
}

/** Renames (or moves, on the same volume) a file or folder, replacing a file at `to`. */
int64_t hx_fs_rename(const char *from, size_t from_len, const char *to, size_t to_len) {
    char src[4096], dst[4096];
    if (!fs_path(src, from, from_len) || !fs_path(dst, to, to_len)) return -FS_NAME_TOO_LONG;
    return MoveFileExA(src, dst, 0x1 /* MOVEFILE_REPLACE_EXISTING */) ? 0 : fs_win_error();
}

static int64_t delete_tree(char *path, size_t len) {
    DWORD attributes = GetFileAttributesA(path);
    if (attributes == INVALID_ATTRIBUTES) {
        DWORD error = GetLastError();
        return error == 2 || error == 3 ? 0 : fs_win_error();
    }
    if (attributes & ATTRIBUTE_REPARSE_POINT) {   // a link goes, never what it points at
        bool gone = (attributes & ATTRIBUTE_DIRECTORY) ? RemoveDirectoryA(path) : DeleteFileA(path);
        return gone ? 0 : fs_win_error();
    }
    if (!(attributes & ATTRIBUTE_DIRECTORY)) return DeleteFileA(path) ? 0 : fs_win_error();
    if (len + 3 > 4096) return -FS_NAME_TOO_LONG;
    memcpy(path + len, "\\*", 3);
    FindData data;
    HANDLE find = FindFirstFileA(path, &data);
    path[len] = '\0';
    if (find == INVALID_HANDLE) return fs_win_error();
    int64_t result = 0;
    do {
        const char *n = data.name;
        if (n[0] == '.' && (n[1] == 0 || (n[1] == '.' && n[2] == 0))) continue;
        size_t nlen = strlen(n);
        if (len + 1 + nlen >= 4096) {
            result = -FS_NAME_TOO_LONG;
            break;
        }
        path[len] = '\\';
        memcpy(path + len + 1, n, nlen + 1);
        result = delete_tree(path, len + 1 + nlen);
        path[len] = '\0';
    } while (result == 0 && FindNextFileA(find, &data));
    FindClose(find);
    if (result == 0 && !RemoveDirectoryA(path)) result = fs_win_error();
    return result;
}

/** `rm -rf`: the file or folder and everything in it. A symbolic link is removed itself. Missing is fine. */
int64_t hx_fs_delete_tree(const char *path, size_t len) {
    char name[4096];
    if (!fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    return delete_tree(name, len);
}

/**
 * A symbolic link at `path` holding `target`. Windows marks a link to a folder as one, so a relative target is
 * looked at from the link's own folder. Without Developer Mode or admin rights Windows refuses: AccessDenied.
 */
int64_t hx_fs_symlink(const char *target, size_t target_len, const char *path, size_t len) {
    char t[4096], name[4096], seen[8192];
    if (!fs_path(t, target, target_len) || !fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    bool absolute = t[0] == '/' || t[0] == '\\' || (t[0] && t[1] == ':');
    size_t dir = len;
    while (dir > 0 && name[dir - 1] != '/' && name[dir - 1] != '\\') dir--;
    if (absolute || dir == 0) {
        memcpy(seen, t, target_len + 1);
    } else {
        memcpy(seen, name, dir);
        memcpy(seen + dir, t, target_len + 1);
    }
    DWORD attributes = GetFileAttributesA(seen);
    DWORD folder = attributes != INVALID_ATTRIBUTES && (attributes & ATTRIBUTE_DIRECTORY) ? 0x1 : 0;
    return CreateSymbolicLinkA(name, t, folder | 0x2 /* allow without admin, in Developer Mode */) ? 0 : fs_win_error();
}

/** What the symbolic link (or junction) holds, copied into `out`: its length. */
int64_t hx_fs_read_link(const char *path, size_t len, char *out, size_t cap) {
    char name[4096];
    if (!fs_path(name, path, len)) return -FS_NAME_TOO_LONG;
    HANDLE h = CreateFileA(name, 0, 0x7, NULL, 3 /* OPEN_EXISTING */, 0x02000000 | 0x00200000 /* the link itself */, NULL);
    if (h == INVALID_HANDLE) return fs_win_error();
    static uint8_t buf[16384];   // MAXIMUM_REPARSE_DATA_BUFFER_SIZE
    DWORD got = 0;
    int ok = DeviceIoControl(h, 0x000900A8 /* FSCTL_GET_REPARSE_POINT */, NULL, 0, buf, sizeof buf, &got, NULL);
    CloseHandle(h);
    if (!ok) return GetLastError() == 4390 /* not a reparse point */ ? -FS_UNEXPECTED : fs_win_error();
    uint32_t tag;
    memcpy(&tag, buf, 4);
    size_t names;   // where the offsets are: a symbolic link has a flags field after them, a junction doesn't
    if (tag == 0xA000000Cu) names = 8 + 8 + 4;
    else if (tag == 0xA0000003u) names = 8 + 8;
    else return -FS_UNEXPECTED;
    uint16_t sub_offset, sub_len, print_offset, print_len;
    memcpy(&sub_offset, buf + 8, 2);
    memcpy(&sub_len, buf + 10, 2);
    memcpy(&print_offset, buf + 12, 2);
    memcpy(&print_len, buf + 14, 2);
    bool print = print_len > 0;
    const uint16_t *wide = (const uint16_t *)(buf + names + (print ? print_offset : sub_offset));
    int wide_len = (print ? print_len : sub_len) / 2;
    int n = WideCharToMultiByte(65001 /* UTF-8 */, 0, wide, wide_len, out, (int)(cap > 0x7fffffff ? 0x7fffffff : cap), NULL, NULL);
    if (n <= 0 && wide_len > 0) return GetLastError() == 122 /* too small */ ? -FS_NAME_TOO_LONG : -FS_UNEXPECTED;
    return n;
}

const char *hx_getenv(const char *name, size_t len) {
    char key[4096];
    if (!fs_path(key, name, len)) return NULL;
    return getenv(key);
}

/* ---- processes ---- */

typedef struct {
    const char *ptr;
    size_t len;
} HxString;

/** An argument quoted the way Windows programs split their command line (CommandLineToArgvW's rules). */
static char *quote(const char *text, size_t len) {
    char *out = malloc(len * 2 + 3);
    size_t n = 0;
    bool plain = len > 0;
    for (size_t i = 0; i < len && plain; i++) plain = text[i] != ' ' && text[i] != '\t' && text[i] != '"';
    if (plain) {
        memcpy(out, text, len);
        out[len] = '\0';
        return out;
    }
    out[n++] = '"';
    size_t backslashes = 0;
    for (size_t i = 0; i < len; i++) {
        if (text[i] == '\\') {
            backslashes++;
        } else {
            if (text[i] == '"') {   // backslashes before a quote are doubled, and the quote escaped
                for (size_t b = 0; b <= backslashes; b++) out[n++] = '\\';
            }
            backslashes = 0;
        }
        out[n++] = text[i];
    }
    for (size_t b = 0; b < backslashes; b++) out[n++] = '\\';   // and before the closing quote
    out[n++] = '"';
    out[n] = '\0';
    return out;
}

int64_t hx_process_run(const HxString *argv, size_t count) {
    if (count == 0) return -1;
    char **args = malloc((count + 1) * sizeof(char *));
    for (size_t i = 0; i < count; i++) args[i] = quote(argv[i].ptr, argv[i].len);
    args[count] = NULL;
    intptr_t status = _spawnvp(0 /* _P_WAIT */, args[0], (const char *const *)args);
    for (size_t i = 0; i < count; i++) free(args[i]);
    free(args);
    return status < 0 ? -1 : (int64_t)(status & 0xff);
}

/**
 * Runs a program with its stdout captured through a pipe into `*out` (malloc'ed, `*out_len` bytes), and its stderr
 * going to `error`. CreateProcessA looks the program up in PATH as `_spawnvp` does. It starts in `dir` unless that is
 * NULL, and is ended once `timeout_ms` (when above 0) has passed, which makes its status 128 + 9 as on Unix.
 */
static int64_t capture_with(const HxString *argv, size_t count, const char *dir, int64_t timeout_ms, char **out,
                            size_t *out_len, HANDLE error) {
    *out = NULL;
    *out_len = 0;
    if (count == 0) return -1;
    size_t size = 1;
    char **args = malloc(count * sizeof(char *));
    for (size_t i = 0; i < count; i++) {
        args[i] = quote(argv[i].ptr, argv[i].len);
        size += strlen(args[i]) + 1;
    }
    char *command = malloc(size);
    size_t n = 0;
    for (size_t i = 0; i < count; i++) {
        size_t len = strlen(args[i]);
        memcpy(command + n, args[i], len);
        n += len;
        command[n++] = i + 1 < count ? ' ' : '\0';
        free(args[i]);
    }
    free(args);

    SecurityAttributes inherit = { sizeof inherit, NULL, 1 };
    HANDLE read_end, write_end;
    if (!CreatePipe(&read_end, &write_end, &inherit, 0)) {
        free(command);
        return -1;
    }
    SetHandleInformation(read_end, 0x1 /* HANDLE_FLAG_INHERIT */, 0);   // only the write end goes to the child
    StartupInfoA startup = { 0 };
    startup.cb = sizeof startup;
    startup.flags = 0x100;   // STARTF_USESTDHANDLES
    startup.input = GetStdHandle((DWORD)-10);
    startup.output = write_end;
    startup.error = error;
    ProcessInformation process = { 0 };
    int started = CreateProcessA(NULL, command, NULL, NULL, 1, 0, NULL, dir, &startup, &process);
    CloseHandle(write_end);
    if (!started) {
        dprintf(2, "error: cannot run '%.*s': Windows error %lu\n", (int)argv[0].len, argv[0].ptr, (unsigned long)GetLastError());
        CloseHandle(read_end);
        free(command);
        return -1;
    }
    free(command);
    CloseHandle(process.thread);
    size_t cap = 4096, len = 0;
    char *buf = malloc(cap);
    uint64_t deadline = timeout_ms > 0 ? GetTickCount64() + (uint64_t)timeout_ms : 0;
    for (;;) {
        if (len == cap) buf = realloc(buf, cap *= 2);
        if (deadline > 0) {   // read only what's there, so the deadline can pass between reads
            DWORD available = 0;
            if (!PeekNamedPipe(read_end, NULL, 0, NULL, &available, NULL)) break;   // the program closed it
            if (available == 0) {
                if (GetTickCount64() >= deadline) {
                    TerminateProcess(process.process, 128 + 9);
                    deadline = 0;
                } else {
                    Sleep(10);
                }
                continue;
            }
        }
        DWORD got = 0;
        if (!ReadFile(read_end, buf + len, (DWORD)(cap - len), &got, NULL) || got == 0) break;
        len += got;
    }
    CloseHandle(read_end);
    WaitForSingleObject(process.process, 0xffffffffu);
    DWORD code = 0;
    GetExitCodeProcess(process.process, &code);
    CloseHandle(process.process);
    *out = buf;
    *out_len = len;
    return (int64_t)(code & 0xff);
}

/**
 * Like `hx_process_run`, with the program's stdout captured through a pipe: `*out` gets malloc'ed bytes
 * (`*out_len` of them), which the caller frees. stderr and stdin are inherited.
 */
int64_t hx_process_capture(const HxString *argv, size_t count, char **out, size_t *out_len) {
    return capture_with(argv, count, NULL, 0, out, out_len, GetStdHandle(STD_ERROR_HANDLE));
}

/**
 * Like `hx_process_capture`, with the program's stderr captured too: `*err` gets malloc'ed bytes (`*err_len` of
 * them). stderr goes to a temporary file that is read back once the program ends, so neither stream can block it.
 * The program starts in `dir` when `dir_len` isn't 0, and is ended once `timeout_ms` (when above 0) has passed.
 */
int64_t hx_process_capture_all(const HxString *argv, size_t count, const char *dir, size_t dir_len, int64_t timeout_ms,
                               char **out, size_t *out_len, char **err, size_t *err_len) {
    *err = NULL;
    *err_len = 0;
    char temp[260], path[260];
    if (GetTempPathA(sizeof temp, temp) == 0 || GetTempFileNameA(temp, "hx", 0, path) == 0) return -1;
    SecurityAttributes inherit = { sizeof inherit, NULL, 1 };
    HANDLE file = CreateFileA(path, 0x40000000 /* GENERIC_WRITE */, 0x7 /* share all */, &inherit,
                              2 /* CREATE_ALWAYS */, 0, NULL);
    if (file == INVALID_HANDLE) {
        _unlink(path);
        return -1;
    }
    char *folder = NULL;
    if (dir_len > 0 && (folder = malloc(dir_len + 1))) {
        memcpy(folder, dir, dir_len);
        folder[dir_len] = '\0';
    }
    int64_t result = capture_with(argv, count, folder, timeout_ms, out, out_len, file);
    free(folder);
    CloseHandle(file);
    int fd = _open(path, 0x8000 /* _O_BINARY, read-only */);
    if (fd >= 0) {
        int64_t size = _filelengthi64(fd);
        char *buf = malloc(size > 0 ? (size_t)size : 1);
        int64_t got = 0;
        while (buf && got < size) {
            int n = _read(fd, buf + got, (unsigned)(size - got));
            if (n <= 0) break;
            got += n;
        }
        _close(fd);
        *err = buf;
        *err_len = buf ? (size_t)got : 0;
    }
    _unlink(path);
    return result;
}

/* ---- the testing allocator ---- */

/* runtime.c guards each block with pages of its own on macOS and Linux; here, as on WASI, it's plain malloc. */
void *hx_guard_alloc(size_t size, size_t align) {
    (void)align;
    return malloc(size == 0 ? 1 : size);
}

void hx_guard_free(void *memory, size_t size) {
    (void)size;
    free(memory);
}

/* ---- stack traces ---- */

/** Addresses, as offsets into the program, so `llvm-symbolizer --obj=app.exe 0x...` can name them. */
void hx_stack_trace(void) {
    void *frames[64];
    uint16_t count = RtlCaptureStackBackTrace(1, 64, frames, NULL);
    char line[96];
    uintptr_t base = (uintptr_t)GetModuleHandleA(NULL);
    static const char header[] = "stack trace (offsets into the program):\n";
    write_handle(STD_ERROR_HANDLE, header, sizeof header - 1);
    for (uint16_t i = 0; i < count; i++) {
        int n = snprintf(line, sizeof line, "  at +0x%" HX_X64 "\n", (unsigned long long)((uintptr_t)frames[i] - base));
        write_handle(STD_ERROR_HANDLE, line, (size_t)n);
    }
}
