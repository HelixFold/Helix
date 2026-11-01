// expect-panic: integer overflow
// expect-stdout: 64
// expect-stdout: 128

extern "C" function printf(format: readonly u8[*], ...): i32;

function double(x: u8): u8 {
    return x * 2;
}

export function main(): void {
    let level: u8 = 32;
    while (true) {
        level = double(level);
        void printf("%d\n", level);
    }
}
