// expect-error: `value` can reach its end without returning a `i32`
// expect-error: unreachable code
// expect-error: `break` outside of a loop
// expect-error: `return` can't be used inside a `defer`
// expect-error: `continue` can't jump out of a `defer`
// expect-error: no enclosing loop is labeled `inner`

function value(x: i32): i32 {
    if (x > 0) return 1;
}

function after(): i32 {
    return 1;
    void value(2);
}

export function main(): void {
    break;
    defer {
        return;
    }
    for (const i of 0..3) {
        defer {
            if (i > 1) continue;
        }
    }
    outer: while (true) {
        break inner;
    }
    void after();
}
