// expect-error: unknown name `missing`
// expect-error: `total` is already declared
// expect-error: `square` takes 1 argument, but 2 were given
// expect-error: unknown function `nope`
// expect-error: `i32` is a type, not a value

function square(x: i32): i32 {
    return x * x;
}

export function main(): i32 {
    const total: i32 = missing;
    const total: i32 = 2;
    void nope();
    void i32;
    return square(1, 2);
}
