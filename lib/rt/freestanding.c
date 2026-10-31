/*
 * The runtime of programs without an operating system (`--target <arch>-freestanding`): kernels, boot code, firmware.
 * It has what generated code calls (the memory functions, a small printf for panic messages, number formatting,
 * hx_write) and no libc. Output and stopping are the program's: it defines
 *
 *   export extern "C" function helix_console_write(bytes: readonly u8[*], len: usize): void   // println, panics
 *   export extern "C" function helix_halt(): noreturn                                         // after a panic
 *
 * Without them, output goes nowhere and a panic waits for an interrupt forever. Floats print with up to nine
 * significant digits, not the shortest text that reads back (that needs strtod).
 */

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ---- the program's hooks ---- */

__attribute__((weak)) void helix_console_write(const char *bytes, size_t len) {
    (void)bytes;
    (void)len;
}

__attribute__((weak, noreturn)) void helix_halt(void) {
    for (;;) {
#if defined(__riscv)
        __asm__ volatile("wfi");
#elif defined(__aarch64__) || defined(__arm__)
        __asm__ volatile("wfe");
#elif defined(__x86_64__) || defined(__i386__)
        __asm__ volatile("cli; hlt");
#endif
    }
}

/* ---- memory: what the compiler emits calls to ---- */

void *memcpy(void *dst, const void *src, size_t n) {
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
    unsigned char *d = dst;
    const unsigned char *s = src;
    if (d < s) {
        while (n--) *d++ = *s++;
    } else {
        while (n--) d[n] = s[n];
    }
    return dst;
}

void *memset(void *dst, int c, size_t n) {
    unsigned char *d = dst;
    while (n--) *d++ = (unsigned char)c;
    return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = a, *y = b;
    for (size_t i = 0; i < n; i++) {
        if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
    }
    return 0;
}

int bcmp(const void *a, const void *b, size_t n) {
    return memcmp(a, b, n);
}

size_t strlen(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

/* ---- formatting ---- */

typedef struct {
    char *buf;      // null: count only
    size_t size;
    size_t len;     // what the whole text needs, as snprintf returns
} Out;

static void put(Out *o, char c) {
    if (o->buf && o->len + 1 < o->size) o->buf[o->len] = c;
    o->len++;
}

static void puts_n(Out *o, const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) put(o, s[i]);
}

static void put_unsigned(Out *o, unsigned long long v, unsigned base, bool upper) {
    char digits[24];
    int n = 0;
    do {
        unsigned d = (unsigned)(v % base);
        digits[n++] = (char)(d < 10 ? '0' + d : (upper ? 'A' : 'a') + d - 10);
        v /= base;
    } while (v);
    while (n) put(o, digits[--n]);
}

static void put_signed(Out *o, long long v) {
    if (v < 0) {
        put(o, '-');
        put_unsigned(o, (unsigned long long)0 - (unsigned long long)v, 10, false);
    } else {
        put_unsigned(o, (unsigned long long)v, 10, false);
    }
}

/** A float with up to `digits` significant digits, as `12.5`, `0.001` or `1.5e+20`. */
static void put_float(Out *o, double v, int digits) {
    if (v != v) {
        puts_n(o, "NaN", 3);
        return;
    }
    if (v < 0 || (v == 0 && 1 / v < 0)) {
        put(o, '-');
        v = -v;
    }
    if (v > 1.7976931348623157e308) {
        puts_n(o, "Infinity", 8);
        return;
    }
    if (v == 0) {
        put(o, '0');
        return;
    }
    int exp10 = 0;
    while (v >= 10) {
        v /= 10;
        exp10++;
    }
    while (v < 1) {
        v *= 10;
        exp10--;
    }
    // the significant digits, rounded
    char d[20];
    for (int i = 0; i < digits; i++) {
        int digit = (int)v;
        d[i] = (char)('0' + digit);
        v = (v - digit) * 10;
    }
    if (v >= 5) {
        int i = digits - 1;
        while (i >= 0 && d[i] == '9') d[i--] = '0';
        if (i >= 0) {
            d[i]++;
        } else {   // 9.99 -> 10.0
            for (int k = digits - 1; k > 0; k--) d[k] = d[k - 1];
            d[0] = '1';
            exp10++;
        }
    }
    int last = digits - 1;
    while (last > 0 && d[last] == '0') last--;
    if (exp10 >= 21 || exp10 < -6) {
        put(o, d[0]);
        if (last > 0) {
            put(o, '.');
            puts_n(o, d + 1, (size_t)last);
        }
        put(o, 'e');
        put(o, exp10 < 0 ? '-' : '+');
        put_unsigned(o, (unsigned long long)(exp10 < 0 ? -exp10 : exp10), 10, false);
        return;
    }
    if (exp10 < 0) {
        puts_n(o, "0.", 2);
        for (int i = -1; i > exp10; i--) put(o, '0');
        puts_n(o, d, (size_t)last + 1);
        return;
    }
    for (int i = 0; i <= exp10; i++) put(o, i <= last ? d[i] : '0');
    if (last > exp10) {
        put(o, '.');
        puts_n(o, d + exp10 + 1, (size_t)(last - exp10));
    }
}

/** printf's conversions that panics and the formatters use: %s %.*s %c %d %i %u %x %X %p %e %f %g, with l and ll. */
static void format(Out *o, const char *fmt, va_list args) {
    for (const char *p = fmt; *p; p++) {
        if (*p != '%') {
            put(o, *p);
            continue;
        }
        p++;
        int precision = -1;
        if (*p == '.') {
            p++;
            if (*p == '*') {
                precision = va_arg(args, int);
                p++;
            } else {
                precision = 0;
                while (*p >= '0' && *p <= '9') precision = precision * 10 + (*p++ - '0');
            }
        }
        int longs = 0;
        while (*p == 'l') {
            longs++;
            p++;
        }
        switch (*p) {
        case 's': {
            const char *s = va_arg(args, const char *);
            if (!s) s = "(null)";
            size_t n = strlen(s);
            if (precision >= 0 && (size_t)precision < n) n = (size_t)precision;
            puts_n(o, s, n);
            break;
        }
        case 'c':
            put(o, (char)va_arg(args, int));
            break;
        case 'd':
        case 'i':
            put_signed(o, longs >= 2 ? va_arg(args, long long) : longs == 1 ? va_arg(args, long) : va_arg(args, int));
            break;
        case 'u':
        case 'x':
        case 'X': {
            unsigned long long v = longs >= 2 ? va_arg(args, unsigned long long)
                                 : longs == 1 ? va_arg(args, unsigned long) : va_arg(args, unsigned);
            put_unsigned(o, v, *p == 'u' ? 10 : 16, *p == 'X');
            break;
        }
        case 'p':
            puts_n(o, "0x", 2);
            put_unsigned(o, (unsigned long long)(uintptr_t)va_arg(args, void *), 16, false);
            break;
        case 'e':
        case 'f':
        case 'g':
            put_float(o, va_arg(args, double), 9);
            break;
        case '%':
            put(o, '%');
            break;
        default:   // unknown: as written
            put(o, '%');
            if (*p) put(o, *p);
            else p--;
        }
    }
}

int vsnprintf(char *buf, size_t size, const char *fmt, va_list args) {
    Out o = { buf, size, 0 };
    format(&o, fmt, args);
    if (buf && size) buf[o.len < size ? o.len : size - 1] = 0;
    return (int)o.len;
}

int snprintf(char *buf, size_t size, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(buf, size, fmt, args);
    va_end(args);
    return n;
}

/** Every file descriptor is the console. */
int dprintf(int fd, const char *fmt, ...) {
    (void)fd;
    char text[512];
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(text, sizeof text, fmt, args);
    va_end(args);
    helix_console_write(text, (size_t)n < sizeof text ? (size_t)n : sizeof text - 1);
    return n;
}

int fflush(void *stream) {
    (void)stream;
    return 0;
}

__attribute__((noreturn)) void abort(void) {
    helix_halt();
}

/**
 * The start code's trap handler: an exception nothing else handles (an illegal instruction, a bad address). It
 * prints what the processor reports, then halts. RISC-V: mcause, mepc, mtval; aarch64: ESR_EL1, ELR_EL1, FAR_EL1.
 */
__attribute__((noreturn)) void hx_freestanding_trap(uint64_t cause, uint64_t pc, uint64_t value) {
#if defined(__riscv)
    dprintf(2, "\ntrap: mcause 0x%llx at pc 0x%llx (mtval 0x%llx)\n", (unsigned long long)cause,
            (unsigned long long)pc, (unsigned long long)value);
#else
    dprintf(2, "\nexception: ESR 0x%llx at pc 0x%llx (FAR 0x%llx)\n", (unsigned long long)cause,
            (unsigned long long)pc, (unsigned long long)value);
#endif
    helix_halt();
}

/* ---- what generated code calls ---- */

void hx_write(int32_t fd, const char *bytes, size_t len) {
    (void)fd;
    if (len) helix_console_write(bytes, len);
}

/** No unwinding tables to walk without an OS; a debugger shows the stack. */
void hx_stack_trace(void) {}

#define HX_FORMAT_SIZE 48

size_t hx_format_i64(char *buf, int64_t value) {
    return (size_t)snprintf(buf, HX_FORMAT_SIZE, "%lld", (long long)value);
}

size_t hx_format_u64(char *buf, uint64_t value) {
    return (size_t)snprintf(buf, HX_FORMAT_SIZE, "%llu", (unsigned long long)value);
}

size_t hx_format_ptr(char *buf, const void *ptr) {
    return (size_t)snprintf(buf, HX_FORMAT_SIZE, "%p", ptr);
}

size_t hx_format_f64(char *buf, double value) {
    Out o = { buf, HX_FORMAT_SIZE, 0 };
    put_float(&o, value, 9);
    buf[o.len < HX_FORMAT_SIZE ? o.len : HX_FORMAT_SIZE - 1] = 0;
    return o.len;
}

size_t hx_format_f32(char *buf, float value) {
    Out o = { buf, HX_FORMAT_SIZE, 0 };
    put_float(&o, value, 7);
    buf[o.len < HX_FORMAT_SIZE ? o.len : HX_FORMAT_SIZE - 1] = 0;
    return o.len;
}
