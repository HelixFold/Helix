// expect-error: the result of `compute` is unused
// expect-error: this value is unused
// expect-error: nothing to discard: the expression is `void`

function compute(): i32 {
    return 1;
}

function nothing(): void {}

export function main(): void {
    compute();
    void compute();
    1 + 2;
    void nothing();
}
