// expect-error: integer 300 does not fit in `u8`
// expect-error: integer overflow in a constant expression
// expect-error: -1 does not fit in `u32`
// expect-error: division by zero in a constant expression
// expect-error: shift amount 64 is too large for `u64`
// expect-error: index 4 is out of bounds for `i32[4]`

const LIMIT: u8 = 200;

export function main(): void {
    const a: u8 = 300;
    const b: u8 = LIMIT + LIMIT;
    const c = -1 as u32;
    const d = 10 / 0;
    const one: u64 = 1;
    const e = one << 64;
    let values: i32[4] = undefined;
    values[4] = 1;
    void a;
    void b;
    void c;
    void d;
    void e;
}
