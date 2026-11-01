// expect-panic: integer overflow

function negate(x: i8): i8 {
    return -x;
}

export function main(): i32 {
    return negate(-128);
}
