// expect-panic: shift amount is too large: it must be less than 32

function shift(x: u32, n: u32): u32 {
    return x << n;
}

export function main(): u8 {
    return @truncate(u8, shift(1, 40));
}
