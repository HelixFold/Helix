// expect-stdout: counter 3
// expect-stdout: limits 255 -128 1048576
// expect-stdout: name helix 5

extern "C" function printf(format: readonly u8[*], ...): i32;

type Count = u32;

const NAME: string = "helix";
const MEGA: u64 = KILO * KILO;
const KILO: u64 = 1024;
let counter: Count = 0;

function bump(): void {
    counter += 1;
}

export function main(): void {
    bump();
    bump();
    bump();
    void printf("counter %u\n", counter);

    const max: u8 = 255;
    const min: i8 = -128;
    void printf("limits %d %d %llu\n", max, min, MEGA);
    void printf("name %s %zu\n", NAME.ptr, NAME.len);
}
