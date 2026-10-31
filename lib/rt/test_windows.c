/*
 * The test runner for Windows, linked into the binaries `helix test` builds for it. Like runtime_windows.c it
 * declares what it uses from kernel32.dll and msvcrt.dll instead of including Windows' headers, so it builds with
 * nothing but LLVM. test_core.inc has the table, the selection and the reporters.
 *
 * Windows has no fork, so a test can't start from a copy of its describe's process. Instead the test binary runs
 * itself again for each test, as `<binary> --hx-child test <index> <report file>`: the child sets up the describes
 * around the test (fixtures and `beforeAll`, outermost first), then runs it. Each test still starts from fresh
 * fixtures, and a panic, crash or timeout only ends its own process, but `beforeAll` runs once per test rather than
 * once per describe. Each describe is first set up on its own (`--hx-child setup`), so a failing `beforeAll` is
 * reported once for the describe, and its `afterAll` runs last in a child of its own (`--hx-child teardown`).
 *
 * The child's stdout and stderr go to a file that's printed only if the test fails; failed `expect`s write their
 * report to descriptor 3, which the child opens on a second file. Only the top process counts and reports.
 */

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ---- what msvcrt.dll and kernel32.dll provide ---- */

#define IMPORT __declspec(dllimport)

typedef void *HANDLE;
typedef uint32_t DWORD;
typedef int BOOL;

typedef struct {
    DWORD length;
    void *descriptor;
    BOOL inherit;
} SecurityAttributes;

typedef struct {
    DWORD cb;
    char *reserved, *desktop, *title;
    DWORD x, y, x_size, y_size, x_chars, y_chars, fill, flags;
    uint16_t show_window, reserved2_size;
    uint8_t *reserved2;
    HANDLE input, output, error;
} StartupInfo;

typedef struct {
    HANDLE process, thread;
    DWORD process_id, thread_id;
} ProcessInformation;

IMPORT HANDLE __stdcall GetStdHandle(DWORD which);
IMPORT BOOL __stdcall WriteFile(HANDLE file, const void *bytes, DWORD len, DWORD *written, void *overlapped);
IMPORT HANDLE __stdcall CreateFileA(const char *name, DWORD access, DWORD share, SecurityAttributes *security,
                                    DWORD disposition, DWORD flags, HANDLE templ);
IMPORT BOOL __stdcall CloseHandle(HANDLE handle);
IMPORT BOOL __stdcall DeleteFileA(const char *name);
IMPORT DWORD __stdcall GetTempPathA(DWORD size, char *buf);
IMPORT unsigned __stdcall GetTempFileNameA(const char *dir, const char *prefix, unsigned unique, char *buf);
IMPORT DWORD __stdcall GetModuleFileNameA(HANDLE module, char *buf, DWORD size);
IMPORT BOOL __stdcall CreateProcessA(const char *app, char *command_line, SecurityAttributes *process,
                                     SecurityAttributes *thread, BOOL inherit, DWORD flags, void *environment,
                                     const char *dir, StartupInfo *startup, ProcessInformation *info);
IMPORT DWORD __stdcall WaitForSingleObject(HANDLE handle, DWORD ms);
IMPORT BOOL __stdcall GetExitCodeProcess(HANDLE process, DWORD *code);
IMPORT BOOL __stdcall TerminateProcess(HANDLE process, unsigned code);
IMPORT unsigned __stdcall SetErrorMode(unsigned mode);
IMPORT BOOL __stdcall QueryPerformanceCounter(int64_t *count);
IMPORT BOOL __stdcall QueryPerformanceFrequency(int64_t *frequency);

#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define STD_ERROR_HANDLE ((DWORD)-12)
#define INVALID_HANDLE ((HANDLE)(intptr_t)-1)
#define GENERIC_READ 0x80000000u
#define GENERIC_WRITE 0x40000000u
#define SHARE_ALL 0x7u                  // read, write and delete
#define CREATE_ALWAYS 2u
#define FILE_ATTRIBUTE_TEMPORARY 0x100u
#define STARTF_USESTDHANDLES 0x100u
#define WAIT_TIMEOUT 0x102u
#define INFINITE 0xffffffffu
#define TIMED_OUT 0x48544f75u           // the exit code a timed-out test is ended with ("HTOu")

IMPORT void exit(int code);
IMPORT void abort(void);
IMPORT void *malloc(size_t size);
IMPORT void *calloc(size_t count, size_t size);
IMPORT void *realloc(void *p, size_t size);
IMPORT void free(void *p);
IMPORT void *memcpy(void *to, const void *from, size_t n);
IMPORT int memcmp(const void *a, const void *b, size_t n);
IMPORT void *memchr(const void *p, int c, size_t n);
IMPORT char *strchr(const char *text, int c);
IMPORT size_t strlen(const char *text);
IMPORT int strcmp(const char *a, const char *b);
IMPORT long strtol(const char *text, char **end, int base);
IMPORT char *getenv(const char *name);
IMPORT double fabs(double x);
IMPORT double pow(double x, double y);
IMPORT int _vsnprintf(char *buf, size_t size, const char *fmt, va_list args);
IMPORT int _vscprintf(const char *fmt, va_list args);
IMPORT int _open(const char *path, int flags, ...);
IMPORT int _read(int fd, void *buf, unsigned len);
IMPORT int _write(int fd, const void *buf, unsigned len);
IMPORT int _close(int fd);
IMPORT int _dup2(int fd, int to);
IMPORT int _isatty(int fd);

#define O_RDONLY 0x0
#define O_WRONLY 0x1
#define O_APPEND 0x8
#define O_CREAT 0x100
#define O_TRUNC 0x200
#define O_BINARY 0x8000

int snprintf(char *buf, size_t size, const char *fmt, ...);   // runtime_windows.c's, a C99 one

/** C99 `vsnprintf`: the full length, and the text cut to fit (msvcrt's `_vsnprintf` returns -1 when it doesn't). */
static int vsnprintf_(char *buf, size_t size, const char *fmt, va_list args) {
    va_list copy;
    va_copy(copy, args);
    int n = _vscprintf(fmt, copy);
    va_end(copy);
    if (size > 0) {
        _vsnprintf(buf, size, fmt, args);
        buf[size - 1 < (size_t)n ? size - 1 : (size_t)n] = '\0';
    }
    return n;
}
#define vsnprintf vsnprintf_

#include "test_core.inc"

static Shared counters;
static Buf details;         // only the top process reports, so the details stay in memory
static char self[1024];     // this test binary, which runs again for each test

/* ---- what test_core.inc needs ---- */

static void write_handle(DWORD which, const char *text, size_t len) {
    HANDLE h = GetStdHandle(which);
    while (len > 0) {
        DWORD written = 0;
        if (!WriteFile(h, text, (DWORD)len, &written, NULL) || written == 0) return;
        text += written;
        len -= written;
    }
}

static void detail(const char *text, size_t len) {
    buf_add(&details, text, len);
}

static char *details_text(size_t *len) {
    *len = details.len;
    return copy_text(details.data ? details.data : "", details.len);
}

static void out_write(const char *text, size_t len) {
    write_handle(STD_OUTPUT_HANDLE, text, len);
}

static void out_flush(void) {}

static void err_write(const char *text, size_t len) {
    write_handle(STD_ERROR_HANDLE, text, len);
}

static void report_write(const char *text, size_t len) {
    while (len > 0) {
        int n = _write(3, text, (unsigned)len);
        if (n <= 0) return;
        text += n;
        len -= (size_t)n;
    }
}

static void write_file(const char *path, const char *text, size_t len) {
    int fd = _open(path, O_WRONLY | O_CREAT | O_TRUNC | O_BINARY, 0x180);   // _S_IREAD | _S_IWRITE
    if (fd < 0) return;
    _write(fd, text, (unsigned)len);
    _close(fd);
}

static double now_ms(void) {
    int64_t count, frequency;
    QueryPerformanceCounter(&count);
    QueryPerformanceFrequency(&frequency);
    return (double)count * 1000.0 / (double)frequency;
}

static bool stdout_is_terminal(void) {
    return _isatty(1) != 0;
}

/** A `[...]` class at `p` (just past the `[`): whether `c` is in it; `*end` is set past the closing `]`. */
static bool class_has(const char *p, char c, char negate, const char **end) {
    bool invert = *p == negate || (negate == '!' && *p == '^');
    if (invert) p++;
    bool found = false;
    bool first = true;
    while (*p && (*p != ']' || first)) {
        first = false;
        char lo = *p == '\\' && p[1] ? *++p : *p;
        char hi = lo;
        if (p[1] == '-' && p[2] && p[2] != ']') {
            hi = p[2] == '\\' && p[3] ? p[3] : p[2];
            p += p[2] == '\\' ? 3 : 2;
        }
        if (c >= lo && c <= hi) found = true;
        p++;
    }
    *end = *p == ']' ? p + 1 : p;
    return found != invert;
}

/** fnmatch(3) without flags: `*`, `?`, `[...]` (or `[!...]`) and `\` escapes. */
static bool glob_match(const char *pattern, const char *text) {
    const char *star = NULL, *resume = NULL;
    while (*text) {
        const char *next;
        if (*pattern == '*') {
            star = ++pattern;
            resume = text;
            continue;
        }
        if (*pattern == '?' || (*pattern == '\\' && pattern[1] == *text) || (*pattern == *text && *pattern != '[' && *pattern != '\\')) {
            pattern += *pattern == '\\' ? 2 : 1;
            text++;
            continue;
        }
        if (*pattern == '[' && class_has(pattern + 1, *text, '!', &next)) {
            pattern = next;
            text++;
            continue;
        }
        if (!star) return false;
        pattern = star;   // let the last `*` take one more character
        text = ++resume;
    }
    while (*pattern == '*') pattern++;
    return *pattern == '\0';
}

/*
 * `-f regex`: msvcrt has no regex.h, so this is a small backtracking matcher for POSIX extended regular expressions
 * as test filters use them: literals, `.`, `[...]` (ranges, `^`), `\` escapes, groups, `|`, `*`, `+`, `?`, `{m,n}`,
 * `^` and `$`. Like regexec it matches anywhere in the name, and prefers the longest repetition.
 */

enum { RE_CHAR, RE_ANY, RE_CLASS, RE_GROUP, RE_START, RE_END };

typedef struct {
    int kind;
    char c;                 // RE_CHAR
    const char *class_at;   // RE_CLASS: just past its `[`
    int group;              // RE_GROUP: its alternatives, an index into `re.alts`
    int min, max;           // how often; max -1 = no limit
} ReItem;

typedef struct { int first, count; } ReSeq;            // items, in `re.items`
typedef struct { int first, count; } ReAlt;            // sequences, in `re.seqs`

#define RE_MAX 512

static struct {
    ReItem items[RE_MAX];
    ReSeq seqs[RE_MAX];
    ReAlt alts[RE_MAX];
    int seq_list[RE_MAX];   // each alternative's sequences, by index
    int n_items, n_seqs, n_alts, n_list;
    int top;                // the whole pattern's alternatives
    const char *start;      // the name being matched, for `^`
} re;

static int re_alt(const char **p);

/** A whole number at `*p` for `{m,n}`; -1 when there's none. */
static int re_number(const char **p) {
    if (**p < '0' || **p > '9') return -1;
    int n = 0;
    while (**p >= '0' && **p <= '9' && n < 10000) n = n * 10 + (*(*p)++ - '0');
    return n;
}

/** The items up to `|`, `)` or the end, as a sequence; -1 when the pattern is malformed. */
static int re_seq(const char **p) {
    int first = re.n_items;
    int items[RE_MAX];
    int count = 0;
    while (**p && **p != '|' && **p != ')') {
        if (re.n_items >= RE_MAX || count >= RE_MAX) return -1;
        ReItem item = { .min = 1, .max = 1 };
        char c = *(*p)++;
        if (c == '.') item.kind = RE_ANY;
        else if (c == '^') item.kind = RE_START;
        else if (c == '$') item.kind = RE_END;
        else if (c == '\\') {
            if (!**p) return -1;
            item.kind = RE_CHAR;
            item.c = *(*p)++;
        } else if (c == '[') {
            item.kind = RE_CLASS;
            item.class_at = *p;
            const char *end;
            (void)class_has(*p, '\0', '^', &end);
            if (end[-1] != ']' || end == *p) return -1;
            *p = end;
        } else if (c == '(') {
            item.kind = RE_GROUP;
            item.group = re_alt(p);
            if (item.group < 0 || **p != ')') return -1;
            (*p)++;
        } else if (c == '*' || c == '+' || c == '?' || c == '{') {
            return -1;   // a repetition of nothing
        } else {
            item.kind = RE_CHAR;
            item.c = c;
        }
        for (;;) {   // its repetitions
            if (**p == '*') item.min = 0, item.max = -1;
            else if (**p == '+') item.max = -1;
            else if (**p == '?') item.min = 0;
            else if (**p == '{') {
                const char *q = *p + 1;
                int lo = re_number(&q), hi = lo;
                if (lo < 0) return -1;
                if (*q == ',') {
                    q++;
                    hi = re_number(&q);
                }
                if (*q != '}' || (hi >= 0 && hi < lo)) return -1;
                item.min = lo;
                item.max = hi;
                *p = q;
            } else break;
            (*p)++;
        }
        items[count++] = re.n_items;
        re.items[re.n_items++] = item;
    }
    // nested groups were parsed in between: keep this sequence's own items together
    ReItem own[RE_MAX];
    for (int i = 0; i < count; i++) own[i] = re.items[items[i]];
    first = re.n_items;
    if (re.n_items + count > RE_MAX || re.n_seqs >= RE_MAX) return -1;
    for (int i = 0; i < count; i++) re.items[re.n_items++] = own[i];
    re.seqs[re.n_seqs] = (ReSeq){ first, count };
    return re.n_seqs++;
}

/** Sequences separated by `|`, as alternatives; -1 when the pattern is malformed. */
static int re_alt(const char **p) {
    int seqs[RE_MAX];
    int count = 0;
    for (;;) {
        int seq = re_seq(p);
        if (seq < 0 || count >= RE_MAX) return -1;
        seqs[count++] = seq;
        if (**p != '|') break;
        (*p)++;
    }
    if (re.n_alts >= RE_MAX || re.n_list + count > RE_MAX) return -1;
    re.alts[re.n_alts] = (ReAlt){ re.n_list, count };
    for (int i = 0; i < count; i++) re.seq_list[re.n_list++] = seqs[i];
    return re.n_alts++;
}

/** What's left to match after the current item: the rest of a sequence, or more repetitions of a group. */
typedef struct ReCont {
    const ReSeq *seq;           // the rest of this sequence, from `at`
    int at;
    const ReItem *repeat;       // or: a group repeated `done` times so far, last from `from`
    int done;
    const char *from;
    const struct ReCont *next;
} ReCont;

static bool re_match_seq(const ReSeq *seq, int at, const char *text, const ReCont *k);

static bool re_continue(const char *text, const ReCont *k);

/** `item` matched `done` times, up to `text`: tries once more (longest first), then what comes after. */
static bool re_repeat(const ReItem *item, int done, const char *text, const char *from, const ReCont *k) {
    bool more = item->max < 0 || done < item->max;
    if (more && !(done > 0 && text == from && done >= item->min)) {   // an empty repetition can't repeat forever
        if (item->kind == RE_GROUP) {
            const ReAlt *alt = &re.alts[item->group];
            ReCont again = { .repeat = item, .done = done + 1, .from = text, .next = k };
            for (int i = 0; i < alt->count; i++) {
                if (re_match_seq(&re.seqs[re.seq_list[alt->first + i]], 0, text, &again)) return true;
            }
        } else {
            bool one = false;
            if (*text) {
                if (item->kind == RE_ANY) one = true;
                else if (item->kind == RE_CHAR) one = *text == item->c;
                else if (item->kind == RE_CLASS) {
                    const char *end;
                    one = class_has(item->class_at, *text, '^', &end);
                }
            }
            if (one && re_repeat(item, done + 1, text + 1, text, k)) return true;
        }
    }
    return done >= item->min && re_continue(text, k);
}

static bool re_continue(const char *text, const ReCont *k) {
    if (!k) return true;   // the whole pattern matched; what follows in the name doesn't matter
    if (k->repeat) return re_repeat(k->repeat, k->done, text, k->from, k->next);
    return re_match_seq(k->seq, k->at, text, k->next);
}

static bool re_match_seq(const ReSeq *seq, int at, const char *text, const ReCont *k) {
    if (at == seq->count) return re_continue(text, k);
    const ReItem *item = &re.items[seq->first + at];
    ReCont rest = { .seq = seq, .at = at + 1, .next = k };
    if (item->kind == RE_START) return text == re.start && re_match_seq(seq, at + 1, text, k);
    if (item->kind == RE_END) return *text == '\0' && re_match_seq(seq, at + 1, text, k);
    return re_repeat(item, 0, text, NULL, &rest);
}

static bool filter_compile(const char *pattern) {
    const char *p = pattern;
    re.top = re_alt(&p);
    return re.top >= 0 && *p == '\0';   // a `)` with no `(`, or anything this matcher doesn't read, is an error
}

static bool filter_matches(const char *name) {
    re.start = name;
    const ReAlt *alt = &re.alts[re.top];
    for (const char *at = name;; at++) {
        for (int i = 0; i < alt->count; i++) {
            if (re_match_seq(&re.seqs[re.seq_list[alt->first + i]], 0, at, NULL)) return true;
        }
        if (!*at) return false;
    }
}

static bool platform_init(void) {
    t.shared = &counters;
    // a crashing test ends with its exception code, without Windows' error dialog
    SetErrorMode(0x1 | 0x2 | 0x8000);   // SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX
    if (GetModuleFileNameA(NULL, self, sizeof self) == 0) {
        const char *text = "helix test: can't find the test binary's own path\n";
        err_write(text, strlen(text));
        return false;
    }
    return true;
}

/** Puts the describes around entry `index` in `t.path`, outermost first. */
static void describes_around(int64_t index) {
    t.depth = 0;
    for (int64_t i = 0; i < index; i++) {
        if (t.entries[i].kind == ENTRY_DESCRIBE && t.depth < MAX_DEPTH) t.path[t.depth++] = (int)i;
        else if (t.entries[i].kind == ENTRY_END && t.depth > 0) t.depth--;
    }
}

/**
 * `--hx-child test|setup|teardown <index> <report file>`, a process the runner started: sets up the describes around
 * entry `index` (and, for setup and teardown, that describe itself), then runs the test or the describe's
 * `afterAll`. Exits with 0 when it passed, 1 when a test failed, 2 when a describe's block failed (its error's name
 * in the report). -1 when this isn't such a process.
 */
static int platform_child(int argc, char **argv) {
    if (argc != 5 || strcmp(argv[1], "--hx-child") != 0) return -1;
    const char *kind = argv[2];
    int64_t index = strtol(argv[3], NULL, 10);
    if (index < 0 || index >= t.count) return 2;
    int report = _open(argv[4], O_WRONLY | O_APPEND | O_BINARY);
    if (report >= 0 && report != 3) {
        _dup2(report, 3);
        _close(report);
    }
    bool test = strcmp(kind, "test") == 0;
    describes_around(index);
    if (!test && t.depth < MAX_DEPTH) t.path[t.depth++] = (int)index;
    for (int i = 0; i < t.depth; i++) {
        const Entry *d = &t.entries[t.path[i]];
        uint16_t code = d->fn ? d->fn() : 0;
        if (code == 0) continue;
        if (test) {
            char what[512];
            snprintf(what, sizeof what, "beforeAll in \"%s\"", d->name);
            hx_report_error(what, code, d->location);
            return 1;
        }
        const char *name = t.error_name(code);
        report_write(name, strlen(name));
        return 2;
    }
    if (test) return hx_test_body(index) ? 0 : 1;
    if (strcmp(kind, "teardown") == 0) {
        const Entry *end = &t.entries[end_of(index)];
        uint16_t code = end->fn ? end->fn() : 0;
        if (code) {
            const char *name = t.error_name(code);
            report_write(name, strlen(name));
            return 2;
        }
    }
    return 0;
}

/* ---- running ---- */

/** How one child process went. */
typedef struct {
    DWORD code;             // its exit code
    bool timed_out;
    double ms;
    char *output;           // its stdout and stderr
    size_t output_len;
    char *report;           // descriptor 3
    size_t report_len;
} Child;

/** A new, empty temporary file's path in `path`. */
static void temp_path(char *path) {
    char dir[1024];
    if (GetTempPathA(sizeof dir, dir) == 0 || GetTempFileNameA(dir, "hxt", 0, path) == 0) {
        const char *text = "helix test: cannot create a temporary file\n";
        err_write(text, strlen(text));
        exit(2);
    }
}

/** The whole contents of the file at `path`, which is then deleted. */
static char *slurp_path(const char *path, size_t *len) {
    Buf b = { 0 };
    buf_add(&b, "", 0);
    int fd = _open(path, O_RDONLY | O_BINARY);
    if (fd >= 0) {
        char chunk[4096];
        int n;
        while ((n = _read(fd, chunk, sizeof chunk)) > 0) buf_add(&b, chunk, (size_t)n);
        _close(fd);
    }
    DeleteFileA(path);
    *len = b.len;
    return b.data;
}

/** Runs this binary as `--hx-child <kind> <index>`, ending it after `timeout_ms` (0: no limit). */
static Child spawn(const char *kind, int64_t index, int64_t timeout_ms) {
    char out_path[1024], report_path[1024];
    temp_path(out_path);
    temp_path(report_path);
    SecurityAttributes inherit = { sizeof inherit, NULL, 1 };
    HANDLE out = CreateFileA(out_path, GENERIC_READ | GENERIC_WRITE, SHARE_ALL, &inherit, CREATE_ALWAYS,
                             FILE_ATTRIBUTE_TEMPORARY, NULL);
    if (out == INVALID_HANDLE) {
        const char *text = "helix test: cannot create a temporary file\n";
        err_write(text, strlen(text));
        exit(2);
    }
    char command[4096];
    snprintf(command, sizeof command, "\"%s\" --hx-child %s %lld \"%s\"", self, kind, (long long)index, report_path);
    StartupInfo startup = { 0 };
    startup.cb = sizeof startup;
    startup.flags = STARTF_USESTDHANDLES;
    startup.input = GetStdHandle((DWORD)-10);   // STD_INPUT_HANDLE
    startup.output = out;
    startup.error = out;
    ProcessInformation process = { 0 };

    Child c = { 0 };
    double start = now_ms();
    if (!CreateProcessA(self, command, NULL, NULL, 1, 0, NULL, NULL, &startup, &process)) {
        const char *text = "helix test: cannot start the test binary again for a test\n";
        err_write(text, strlen(text));
        exit(2);
    }
    CloseHandle(process.thread);
    DWORD wait = timeout_ms > 0 ? (DWORD)timeout_ms : INFINITE;
    if (WaitForSingleObject(process.process, wait) == WAIT_TIMEOUT) {
        TerminateProcess(process.process, TIMED_OUT);
        WaitForSingleObject(process.process, INFINITE);
        c.timed_out = true;
    }
    c.ms = now_ms() - start;
    GetExitCodeProcess(process.process, &c.code);
    CloseHandle(process.process);
    CloseHandle(out);
    c.output = slurp_path(out_path, &c.output_len);
    c.report = slurp_path(report_path, &c.report_len);
    return c;
}

/** Why a process that ended with `code` crashed, for an exception's code; NULL for an ordinary exit status. */
static const char *crash_reason(DWORD code, char *buf, size_t size) {
    switch (code) {
    case 0xC0000005u: return "access violation (a null or dangling pointer, or past the end of an allocation)";
    case 0xC00000FDu: return "stack overflow";
    case 0xC0000094u: return "integer division by zero";
    case 0xC000001Du: return "illegal instruction";
    case 0xC0000409u: return "the program ended itself on a fatal error (fast fail)";
    }
    if (code < 0xC0000000u) return NULL;
    snprintf(buf, size, "exception 0x%08lX", (unsigned long)code);
    return buf;
}

static void hx_run_test(int64_t index) {
    const Entry *e = &t.entries[index];
    Child c = spawn("test", index, e->timeout_ms ? e->timeout_ms : t.timeout_ms);
    char buf[64];
    size_t panic_len;
    Outcome o = {
        .ms = c.ms, .output = c.output, .output_len = c.output_len, .report = c.report, .report_len = c.report_len,
        .timed_out = c.timed_out, .passed = !c.timed_out && c.code == 0,
    };
    o.panicked = !c.timed_out && c.code == 3 && panic_line(c.output, &panic_len);   // a panic ends in abort()
    if (!c.timed_out && !o.panicked) {
        o.crash = c.code == 3 ? "abort() was called" : crash_reason(c.code, buf, sizeof buf);
    }
    hx_record_test(index, &o);
    free(c.output);
    free(c.report);
}

/** A describe: set up on its own first (fixtures and `beforeAll`), then each test inside, then `afterAll`. */
static void hx_run_describe(int64_t index, int64_t end) {
    int64_t before = hx_tests_reported();
    int depth = t.depth;
    if (t.depth < MAX_DEPTH) t.path[t.depth++] = (int)index;
    Child c = spawn("setup", index, 0);
    if (c.code != 0) {
        char buf[64];
        size_t panic_len;
        const char *crash = crash_reason(c.code, buf, sizeof buf);
        Buf reason = { 0 };
        if (c.code == 2) buf_printf(&reason, "beforeAll or a fixture failed with error: %.*s", (int)c.report_len, c.report);
        else if (c.code == 3 && panic_line(c.output, &panic_len)) buf_printf(&reason, "the block panicked outside its tests");
        else buf_printf(&reason, "the block crashed outside its tests: %s", crash ? crash : "abort() was called");
        hx_fail_unreported(index, end, hx_tests_reported() - before, reason.data, c.output, c.output_len);
        free(reason.data);
        free(c.output);
        free(c.report);
        t.depth = depth;
        return;
    }
    free(c.output);
    free(c.report);

    hx_run_range(index + 1, end);
    if (t.entries[end].fn && !t.shared->stop) {
        c = spawn("teardown", index, 0);
        if (c.code == 2) {
            char *name = copy_text(c.report, c.report_len);
            hx_report_after_all(index, name);
            free(name);
        } else if (c.code != 0) {
            hx_report_after_all(index, "it panicked or crashed");
        }
        free(c.output);
        free(c.report);
    }
    t.depth = depth;
}
