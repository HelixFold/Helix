// expect-stdout: map 8 big four
// expect-stdout: pair 2.5
// expect-stdout: repeat 3 [4, 4, 4]
// expect-stdout: stats 6 3 14 count 3
// expect-stdout: comptime 4
// expect-stdout: list [1, 4, 9] sum 14

import { ArrayList, Allocator, AllocError, DebugAllocator, cAllocator } from "std";

struct Box<T> {
    value: T,

    /** A method with a type parameter of its own: `U` comes from `f`. */
    map<U>(this: Box<T>, f: (x: T) => U): Box<U> {
        return Box<U> { value: f(this.value) };
    }

    with<U>(value: T, other: U): Box<U> {
        void value;
        return Box<U> { value: other };
    }

    repeat(this: Box<T>, comptime n: usize): T[n] {
        let out: T[n] = undefined;
        for (const i of 0..n) out[i] = this.value;
        return out;
    }
}

struct Stats {
    count: i32,

    twice<T extends Numeric>(this: *Stats, x: T): T {
        this.count += 1;
        return x + x;
    }
}

function double(x: i32): i64 {
    return (x * 2) as i64;
}

function describe(x: i64): string {
    return x > 5 ? "big" : "small";
}

function square(x: i32): i32 {
    return x * x;
}

/** A free function that maps a list into a new one, with the allocator passed in. */
function mapList<T, U>(a: dyn Allocator, items: readonly T[], f: (x: T) => U): ArrayList<U> | AllocError {
    let out = ArrayList<U>.init(a);
    errdefer out.deinit();
    for (const x of items) try out.append(f(x));
    return out;
}

function main(): void | AllocError {
    const b = Box<i32> { value: 4 };
    const four = b.map<string>((x: i32) => x == 4 ? "four" : "other").value;
    println(`map ${b.map(double).value} ${b.map(double).map(describe).value} ${four}`);
    println(`pair ${Box<i32>.with(1, 2.5).value}`);
    println(`repeat ${b.repeat(3).len} ${b.repeat(3)}`);

    let s = Stats { count: 0 };
    const a = s.twice(3);
    const c = s.twice(1.5);
    const d = s.twice<u8>(7);
    println(`stats ${a} ${c} ${d} count ${s.count}`);

    const e = comptime Box<i32> { value: 2 }.map(double).value;
    println(`comptime ${e}`);

    let debug = DebugAllocator.init(cAllocator());
    const items: i32[3] = [1, 2, 3];
    let squares = try mapList(&debug, &items, square);
    let sum: i32 = 0;
    for (const x of squares.items) sum += x;
    println(`list ${squares.items} sum ${sum}`);
    squares.deinit();
    void debug.deinit();
}
