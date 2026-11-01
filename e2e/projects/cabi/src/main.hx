import * as c from "./shapes";

// Helix functions C calls, with structs by value both ways
export extern "C" function helix_pair(p: c.Pair, b: c.Big): c.Pair {
    return c.Pair { a: p.a + b.v[0] as i32, b: p.b + b.v[4] as i32 };
}

export extern "C" function helix_vec3(v: c.Vec3): c.Vec3 {
    return c.Vec3 { x: v.x * 2.0, y: v.y * 2.0, z: v.z * 2.0 };
}

export extern "C" function helix_big(m: c.Mixed): c.Big {
    return c.Big { v: [1, 2, 3, 4, m.i as i64 + m.d as i64] };
}

// plain Helix functions (not `extern "C"`), handed to C as callbacks that pass structs by value
function add_big(p: c.Pair, b: c.Big): c.Pair {
    return c.Pair { a: p.a + b.v[0] as i32, b: p.b + b.v[4] as i32 };
}

function scale3(v: c.Vec3): c.Vec3 {
    return c.Vec3 { x: v.x * 10.0, y: v.y * 10.0, z: v.z * 10.0 };
}

export function main(): void {
    const p = c.pair_swap(c.Pair { a: 1, b: 2 });
    println(`pair ${p.a} ${p.b}`);
    const t = c.triple_add(c.Triple { a: 1, b: 2, c: 3 }, 10);
    println(`triple ${t.a} ${t.b} ${t.c}`);
    const v = c.vec2_scale(c.Vec2 { x: 1.5, y: 2.5 }, 2.0);
    println(`vec2 ${v.x} ${v.y}`);
    const x = c.vec3_cross(c.Vec3 { x: 1, y: 2, z: 3 }, c.Vec3 { x: 4, y: 5, z: 6 });
    println(`vec3 ${x.x} ${x.y} ${x.z}`);
    const q = c.quat_neg(c.Quat { x: 1, y: 2, z: 3, w: 4 });
    println(`quat ${q.x} ${q.y} ${q.z} ${q.w}`);
    const m = c.mixed_bump(c.Mixed { d: 1.5, i: 7 });
    println(`mixed ${m.d} ${m.i}`);
    const b = c.big_sum(c.Big { v: [1, 2, 3, 4, 5] }, c.Big { v: [10, 20, 30, 40, 50] });
    println(`big ${b.v[0]} ${b.v[1]} ${b.v[2]} ${b.v[3]} ${b.v[4]}`);
    const k = c.color_invert(c.Color { r: 0, g: 128, b: 255, a: 9 });
    println(`color ${k.r} ${k.g} ${k.b} ${k.a}`);
    const n = c.many(c.Pair { a: 1, b: 2 }, c.Vec2 { x: 3, y: 4 }, c.Big { v: [100, 0, 0, 0, 50] },
                     c.Mixed { d: 5.9, i: 6 }, 7, c.Color { r: 40, g: 0, b: 0, a: 1 });
    println(`many ${n}`);
    const back = c.call_helix();
    println(`call_helix ${back - 15} + 15`);

    c.counter += 1;
    unsafe {
        println(`globals ${c.counter} ${c.label!}`);
    }
    const log = c.get_logger()!;
    void log("variadic %d %s\n", 42 as i32, "pointer");
    println(`callbacks ${c.apply_pair(add_big, c.Pair { a: 1, b: 2 })} ${c.apply_vec3(scale3, c.Vec3 { x: 1, y: 2, z: 3 })}`);
}
