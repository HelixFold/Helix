/*
 * The test runner's platform-neutral part, included by test.c (macOS, Linux: a forked process per describe and per
 * test) and test_windows.c (a child process per test). It holds the table, the selection, `expect`'s helpers, the
 * reporters and `hx_test_main`; the file that includes it provides how tests run and the few things the C library
 * does differently:
 *
 *   detail, details_text   the record of results, printed once every test has run
 *   out_write, out_flush   stdout; err_write: stderr
 *   report_write           descriptor 3, where failed `expect`s write
 *   write_file             the --summary file
 *   now_ms, stdout_is_terminal
 *   glob_match             `toMatch`
 *   filter_compile, filter_matches   `-f regex`
 *   platform_init          before the first test; platform_child: a process the runner started, or -1
 *   hx_run_test, hx_run_describe
 */

typedef uint16_t (*TestFn)(void);

/** One row of the compiler's table (must match `helix.test.entry`). */
typedef struct {
    int32_t kind;
    int32_t mode;
    const char *name;
    const char *message;    // `test.panics`: the expected message
    TestFn fn;              // test: the body; describe: fixtures and `beforeAll`; end: `afterAll`
    TestFn before;          // describe: its `beforeEach` hooks
    TestFn after;           // describe: its `afterEach` hooks
    const char *location;   // "file:line:col"
    int64_t timeout_ms;     // test: `{ timeout: ms }`, 0 = the run's default
} Entry;

enum { ENTRY_DESCRIBE, ENTRY_END, ENTRY_TEST };
enum { MODE_PLAIN, MODE_SKIP, MODE_ONLY, MODE_TODO, MODE_FAILING, MODE_PANICS };

/** Counters every process of the run adds to. */
typedef struct {
    int64_t passed, failed, panicked, skipped, todo;
    bool stop;              // `--bail` after a failure
} Shared;

#define MAX_DEPTH 64

static struct {
    const Entry *entries;
    int64_t count;
    const char *(*error_name)(uint16_t);
    void (*begin)(void);
    uint64_t (*end)(void);
    uint16_t require_code;

    bool verbose, bail, color;
    bool json;              // `--json`: one JSON object per line, for editors (docs/design/ide.md)
    bool teamcity;          // `--teamcity`: TeamCity service messages, which JetBrains IDEs' test trees read
    int64_t timeout_ms;
    bool has_filter;
    const char *label;

    Shared *shared;
    bool *runs;             // per entry: a test that runs, or a describe with a test that runs
    bool *marked;           // per test: skipped by `.skip` or `.todo` (its own or a describe's), not just filtered out
    int path[MAX_DEPTH];    // the describes around the current entry
    int depth;
} t;

static bool failed;         // the current test: an `expect` failed or something else went wrong

static void detail(const char *text, size_t len);
static char *details_text(size_t *len);
static void out_write(const char *text, size_t len);
static void out_flush(void);
static void err_write(const char *text, size_t len);
static void report_write(const char *text, size_t len);
static void write_file(const char *path, const char *text, size_t len);
static double now_ms(void);
static bool stdout_is_terminal(void);
static bool glob_match(const char *pattern, const char *text);
static bool filter_compile(const char *pattern);
static bool filter_matches(const char *name);
static bool platform_init(void);
static int platform_child(int argc, char **argv);
static void hx_run_test(int64_t index);
static void hx_run_describe(int64_t index, int64_t end);

/** A NUL-terminated copy of `len` bytes. */
static char *copy_text(const char *text, size_t len) {
    char *copy = malloc(len + 1);
    if (!copy) abort();
    memcpy(copy, text, len);
    copy[len] = '\0';
    return copy;
}

/** Whether `part` occurs in the `len` bytes at `text`. */
static bool contains_bytes(const char *text, size_t len, const char *part, size_t part_len) {
    if (part_len == 0) return true;
    for (size_t i = 0; i + part_len <= len; i++) {
        if (memcmp(text + i, part, part_len) == 0) return true;
    }
    return false;
}

/* ---- called from generated code ---- */

void hx_test_fail(void) {
    failed = true;
    report_write("\n", 1);   // separates one failed `expect`'s report from the next
}

/** `toBeCloseTo`: |a - b| < 10^-digits / 2, as in Jest. */
bool hx_test_close_to(double a, double b, int32_t digits) {
    if (__builtin_isinf(a) && __builtin_isinf(b)) return a == b;
    return fabs(a - b) < pow(10.0, -digits) / 2;
}

/** `toStartWith`, `toEndWith`, `toInclude` and `toMatch` (a glob) on two Helix strings. */
bool hx_test_text(int32_t kind, const char *text, int64_t text_len, const char *part, int64_t part_len) {
    switch (kind) {
    case 0: return part_len <= text_len && memcmp(text, part, (size_t)part_len) == 0;
    case 1: return part_len <= text_len && memcmp(text + text_len - part_len, part, (size_t)part_len) == 0;
    case 2: return contains_bytes(text, (size_t)text_len, part, (size_t)part_len);
    default: {
        char *a = copy_text(text, (size_t)text_len), *b = copy_text(part, (size_t)part_len);
        bool match = glob_match(b, a);
        free(a);
        free(b);
        return match;
    }
    }
}

/* ---- output ---- */

#define RED "\033[31m"
#define GREEN "\033[32m"
#define YELLOW "\033[33m"
#define DIM "\033[2m"
#define BOLD "\033[1m"
#define RESET "\033[0m"

static const char *paint(const char *code) {
    return t.color ? code : "";
}

typedef struct {
    char *data;
    size_t len, cap;
} Buf;

static void buf_add(Buf *b, const char *text, size_t len) {
    if (b->len + len + 1 > b->cap) {
        b->cap = (b->len + len + 1) * 2;
        b->data = realloc(b->data, b->cap);
        if (!b->data) abort();
    }
    memcpy(b->data + b->len, text, len);
    b->len += len;
    b->data[b->len] = '\0';
}

static void buf_printf(Buf *b, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

static void buf_printf(Buf *b, const char *fmt, ...) {
    char small[1024];
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(small, sizeof small, fmt, args);
    va_end(args);
    if (n < 0) return;
    if ((size_t)n < sizeof small) {
        buf_add(b, small, (size_t)n);
        return;
    }
    char *big = malloc((size_t)n + 1);
    va_start(args, fmt);
    vsnprintf(big, (size_t)n + 1, fmt, args);
    va_end(args);
    buf_add(b, big, (size_t)n);
    free(big);
}

/** Adds `text` with every line indented, dropping trailing blank lines. */
static void buf_indented(Buf *b, const char *text, size_t len, const char *indent) {
    while (len > 0 && (text[len - 1] == '\n' || text[len - 1] == ' ' || text[len - 1] == '\r')) len--;
    size_t start = 0;
    while (start < len) {
        size_t end = start;
        while (end < len && text[end] != '\n') end++;
        size_t line_end = end > start && text[end - 1] == '\r' ? end - 1 : end;   // Windows' line ends
        if (line_end > start) buf_add(b, indent, strlen(indent));
        buf_add(b, text + start, line_end - start);
        buf_add(b, "\n", 1);
        start = end + 1;
    }
}

/** "Outer › inner › should ..." for entry `index`, with the describes on the path. */
static void full_name(Buf *b, int index) {
    for (int i = 0; i < t.depth; i++) buf_printf(b, "%s › ", t.entries[t.path[i]].name);
    buf_add(b, t.entries[index].name, strlen(t.entries[index].name));
}

/* ---- --json: one event per line ---- */

/** `text` as a JSON string, quotes included. */
static void buf_json(Buf *b, const char *text, size_t len) {
    buf_add(b, "\"", 1);
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)text[i];
        if (c == '"' || c == '\\') {
            buf_add(b, "\\", 1);
            buf_add(b, (const char *)&text[i], 1);
        } else if (c == '\n') {
            buf_add(b, "\\n", 2);
        } else if (c == '\t') {
            buf_add(b, "\\t", 2);
        } else if (c < 0x20) {
            buf_printf(b, "\\u%04x", c);
        } else {
            buf_add(b, (const char *)&text[i], 1);
        }
    }
    buf_add(b, "\"", 1);
}

/** `["outer", "inner", "name"]`: the describes on the path, then entry `index` (none when it's -1). */
static void json_name(Buf *b, int index) {
    buf_add(b, "[", 1);
    for (int i = 0; i < t.depth; i++) {
        if (i) buf_add(b, ",", 1);
        const char *n = t.entries[t.path[i]].name;
        buf_json(b, n, strlen(n));
    }
    if (index >= 0) {
        if (t.depth) buf_add(b, ",", 1);
        buf_json(b, t.entries[index].name, strlen(t.entries[index].name));
    }
    buf_add(b, "]", 1);
}

/** `,"location":{...}` for the first `at file.hx:line:col` line of a failure report, if there is one. */
static void json_location(Buf *b, const char *text, size_t len) {
    size_t start = 0;
    while (start < len) {
        size_t end = start;
        while (end < len && text[end] != '\n') end++;
        size_t i = start;
        while (i < end && text[i] == ' ') i++;
        if (end - i > 3 && memcmp(text + i, "at ", 3) == 0) {
            // file:line:col, from the end: the file name may hold colons
            size_t colon2 = end, colon1;
            while (colon2 > i && text[colon2 - 1] != ':') colon2--;
            colon1 = colon2 > i + 1 ? colon2 - 1 : i;
            while (colon1 > i && text[colon1 - 1] != ':') colon1--;
            if (colon1 > i + 3 && colon2 > colon1) {
                long line = strtol(text + colon1, NULL, 10), col = strtol(text + colon2, NULL, 10);
                if (line > 0 && col > 0) {
                    buf_printf(b, ",\"location\":{\"file\":");
                    buf_json(b, text + i + 3, colon1 - 1 - (i + 3));
                    buf_printf(b, ",\"line\":%ld,\"column\":%ld}", line, col);
                    return;
                }
            }
        }
        start = end + 1;
    }
}

/* ---- --teamcity ---- */

/** `text` as a TeamCity value: `|`, `'`, `[`, `]` and line breaks escaped with `|`. */
static void tc_value(Buf *b, const char *text, size_t len) {
    for (size_t i = 0; i < len; i++) {
        char c = text[i];
        if (c == '|' || c == '\'' || c == '[' || c == ']') {
            buf_add(b, "|", 1);
            buf_add(b, &text[i], 1);
        } else if (c == '\n') {
            buf_add(b, "|n", 2);
        } else if (c == '\r') {
            buf_add(b, "|r", 2);
        } else {
            buf_add(b, &text[i], 1);
        }
    }
}

static void tc_attr(Buf *b, const char *name, const char *value, size_t len) {
    buf_printf(b, " %s='", name);
    tc_value(b, value, len);
    buf_add(b, "'", 1);
}

/*
 * A test's messages go to the details file as one record: the describes around it (separated by \x1f), \x1e, then
 * its messages (separated by \x1d). The parent turns the records into suites when it prints them, since describes run
 * in processes of their own.
 */
static void tc_event(int index, const char *status, double ms, const char *message, size_t message_len) {
    Buf b = { 0 };
    for (int i = 0; i < t.depth; i++) {
        const char *n = t.entries[t.path[i]].name;
        if (i) buf_add(&b, "\x1f", 1);
        buf_add(&b, n, strlen(n));
    }
    buf_add(&b, "\x1e", 1);
    const char *name = index >= 0 ? t.entries[index].name : "(the describe itself)";
    size_t name_len = strlen(name);
    buf_add(&b, "##teamcity[testStarted", 22);
    tc_attr(&b, "name", name, name_len);
    buf_add(&b, "]\x1d", 2);
    if (strcmp(status, "skipped") == 0 || strcmp(status, "todo") == 0) {
        buf_add(&b, "##teamcity[testIgnored", 22);
        tc_attr(&b, "name", name, name_len);
        tc_attr(&b, "message", status, strlen(status));
        buf_add(&b, "]\x1d", 2);
    } else if (strcmp(status, "passed") != 0) {
        size_t first = 0;
        while (first < message_len && message[first] != '\n') first++;
        buf_add(&b, "##teamcity[testFailed", 21);
        tc_attr(&b, "name", name, name_len);
        tc_attr(&b, "message", message, first);
        tc_attr(&b, "details", message, message_len);
        buf_add(&b, "]\x1d", 2);
    }
    buf_add(&b, "##teamcity[testFinished", 23);
    tc_attr(&b, "name", name, name_len);
    if (ms >= 0) buf_printf(&b, " duration='%lld'", (long long)ms);
    buf_add(&b, "]\n", 2);
    detail(b.data, b.len);
    free(b.data);
}

static void tc_suite(const char *what, const char *name, size_t len) {
    Buf b = { 0 };
    buf_printf(&b, "##teamcity[%s", what);
    tc_attr(&b, "name", name, len);
    buf_add(&b, "]\n", 2);
    out_write(b.data, b.len);
    free(b.data);
}

/** Prints the records of `tc_event`, inside a suite for the file and one for each describe. */
static void tc_print(const char *records, size_t len) {
    tc_suite("testSuiteStarted", t.label, strlen(t.label));
    const char *open[MAX_DEPTH];
    size_t open_len[MAX_DEPTH];
    int depth = 0;
    size_t start = 0;
    while (start < len) {
        size_t end = start;
        while (end < len && records[end] != '\n') end++;
        const char *sep = memchr(records + start, '\x1e', end - start);
        if (sep) {
            // the describes of this record: close those it isn't in, open the new ones
            const char *names[MAX_DEPTH];
            size_t lens[MAX_DEPTH];
            int n = 0;
            const char *p = records + start;
            while (p < sep && n < MAX_DEPTH) {
                const char *q = memchr(p, '\x1f', (size_t)(sep - p));
                if (!q) q = sep;
                names[n] = p;
                lens[n++] = (size_t)(q - p);
                p = q + 1;
            }
            int same = 0;
            while (same < depth && same < n && open_len[same] == lens[same] && memcmp(open[same], names[same], lens[same]) == 0) same++;
            while (depth > same) {
                depth--;
                tc_suite("testSuiteFinished", open[depth], open_len[depth]);
            }
            while (depth < n) {
                open[depth] = names[depth];
                open_len[depth] = lens[depth];
                tc_suite("testSuiteStarted", names[depth], lens[depth]);
                depth++;
            }
            Buf messages = { 0 };
            for (const char *m = sep + 1; m < records + end; m++) buf_add(&messages, *m == '\x1d' ? "\n" : m, 1);
            buf_add(&messages, "\n", 1);
            out_write(messages.data, messages.len);
            free(messages.data);
        }
        start = end + 1;
    }
    while (depth > 0) {
        depth--;
        tc_suite("testSuiteFinished", open[depth], open_len[depth]);
    }
    tc_suite("testSuiteFinished", t.label, strlen(t.label));
}

/** One event line in the details file: a test's or a describe's outcome. `ms` < 0 leaves the time out. */
static void json_event(const char *event, int index, const char *status, double ms, const char *message, size_t message_len) {
    if (t.teamcity) {
        tc_event(index, status, ms, message, message_len);
        return;
    }
    Buf b = { 0 };
    buf_printf(&b, "{\"event\":\"%s\",\"file\":", event);
    buf_json(&b, t.label, strlen(t.label));
    buf_add(&b, ",\"name\":", 8);
    json_name(&b, index);
    buf_printf(&b, ",\"status\":\"%s\"", status);
    if (ms >= 0) buf_printf(&b, ",\"ms\":%.3f", ms);
    if (message_len) {
        buf_add(&b, ",\"message\":", 11);
        buf_json(&b, message, message_len);
        json_location(&b, message, message_len);
    }
    buf_add(&b, "}\n", 2);
    detail(b.data, b.len);
    free(b.data);
}

/* ---- selection ---- */

/** The index of the END that closes the describe at `index`. */
static int64_t end_of(int64_t index) {
    int depth = 0;
    for (int64_t i = index; i < t.count; i++) {
        if (t.entries[i].kind == ENTRY_DESCRIBE) depth++;
        else if (t.entries[i].kind == ENTRY_END && --depth == 0) return i;
    }
    return t.count - 1;
}

/**
 * Decides which tests run: not skipped (itself or a describe around it), inside or marked `.only` when any `.only`
 * exists, and matching `--filter`. A describe runs when any test inside it does.
 */
static void hx_select_tests(void) {
    bool any_only = false;
    for (int64_t i = 0; i < t.count; i++) any_only |= t.entries[i].mode == MODE_ONLY;

    int stack[MAX_DEPTH];
    int depth = 0;
    for (int64_t i = 0; i < t.count; i++) {
        const Entry *e = &t.entries[i];
        if (e->kind == ENTRY_DESCRIBE) {
            if (depth < MAX_DEPTH) stack[depth++] = (int)i;
            continue;
        }
        if (e->kind == ENTRY_END) {
            depth--;
            continue;
        }
        bool skipped = e->mode == MODE_SKIP || e->mode == MODE_TODO;
        bool only = e->mode == MODE_ONLY;
        Buf name = { 0 };
        buf_add(&name, "", 0);
        for (int d = 0; d < depth; d++) {
            const Entry *outer = &t.entries[stack[d]];
            skipped |= outer->mode == MODE_SKIP;
            only |= outer->mode == MODE_ONLY;
            buf_printf(&name, "%s ", outer->name);
        }
        buf_add(&name, e->name, strlen(e->name));
        bool matches = !t.has_filter || filter_matches(name.data);
        free(name.data);
        t.runs[i] = !skipped && (!any_only || only) && matches;
        t.marked[i] = skipped;
        if (t.runs[i]) {
            for (int d = 0; d < depth; d++) t.runs[stack[d]] = true;
        }
    }
}

/** Counts the tests of a describe that are not run, as skipped or todo, and lists them with --verbose. */
static void hx_report_not_run(int64_t from, int64_t to) {
    int saved = t.depth;
    for (int64_t i = from; i <= to; i++) {
        const Entry *e = &t.entries[i];
        if (e->kind == ENTRY_DESCRIBE && t.depth < MAX_DEPTH) t.path[t.depth++] = (int)i;
        if (e->kind == ENTRY_END && t.depth > saved) t.depth--;
        if (e->kind != ENTRY_TEST || t.runs[i]) continue;
        bool todo = e->mode == MODE_TODO;
        if (todo) t.shared->todo++;
        else t.shared->skipped++;
        if (t.json && t.marked[i]) json_event("test", (int)i, todo ? "todo" : "skipped", -1, NULL, 0);
        if (!t.verbose || t.json) continue;
        Buf b = { 0 };
        buf_printf(&b, "  %s%s%s ", paint(YELLOW), todo ? "✎ todo" : "○ skip", paint(RESET));
        full_name(&b, (int)i);
        buf_add(&b, "\n", 1);
        detail(b.data, b.len);
        free(b.data);
    }
    t.depth = saved;
}

/* ---- running ---- */

/** Notes an error from a hook or body in the test's report. */
static void hx_report_error(const char *what, uint16_t code, const char *location) {
    Buf b = { 0 };
    buf_printf(&b, "%s%serror: %s\n\nat %s\n\n", what, *what ? " failed with " : "", t.error_name(code), location);
    report_write(b.data, b.len);
    free(b.data);
    failed = true;
}

/**
 * Runs test `index` in the process meant for it, with the describes around it in `t.path` already set up: the
 * describes' `beforeEach` hooks, the body, the `afterEach` hooks, then the leak check. True when it passed.
 */
static bool hx_test_body(int64_t index) {
    const Entry *e = &t.entries[index];
    failed = false;
    t.begin();

    int ready = 0;   // describes whose `beforeEach` ran
    bool ok = true;
    for (; ready < t.depth && ok; ready++) {
        const Entry *d = &t.entries[t.path[ready]];
        uint16_t code = d->before ? d->before() : 0;
        if (code) {
            char what[512];
            snprintf(what, sizeof what, "beforeEach in \"%s\"", d->name);
            hx_report_error(what, code, d->location);
            ok = false;
        }
    }
    if (ok) {
        uint16_t code = e->fn();
        if (code && code != t.require_code) hx_report_error("", code, e->location);
    }
    while (ready-- > 0) {
        const Entry *d = &t.entries[t.path[ready]];
        uint16_t code = d->after ? d->after() : 0;
        if (code) {
            char what[512];
            snprintf(what, sizeof what, "afterEach in \"%s\"", d->name);
            hx_report_error(what, code, d->location);
        }
    }
    uint64_t leaks = t.end();
    if (leaks) {
        Buf b = { 0 };
        buf_printf(&b, "testing.allocator: %llu allocation%s never freed (sizes in the output below)\n\n",
                   (unsigned long long)leaks, leaks == 1 ? " was" : "s were");
        report_write(b.data, b.len);
        free(b.data);
        failed = true;
    }
    return !failed;
}

/** The line of the captured output that starts with "panic: ", or NULL. */
static const char *panic_line(const char *output, size_t *len) {
    for (const char *line = output; line && *line;) {
        const char *end = strchr(line, '\n');
        size_t n = end ? (size_t)(end - line) : strlen(line);
        if (n > 0 && line[n - 1] == '\r') n--;
        if (n >= 7 && memcmp(line, "panic: ", 7) == 0) {
            *len = n;
            return line;
        }
        line = end ? end + 1 : NULL;
    }
    return NULL;
}

/** How a test's process ended, and what it wrote. */
typedef struct {
    bool passed;            // it exited with status 0
    bool panicked;          // it panicked (the output has the "panic: " line)
    bool timed_out;
    const char *crash;      // it crashed some other way: why, or NULL
    double ms;
    const char *output;     // its stdout and stderr
    size_t output_len;
    const char *report;     // what failed `expect`s wrote
    size_t report_len;
} Outcome;

/** Counts and reports test `index` from how its process ended. */
static void hx_record_test(int64_t index, const Outcome *o) {
    const Entry *e = &t.entries[index];
    const char *output = o->output, *text = o->report;
    size_t output_len = o->output_len, report_len = o->report_len;
    bool passed = o->passed, panicked = o->panicked, timed_out = o->timed_out;
    double ms = o->ms;

    // what happened
    Buf why = { 0 };
    buf_add(&why, "", 0);
    if (o->crash) {
        buf_printf(&why, "the test crashed: %s\n", o->crash);
    } else if (timed_out) {
        buf_printf(&why, "timed out after %lld ms\n", (long long)(e->timeout_ms ? e->timeout_ms : t.timeout_ms));
    }

    // what was wanted
    bool ok = passed;
    if (e->mode == MODE_FAILING) {
        ok = !passed && !timed_out;
        if (!ok && passed) buf_printf(&why, "this test is marked `.failing`, but it passed; remove `.failing`\n");
    } else if (e->mode == MODE_PANICS) {
        size_t line_len = 0;
        const char *line = panicked ? panic_line(output, &line_len) : NULL;
        ok = line && contains_bytes(line, line_len, e->message, strlen(e->message));
        if (!ok && line) buf_printf(&why, "expected a panic with \"%s\", but got: %.*s\n", e->message, (int)line_len, line);
        else if (!ok && !panicked) buf_printf(&why, "expected a panic with \"%s\", but the test %s\n", e->message,
                                              passed ? "finished without one" : "failed instead");
    }

    if (t.json) {
        if (ok) {
            t.shared->passed++;
            json_event("test", (int)index, "passed", ms, NULL, 0);
        } else {
            if (panicked && e->mode != MODE_PANICS) t.shared->panicked++;
            else t.shared->failed++;
            Buf m = { 0 };
            buf_add(&m, why.data, why.len);
            if (why.len && report_len) buf_add(&m, "\n", 1);
            buf_add(&m, text, report_len);
            if (output_len) buf_printf(&m, "%soutput:\n%.*s", m.len ? "\n" : "", (int)output_len, output);
            json_event("test", (int)index, panicked && e->mode != MODE_PANICS ? "panicked" : "failed", ms, m.data, m.len);
            free(m.data);
            if (t.bail) t.shared->stop = true;
        }
        free(why.data);
        return;
    }

    Buf b = { 0 };
    buf_add(&b, "", 0);
    char time[32];
    snprintf(time, sizeof time, ms >= 1 ? "%.0f ms" : "%.1f ms", ms);
    if (ok) {
        t.shared->passed++;
        if (t.verbose) {
            buf_printf(&b, "  %s✓%s ", paint(GREEN), paint(RESET));
            full_name(&b, (int)index);
            buf_printf(&b, " %s(%s)%s\n", paint(DIM), time, paint(RESET));
        }
    } else {
        if (panicked && e->mode != MODE_PANICS) t.shared->panicked++;
        else t.shared->failed++;
        buf_printf(&b, "\n  %s✗ ", paint(RED));
        full_name(&b, (int)index);
        buf_printf(&b, "%s %s(%s)%s\n", paint(RESET), paint(DIM), time, paint(RESET));
        buf_indented(&b, why.data, why.len, "    ");
        if (why.len && report_len) buf_add(&b, "\n", 1);
        buf_indented(&b, text, report_len, "    ");
        if (output_len) {
            if (!panicked || report_len || why.len) buf_printf(&b, "\n    %soutput:%s\n", paint(DIM), paint(RESET));
            buf_indented(&b, output, output_len, panicked && !report_len && !why.len ? "    " : "      ");
        }
        if (t.verbose) buf_add(&b, "\n", 1);
        if (t.bail) t.shared->stop = true;
    }
    detail(b.data, b.len);
    free(b.data);
    free(why.data);
}

/** Marks every running test of a describe that never reported as failed, with the reason. */
static void hx_fail_unreported(int64_t from, int64_t to, int64_t reported, const char *reason, const char *output, size_t output_len) {
    int64_t total = 0;
    for (int64_t i = from; i <= to; i++) total += t.entries[i].kind == ENTRY_TEST && t.runs[i];
    int64_t missing = total - reported;
    if (missing <= 0) return;
    t.shared->failed += missing;
    if (t.json) {
        Buf m = { 0 };
        buf_printf(&m, "%s; %lld test%s didn't run", reason, (long long)missing, missing == 1 ? "" : "s");
        if (output_len) buf_printf(&m, "\noutput:\n%.*s", (int)output_len, output);
        json_event("describe", -1, "failed", -1, m.data, m.len);
        free(m.data);
        if (t.bail) t.shared->stop = true;
        return;
    }
    Buf b = { 0 };
    buf_printf(&b, "\n  %s✗ ", paint(RED));
    for (int i = 0; i < t.depth; i++) buf_printf(&b, "%s%s", t.entries[t.path[i]].name, i + 1 < t.depth ? " › " : "");
    buf_printf(&b, "%s\n", paint(RESET));
    buf_printf(&b, "    %s; %lld test%s didn't run\n", reason, (long long)missing, missing == 1 ? "" : "s");
    if (output_len) {
        buf_printf(&b, "\n    %soutput:%s\n", paint(DIM), paint(RESET));
        buf_indented(&b, output, output_len, "      ");
    }
    detail(b.data, b.len);
    free(b.data);
    if (t.bail) t.shared->stop = true;
}

/** A describe's `afterAll` failed with the error `name`. */
static void hx_report_after_all(int64_t index, const char *name) {
    Buf b = { 0 };
    if (t.json) {
        buf_printf(&b, "afterAll failed with error: %s", name);
        json_event("describe", -1, "failed", -1, b.data, b.len);
    } else {
        buf_printf(&b, "\n  %s✗ %s%s\n    afterAll failed with error: %s\n", paint(RED), t.entries[index].name, paint(RESET), name);
        detail(b.data, b.len);
    }
    free(b.data);
    t.shared->failed++;
}

static int64_t hx_tests_reported(void) {
    return t.shared->passed + t.shared->failed + t.shared->panicked;
}

static void hx_run_range(int64_t from, int64_t to) {
    for (int64_t i = from; i < to && !t.shared->stop; i++) {
        const Entry *e = &t.entries[i];
        if (e->kind == ENTRY_TEST) {
            if (t.runs[i]) hx_run_test(i);
            else hx_report_not_run(i, i);
        } else if (e->kind == ENTRY_DESCRIBE) {
            int64_t end = end_of(i);
            if (t.runs[i]) hx_run_describe(i, end);
            else hx_report_not_run(i, end);
            i = end;
        }
    }
}

/* ---- main ---- */

static int usage(void) {
    const char *text = "usage: <test binary> [-f regex] [-b] [-v] [-t ms] [--name label] [--summary file] [--color|--no-color] [--json|--teamcity]\n";
    err_write(text, strlen(text));
    return 2;
}

int hx_test_main(int argc, char **argv, const Entry *entries, int64_t count, const char *(*error_name)(uint16_t),
                 void (*begin)(void), uint64_t (*end)(void), int32_t require_code) {
    t.entries = entries;
    t.count = count;
    t.error_name = error_name;
    t.begin = begin;
    t.end = end;
    t.require_code = (uint16_t)require_code;
    t.timeout_ms = 5000;
    int child = platform_child(argc, argv);
    if (child >= 0) return child;

    t.label = argv[0];
    t.color = stdout_is_terminal() && !(getenv("NO_COLOR") && *getenv("NO_COLOR"));
    const char *summary = NULL;
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        bool has_value = i + 1 < argc;
        if (strcmp(arg, "-v") == 0) t.verbose = true;
        else if (strcmp(arg, "--json") == 0) t.json = true;
        else if (strcmp(arg, "--teamcity") == 0) t.json = t.teamcity = true;
        else if (strcmp(arg, "-b") == 0) t.bail = true;
        else if (strcmp(arg, "--color") == 0) t.color = true;
        else if (strcmp(arg, "--no-color") == 0) t.color = false;
        else if (strcmp(arg, "-t") == 0 && has_value) t.timeout_ms = strtol(argv[++i], NULL, 10);
        else if (strcmp(arg, "--name") == 0 && has_value) t.label = argv[++i];
        else if (strcmp(arg, "--summary") == 0 && has_value) summary = argv[++i];
        else if (strcmp(arg, "-f") == 0 && has_value) {
            if (!filter_compile(argv[++i])) {
                Buf b = { 0 };
                buf_printf(&b, "error: invalid filter regex '%s'\n", argv[i]);
                err_write(b.data, b.len);
                free(b.data);
                return 2;
            }
            t.has_filter = true;
        } else {
            return usage();
        }
    }

    if (!platform_init()) return 2;
    t.runs = calloc((size_t)count + 1, sizeof(bool));
    t.marked = calloc((size_t)count + 1, sizeof(bool));
    hx_select_tests();

    double start = now_ms();
    hx_run_range(0, count);
    double ms = now_ms() - start;

    Shared s = *t.shared;
    int64_t total = 0;
    for (int64_t i = 0; i < count; i++) total += entries[i].kind == ENTRY_TEST;
    bool ok = s.failed == 0 && s.panicked == 0;
    size_t len;
    char *details = details_text(&len);
    Buf b = { 0 };
    if (t.teamcity) {
        tc_print(details, len);
    } else if (t.json) {   // the events, then the file's own
        buf_add(&b, details, len);
        buf_add(&b, "{\"event\":\"file\",\"file\":", 23);
        buf_json(&b, t.label, strlen(t.label));
        buf_printf(&b, ",\"status\":\"%s\",\"tests\":%lld,\"passed\":%lld,\"failed\":%lld,\"panicked\":%lld,"
                   "\"skipped\":%lld,\"todo\":%lld,\"ms\":%.3f}\n", ok ? "passed" : "failed", (long long)total,
                   (long long)s.passed, (long long)s.failed, (long long)s.panicked, (long long)s.skipped, (long long)s.todo, ms);
    } else {
        buf_printf(&b, " %s%s%s%s %s (%lld test%s", paint(BOLD), paint(ok ? GREEN : RED), ok ? "PASS" : "FAIL", paint(RESET), t.label,
                   (long long)total, total == 1 ? "" : "s");
        if (s.failed) buf_printf(&b, ", %lld failed", (long long)s.failed);
        if (s.panicked) buf_printf(&b, ", %lld panicked", (long long)s.panicked);
        buf_printf(&b, ", %.1f ms)\n", ms);
        buf_add(&b, details, len);
        if (len && (!ok || t.verbose)) buf_add(&b, "\n", 1);
    }
    if (b.len) out_write(b.data, b.len);
    out_flush();
    free(b.data);
    free(details);

    if (summary) {
        Buf line = { 0 };
        buf_printf(&line, "%lld %lld %lld %lld %lld\n", (long long)s.passed, (long long)s.failed, (long long)s.panicked,
                   (long long)s.skipped, (long long)s.todo);
        write_file(summary, line.data, line.len);
        free(line.data);
    }
    return ok ? 0 : 1;
}
