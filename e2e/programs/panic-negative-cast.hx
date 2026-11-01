// expect-panic: integer cast out of range: the value doesn't fit in `u64`

function widen(x: i32): u64 {
    return x as u64;
}

export function main(): u8 {
    return @truncate(u8, widen(-1));
}
