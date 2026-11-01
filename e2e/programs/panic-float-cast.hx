// expect-panic: float cast out of range: the value doesn't fit in `i32`

function whole(x: f64): i32 {
    return x as i32;
}

export function main(): i32 {
    return whole(1e20);
}
