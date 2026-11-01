// expect-panic: integer cast out of range: the value doesn't fit in `u8`

function narrow(x: i32): u8 {
    return x as u8;
}

export function main(): u8 {
    return narrow(300);
}
