// expect-error: only a C function type can be variadic
// expect-error: a C global gets its value from C
// expect-error: a C global needs a type
// expect-error: `copy` is a constant
// expect-error: `(Pair) => Pair` and `extern "C" (Pair) => Pair` pass structs by value differently

import * as other from "./support/c-interop-other";

struct Pair { a: i32, b: i32 }

extern "C" let withValue: i32 = 3;
extern "C" let untyped;

function toC(f: (p: Pair) => Pair): extern "C" (p: Pair) => Pair {
    return f;   // a runtime function pointer: no C entry point can be made for it
}

export function main(): void {
    const log: ?(fmt: string, ...) => void = null;
    void log;
    other.copy = 2;
    void toC;
    void withValue;
    void untyped;
}
