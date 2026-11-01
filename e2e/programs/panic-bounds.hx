// expect-panic: index out of bounds: index 4, len 4

function at(values: readonly i32[], i: usize): i32 {
    return values[i];
}

export function main(): i32 {
    let numbers: i32[4] = undefined;
    for (const _, i of numbers) numbers[i] = 0;
    return at(&numbers, numbers.len);
}
