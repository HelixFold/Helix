// Checked casts between 128-bit integers: the range check's bounds are 2^127 - 1 and -2^127, which have to be
// worked out without overflowing i128.
// expect-stdout: 12345
// expect-stdout: -7
// expect-stdout: 42

function toSigned(x: u128): i128 {
    return x as i128;
}

function toUnsigned(x: i128): u128 {
    return x as u128;
}

function toI64(x: i128): i64 {
    return x as i64;
}

export function main(): void {
    println(`${toI64(toSigned(12345))}`);
    println(`${toI64(-7)}`);
    println(`${toI64(toSigned(toUnsigned(42)))}`);
}
