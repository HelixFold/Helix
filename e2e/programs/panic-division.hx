// expect-panic: division by zero

function ratio(a: i32, b: i32): i32 {
    return a / b;
}

export function main(): i32 {
    return ratio(10, 0);
}
