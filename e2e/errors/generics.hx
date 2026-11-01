// expect-error: `bool` doesn't satisfy `Numeric`
// expect-error: can't infer `T` for `make`
// expect-error: `Box` takes 1 type argument, but 2 were given
// expect-error: `Box` is generic, so it needs type arguments
// expect-error: `+` doesn't work on `bool`

function max<T extends Numeric>(a: T, b: T): T {
    return a > b ? a : b;
}

function make<T>(): ?T {
    return null;
}

function add<T>(a: T, b: T): T {
    return a + b;
}

struct Box<T> { value: T }

export function main(): void {
    void max(true, false);
    void make();
    const pair: Box<i32, i32> = undefined;
    const plain: Box = undefined;
    void add(true, false);
    void pair;
    void plain;
}
