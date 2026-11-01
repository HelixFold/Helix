// expect-panic: reached unreachable code

function pick(n: i32): i32 {
    if (n > 0) return 1;
    unreachable;
}

export function main(): i32 {
    return pick(-1);
}
