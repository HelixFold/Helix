// expect-error: expected `u8`, found `i32`
// expect-error: mismatched operand types `i32` and `u32`
// expect-error: expected `bool`, found `i32`
// expect-error: can't negate unsigned `u32`
// expect-error: can't tell which number type `n` should be
// expect-error: can't convert `bool` to `f64` with `as`

function narrow(x: i32): u8 {
    return x;
}

function mix(a: i32, b: u32): i64 {
    return a + b;
}

export function main(): void {
    const flag: i32 = 1;
    if (flag) {}
    const u: u32 = 5;
    void -u;
    let n = 0;
    n += 1;
    void (true as f64);
    void narrow(1);
    void mix(1, 2);
}
