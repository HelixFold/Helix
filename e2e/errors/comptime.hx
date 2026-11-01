// expect-error: integer overflow at compile time: the result doesn't fit in `u8`
// expect-error: compile-time evaluation took more than 1000000 steps (loop iterations and calls)
// expect-error: index out of bounds at compile time: index 5, len 3
// expect-error: `abs` is a C function, so it can't run at compile time
// expect-error: panic at compile time: negative input
// expect-error: a `*i32` made at compile time can't be kept for the program
// expect-error: `counter` is only known when the program runs
// expect-error: not here
// expect-error: `n` is a `comptime` parameter, so its argument must be known while compiling
// expect-error: `down` was instantiated 1000 times
// expect-error: Header must be 12 bytes

struct Header { magic: u32, size: u64 }

comptime {
    if (@sizeOf(Header) != 12) @compileError("Header must be 12 bytes");
}

function overflow(): u8 {
    let x: u8 = 250;
    for (const _ of 0..10) x += 1;
    return x;
}

function forever(): i32 {
    let n: i32 = 0;
    while (true) n = n +% 1;
}

function outOfBounds(): i32 {
    const a: i32[3] = [1, 2, 3];
    let i: usize = 0;
    while (i < 5) i += 1;
    return a[i];
}

extern "C" function abs(x: i32): i32;

function checked(n: i32): i32 {
    if (n < 0) @panic("negative input");
    return n;
}

function address(): *i32 {
    let x: i32 = 1;
    const p = &x;   // through a variable, which `return &x`'s own check doesn't follow
    return p;
}

let counter: i32 = 0;

const A = comptime overflow();
const B = comptime forever();
const C = comptime outOfBounds();
const D = comptime abs(-3);
const E = comptime checked(-1);
const F = comptime address();
const G = comptime counter + 1;

function main(): void {
    @compileError("not here");
}

function repeat(comptime n: usize): usize { return n; }
function down(comptime n: u32): u32 { return down(n + 1); }

function useParams(): void {
    let k: usize = 3;
    k += 1;
    void repeat(k);
    void down(0);
}
