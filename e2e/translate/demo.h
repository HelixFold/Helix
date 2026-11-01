/* Every rule of `helix translate-c`, without system headers so the output doesn't depend on the SDK. */
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include "demo-types.h"

#define DEMO_VERSION "1.2.3"
#define DEMO_MAX 64
#define DEMO_FLAGS 0x1Fu
#define DEMO_NEG (-5)
#define DEMO_RATIO 0.75f
#define DEMO_MODE 0755
#define DEMO_HEXF 0x1.8p1
#define DEMO_CHAR 'A'
#define DEMO_SQUARE(x) ((x) * (x))
#define _DEMO_PRIVATE 1

/** A point on the plane. */
struct point { int x, y; };

typedef struct demo_ctx demo_ctx;

typedef struct {
    const char *name;
    demo_id id;
    struct point at;
    double weights[4];
    demo_ctx *ctx;
    struct { int w, h; } size;
    union { int i; float f; } u;
    struct item *next;
    struct nested { short a; } inner;
    union { long l; char c; };
} item_t;

struct item { int value; struct item *next; };

typedef enum { COLOR_RED, COLOR_GREEN = 5, COLOR_BLUE } color_t;
enum flags { FLAG_A = 1, FLAG_B = -2 };
enum { ANON_ONE = 1, ANON_TWO };

union value { int64_t i; double f; char bytes[12]; };
struct packed { unsigned a : 3; unsigned b : 5; };
struct flexible { int len; char data[]; };

typedef int (*demo_cb)(void *user, int code);
typedef void (*demo_log)(const char *fmt, ...);
typedef unsigned long demo_size;
typedef demo_size demo_count;

int demo_open(const char *path, demo_ctx **out);
size_t demo_read(demo_ctx *ctx, void *buf, size_t len);
int demo_printf(const char *fmt, ...);
color_t demo_color(enum flags f, bool strict);
int demo_each(demo_ctx *ctx, demo_cb cb, void *user);
void demo_point(struct point p, item_t *item, char **names, const double weights[4], int sums[]);
void demo_set_log(demo_log log);
long double demo_ld(void);
static inline int demo_inline(int x) { return x + 1; }
int demo_type(int type, int this, int i32);
extern int demo_errno;
int demo_old();
uint64_t demo_hash(const uint8_t *bytes, size_t len, uintptr_t seed);
int stat(const char *path, struct stat *out);
struct stat { int64_t size; };
struct with_enum { enum kind { KIND_A, KIND_B } kind; enum undefined_tag *missing; };
