// expect-stdout: body
// expect-stdout: second
// expect-stdout: first
// expect-stdout: loop 0 cleanup 0
// expect-stdout: loop 1 cleanup 1
// expect-stdout: early cleanup
// expect-stdout: result 7
// expect-stdout: break cleanup
// expect-stdout: nested inner
// expect-stdout: nested outer

extern "C" function printf(format: readonly u8[*], ...): i32;

function order(): void {
    defer void printf("first\n");
    defer {
        void printf("second\n");
    }
    void printf("body\n");
}

function early(x: i32): i32 {
    defer void printf("early cleanup\n");
    if (x > 0) return x + 2;
    return 0;
}

export function main(): void {
    order();
    for (const i of 0..2) {
        defer void printf(" cleanup %zu\n", i);
        void printf("loop %zu", i);
    }
    void printf("result %d\n", early(5));

    while (true) {
        defer void printf("break cleanup\n");
        break;
    }

    {
        defer void printf("nested outer\n");
        {
            defer void printf("nested inner\n");
        }
    }
}
