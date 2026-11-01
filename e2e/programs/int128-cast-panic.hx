// A u128 above i128's largest value doesn't fit in it.
// expect-panic: integer cast out of range: the value doesn't fit in `i128`

function toSigned(x: u128): i128 {
    return x as i128;
}

function plusOne(x: u128): u128 {
    return x + 1;
}

export function main(): void {
    void toSigned(plusOne(170141183460469231731687303715884105727));
}
