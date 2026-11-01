// expect-panic: integer overflow

function divide(a: i32, b: i32): i32 {
    return a / b;
}

export function main(): i32 {
    return divide(-2147483648, -1);
}
