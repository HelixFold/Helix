// expect-stdout: before 1 after 42
// expect-stdout: swap 2 1
// expect-stdout: readonly 9
// expect-stdout: raw 104 105

extern "C" function printf(format: readonly u8[*], ...): i32;

function set(target: *i32, value: i32): void {
    *target = value;
}

function swap(a: *i32, b: *i32): void {
    const tmp = *a;
    *a = *b;
    *b = tmp;
}

function read(p: readonly *i32): i32 {
    return *p;
}

export function main(): void {
    let x: i32 = 1;
    void printf("before %d", x);
    set(&x, 42);
    void printf(" after %d\n", x);

    let a: i32 = 1;
    let b: i32 = 2;
    swap(&a, &b);
    void printf("swap %d %d\n", a, b);

    const nine: i32 = 9;
    void printf("readonly %d\n", read(&nine));

    const text: string = "hi";
    const raw = text.ptr;
    unsafe {
        void printf("raw %d %d\n", raw[0], raw[1]);
    }
}
