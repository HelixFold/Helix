// expect-error: an arrow function can't capture `limit`
// expect-error: `max` is generic, so it can't be used as a value on its own
// expect-error: `i32` is not a function, so it can't be called
// expect-error: `?(i32) => void` is not a function, so it can't be called
// expect-error: expected `(i32) => i32`, found `(i32, i32) => i32`
// expect-error: this arrow function can reach its end without returning a `i32`
// expect-error: can't tell what type this arrow function returns
// expect-error: unused parameter `x`
// expect-error: `i32` is not a function, so it can't be called

function max<T extends Numeric>(a: T, b: T): T { return a > b ? a : b; }
function add(a: i32, b: i32): i32 { return a + b; }

struct Box {
    value: i32,
    onChange: ?(v: i32) => void,
}

function main(): void {
    const limit: i32 = 10;
    const over = (x: i32): bool => x > limit;
    const g = max;
    const n: i32 = 3;
    void n(1);
    const box = Box { value: 1, onChange: null };
    box.onChange(2);
    const f: (a: i32) => i32 = add;
    const h = (x: i32): i32 => {
        if (x > 0) return x;
    };
    const k = (x: i32) => null;
    void add(1, 2)(3);
    void over;
    void g;
    void f;
    void h;
    void k;
}
