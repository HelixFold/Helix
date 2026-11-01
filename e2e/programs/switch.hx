// expect-stdout: 0 ok
// expect-stdout: 2 warning
// expect-stdout: 404 client error
// expect-stdout: 503 server error 503
// expect-stdout: 42 unknown
// expect-stdout: GET -> 1, POST -> 2, PUT -> 0
// expect-stdout: origin, y-axis, diagonal, elsewhere
// expect-stdout: yes no

extern "C" function printf(format: readonly u8[*], ...): i32;

struct Point { x: i32, y: i32 }

function status(code: i32): void {
    switch (code) {
        case 0:
            void printf("%d ok\n", code);
        case 1:
        case 2:
            void printf("%d warning\n", code);
        case 400..=499:
            void printf("%d client error\n", code);
        case n if n >= 500:
            void printf("%d server error %d\n", code, n);
        default:
            void printf("%d unknown\n", code);
    }
}

function method(name: string): i32 {
    return switch (name) {
        case "GET": 1;
        case "POST": 2;
        default: 0;
    };
}

function where(p: Point): readonly u8[*] {
    return switch (p) {
        case { x: 0, y: 0 }: "origin";
        case { x: 0 }: "y-axis";
        case { x, y } if x == y: "diagonal";
        default: "elsewhere";
    };
}

function answer(b: bool): readonly u8[*] {
    return switch (b) {
        case true: "yes";
        case false: "no";
    };
}

export function main(): void {
    status(0);
    status(2);
    status(404);
    status(503);
    status(42);
    void printf("GET -> %d, POST -> %d, PUT -> %d\n", method("GET"), method("POST"), method("PUT"));
    void printf("%s, %s, %s, %s\n", where({ x: 0, y: 0 }), where({ x: 0, y: 5 }), where({ x: 3, y: 3 }), where({ x: 1, y: 2 }));
    void printf("%s %s\n", answer(true), answer(false));
}
