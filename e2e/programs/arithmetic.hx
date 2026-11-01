// expect-stdout: 17 3 70 1 3
// expect-stdout: wrap 255 0 254
// expect-stdout: sat 255 0 -128
// expect-stdout: shift 40 2 -4
// expect-stdout: cast 300 44 -1 4294967295
// expect-stdout: float 3.75 2 0.5
// expect-stdout: bits 8 255 5
// expect-stdout: const 1024 60

extern "C" function printf(format: readonly u8[*], ...): i32;

// Values arrive as parameters so the operations run at runtime instead of being folded by the compiler.

const KB: usize = 1 << 10;
const MASK: u8 = 0b1111_0000 >> 2;

function basic(a: i32, b: i32): void {
    void printf("%d %d %d %d %d\n", a + b, a - b, a * b, a / b, a % b);
}

function wrapping(max: u8, zero: u8): void {
    void printf("wrap %d %d %d\n", max, max +% 1, zero -% 2);
}

function saturating(max: u8, zero: u8, low: i8): void {
    void printf("sat %d %d %d\n", max +| 10, zero -| 1, low -| 100);
}

function shifts(value: u32, negative: i32): void {
    void printf("shift %u %u %d\n", value << 3, value >> 1, negative >> 1);
}

function casts(wide: i32, minus_one: i32): void {
    void printf("cast %d %d %lld %u\n", wide, @truncate(u8, wide), minus_one as i64, @truncate(u32, minus_one));
}

function floats(x: f64, y: f32): void {
    void printf("float %.2f %d %.1f\n", x + y, (x + y) as i32 - 1, 1.0 / 2.0);
}

function bits(value: u8): void {
    void printf("bits %d %d %d\n", @sizeOf(u64), value | 0x50, (value & 0x0F) ^ 0b1010);
}

export function main(): void {
    basic(10, 7);
    wrapping(255, 0);
    saturating(255, 0, -100);
    shifts(5, -8);
    casts(300, -1);
    floats(1.5, 2.25);
    bits(0b1010_1111);
    void printf("const %zu %d\n", KB, MASK);
}
