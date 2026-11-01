// C globals, C function pointers (variadic ones too), and `&x` / `&array` as C many-pointers.
// expect-stdout: optind 1 -> 2
// expect-stdout: printf through a pointer: 42 C
// expect-stdout: sorted [1, 2, 5, 9]

extern "C" let optind: i32;
extern "C" function printf(fmt: ?readonly u8[*], ...): i32;
extern "C" function fflush(stream: ?u8[*]): i32;
extern "C" function qsort(base: ?u8[*], count: usize, size: usize, compare: ?extern "C" (a: ?readonly u8[*], b: ?readonly u8[*]) => i32): void;

function byValue(a: ?readonly u8[*], b: ?readonly u8[*]): i32 {
    unsafe {
        const x = @ptrCast(readonly i32[*], a!)[0];
        const y = @ptrCast(readonly i32[*], b!)[0];
        return x < y ? -1 : x > y ? 1 : 0;
    }
}

export function main(): void {
    const before = optind;
    optind = optind + 1;
    println(`optind ${before} -> ${optind}`);

    const say: extern "C" (fmt: ?readonly u8[*], ...) => i32 = printf;
    void fflush(null);
    void say("printf through a pointer: %d %s\n", 42 as i32, "C");
    void fflush(null);

    let items: i32[4] = [9, 2, 5, 1];
    unsafe {
        qsort(@ptrCast(u8[*], &items), 4, 4, byValue);   // C's `void *` is `?u8[*]`
    }
    println(`sorted ${items}`);
}
