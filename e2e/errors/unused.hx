// expect-error: unused local `temp`
// expect-error: unused parameter `b`
// expect-error: `count` is never reassigned

function f(a: i32, b: i32, _ignored: i32): i32 {
    const temp = 5;
    let count: i32 = a;
    return count;
}

export function main(): i32 {
    return f(1, 2, 3);
}
