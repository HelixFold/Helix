#include "shapes.h"

Pair pair_swap(Pair p) { return (Pair){ p.b, p.a }; }
Triple triple_add(Triple t, int32_t n) { return (Triple){ t.a + n, t.b + n, t.c + n }; }
Vec2 vec2_scale(Vec2 v, float k) { return (Vec2){ v.x * k, v.y * k }; }
Vec3 vec3_cross(Vec3 a, Vec3 b) { return (Vec3){ a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x }; }
Quat quat_neg(Quat q) { return (Quat){ -q.x, -q.y, -q.z, -q.w }; }
Mixed mixed_bump(Mixed m) { return (Mixed){ m.d + 0.5, m.i + 1 }; }
Big big_sum(Big a, Big b) { Big r; for (int i = 0; i < 5; i++) r.v[i] = a.v[i] + b.v[i]; return r; }
Color color_invert(Color c) { return (Color){ 255 - c.r, 255 - c.g, 255 - c.b, c.a }; }
int64_t many(Pair a, Vec2 b, Big c, Mixed d, int32_t e, Color f) {
    return a.a + a.b + (int64_t)(b.x + b.y) + c.v[0] + c.v[4] + (int64_t)d.d + d.i + e + f.r + f.a;
}

int64_t call_helix(void) {
    Big b = { { 1, 2, 3, 4, 5 } };
    Pair p = helix_pair((Pair){ 10, 20 }, b);
    Vec3 v = helix_vec3((Vec3){ 1, 2, 3 });
    Big r = helix_big((Mixed){ 2.5, 7 });
    return p.a * 1000000 + p.b * 1000 + (int64_t)(v.x + v.y + v.z) * 10 + r.v[4];
}

#include <stdio.h>
int32_t counter = 5;
const char *const label = "from C";
logger_fn get_logger(void) { return printf; }

int64_t apply_pair(pair_fn f, Pair p) {
    Big b = { { 100, 0, 0, 0, 7 } };
    Pair r = f(p, b);
    return (int64_t)r.a * 1000 + r.b;
}
float apply_vec3(vec3_fn f, Vec3 v) {
    Vec3 r = f(v);
    return r.x + r.y + r.z;
}
