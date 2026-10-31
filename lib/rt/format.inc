/*
 * Number formatting for template strings, shared by the POSIX and the Windows runtime. Each writes into `buf` (at
 * least HX_FORMAT_SIZE bytes) and returns the length; the generated code then hands the text to whatever writer the
 * template goes to.
 *
 * Uses only snprintf, strtod, strtof, strchr, strlen, memmove and atoi, which the including file declares or
 * includes. HX_I64 and HX_U64 are the printf conversions for 64-bit integers ("lld" or Microsoft's "I64d").
 */

#define HX_FORMAT_SIZE 48

size_t hx_format_i64(char *buf, int64_t value) {
    return (size_t)snprintf(buf, HX_FORMAT_SIZE, "%" HX_I64, (long long)value);
}

size_t hx_format_u64(char *buf, uint64_t value) {
    return (size_t)snprintf(buf, HX_FORMAT_SIZE, "%" HX_U64, (unsigned long long)value);
}

size_t hx_format_ptr(char *buf, const void *ptr) {
    return (size_t)snprintf(buf, HX_FORMAT_SIZE, "0x%" HX_X64, (unsigned long long)(uintptr_t)ptr);
}

/** `1e-07` as `1e-7` and `1e+21` as `1e+21`: JavaScript's exponents have no leading zeros. */
static int64_t trim_exponent(char *buf, int64_t len) {
    char *e = strchr(buf, 'e');
    if (!e || (e[1] != '-' && e[1] != '+')) return len;
    char *digits = e + 2, *first = digits;
    while (*first == '0' && first[1]) first++;
    memmove(digits, first, strlen(first) + 1);
    return (int64_t)strlen(buf);
}

/**
 * The shortest text that reads back as the same number, like JavaScript: 0.1, 1.5, 2, 60, 1e+21, 1e-7.
 * `single` checks the round trip in `float` precision, so an f32 0.1 prints as 0.1.
 */
static int64_t format_float(char *buf, double value, bool single) {
    if (__builtin_isnan(value)) return snprintf(buf, HX_FORMAT_SIZE, "NaN");
    if (__builtin_isinf(value)) return snprintf(buf, HX_FORMAT_SIZE, value > 0 ? "Infinity" : "-Infinity");
    int precision = 1;
    char digits[HX_FORMAT_SIZE];
    for (; precision <= 17; precision++) {   // the fewest significant digits that read back as the same number
        snprintf(digits, sizeof digits, "%.*e", precision - 1, value);
        if (single ? strtof(digits, NULL) == (float)value : strtod(digits, NULL) == value) break;
    }
    if (precision > 17) precision = 17;
    // positional unless the exponent is below -6 or above 20, as in JavaScript (60, not 6e+01)
    int exponent = atoi(strchr(digits, 'e') + 1);
    if (value == 0 || exponent < -6 || exponent > 20) {
        int64_t len = snprintf(buf, HX_FORMAT_SIZE, "%.*g", precision, value);
        return trim_exponent(buf, len);
    }
    int decimals = precision - 1 - exponent;
    return snprintf(buf, HX_FORMAT_SIZE, "%.*f", decimals > 0 ? decimals : 0, value);
}

size_t hx_format_f64(char *buf, double value) {
    return (size_t)format_float(buf, value, false);
}

size_t hx_format_f32(char *buf, float value) {
    return (size_t)format_float(buf, value, true);
}
