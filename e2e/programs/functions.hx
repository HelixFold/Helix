// expect-stdout: even 3
// expect-stdout: big 3
// expect-stdout: one 1 same false
// expect-stdout: mapped [1000, 2000, 3000, 4000, 5000, 6000]
// expect-stdout: square 49
// expect-stdout: method 7
// expect-stdout: clicked 1
// expect-stdout: pick 9 3
// expect-stdout: sorted [1, 2, 5, 8, 9]


type Predicate = (x: i32) => bool;

function isEven(x: i32): bool { return x % 2 == 0; }

function count(items: readonly i32[], keep: Predicate): usize {
    let n: usize = 0;
    for (const x of items) {
        if (keep(x)) n += 1;
    }
    return n;
}

function map<T, U>(items: readonly T[], out: U[], f: (x: T) => U): void {
    for (const x, i of items) out[i] = f(x);
}

struct Point {
    x: i32,
    y: i32,
    sum(this: Point): i32 { return this.x + this.y; }
}

struct Button {
    label: string,
    onClick: ?(times: u32) => void,
    click(this: *Button): void {
        if (const handler = this.onClick) handler(1);
    }
}

let current: Predicate = isEven;
const square = (x: i32): i32 => x * x;

function pick(big: bool): (a: i32, b: i32) => i32 {
    return big ? (a: i32, b: i32): i32 => a > b ? a : b : (a: i32, b: i32): i32 => a < b ? a : b;
}

extern "C" function qsort(base: u8[*], count: usize, size: usize, compare: (a: readonly u8[*], b: readonly u8[*]) => i32): void;

// A Helix function passed to C as a callback.
function compareI32(a: readonly u8[*], b: readonly u8[*]): i32 {
    unsafe {
        const x = @ptrCast(readonly *i32, a);
        const y = @ptrCast(readonly *i32, b);
        return *x < *y ? -1 : *x > *y ? 1 : 0;
    }
}

function main(): void {
    const xs: i32[6] = [1, 2, 3, 4, 5, 6];
    println(`even ${count(&xs, isEven)}`);
    println(`big ${count(&xs, (x: i32) => x > 3)}`);
    current = (x: i32) => x == 1;
    println(`one ${count(&xs, current)} same ${current == isEven}`);

    let out: i64[6] = undefined;
    map(&xs, &out, (x: i32): i64 => (x as i64) * 1000);
    println(`mapped ${out}`);
    println(`square ${square(7)}`);

    const p = Point { x: 2, y: 5 };
    const f = Point.sum;
    println(`method ${f(p)}`);

    let b = Button { label: "ok", onClick: (times: u32) => println(`clicked ${times}`) };
    b.click();
    b.onClick = null;
    b.click();
    println(`pick ${pick(true)(3, 9)} ${pick(false)(3, 9)}`);

    let nums: i32[5] = [5, 2, 9, 1, 8];
    unsafe {
        qsort(@ptrCast(u8[*], &nums), 5, @sizeOf(i32), compareI32);
    }
    println(`sorted ${nums}`);
}
