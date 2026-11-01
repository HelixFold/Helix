/* Structs of every shape the C ABI treats differently, passed and returned by value. */
#include <stdint.h>

typedef struct { int32_t a, b; } Pair;                 /* 8 bytes: one register */
typedef struct { int32_t a, b, c; } Triple;            /* 12 bytes: two registers */
typedef struct { float x, y; } Vec2;                   /* two floats */
typedef struct { float x, y, z; } Vec3;
typedef struct { double x, y, z, w; } Quat;            /* four doubles */
typedef struct { double d; int32_t i; } Mixed;         /* a double and an int */
typedef struct { int64_t v[5]; } Big;                  /* 40 bytes: by pointer, returned through sret */
typedef struct { uint8_t r, g, b, a; } Color;          /* 4 bytes */

Pair pair_swap(Pair p);
Triple triple_add(Triple t, int32_t n);
Vec2 vec2_scale(Vec2 v, float k);
Vec3 vec3_cross(Vec3 a, Vec3 b);
Quat quat_neg(Quat q);
Mixed mixed_bump(Mixed m);
Big big_sum(Big a, Big b);
Color color_invert(Color c);
int64_t many(Pair a, Vec2 b, Big c, Mixed d, int32_t e, Color f);

/* calls back into Helix, through functions Helix exports with `export extern "C"` */
int64_t call_helix(void);
Pair helix_pair(Pair p, Big b);
Vec3 helix_vec3(Vec3 v);
Big helix_big(Mixed m);

/* C globals, read and written from Helix */
extern int32_t counter;
extern const char *const label;

/* a variadic function pointer, called from Helix */
typedef int (*logger_fn)(const char *fmt, ...);
logger_fn get_logger(void);

/* C calling Helix callbacks that take and return structs by value */
typedef Pair (*pair_fn)(Pair p, Big b);
typedef Vec3 (*vec3_fn)(Vec3 v);
int64_t apply_pair(pair_fn f, Pair p);
float apply_vec3(vec3_fn f, Vec3 v);
