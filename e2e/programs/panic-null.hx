// expect-panic: unwrapped a null value

function first(values: readonly i32[]): ?i32 {
    if (values.len == 0) return null;
    return values[0];
}

export function main(): i32 {
    let storage: i32[1] = undefined;
    storage[0] = 1;
    return first(storage[0..0])!;
}
