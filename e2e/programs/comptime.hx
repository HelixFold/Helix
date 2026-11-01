// expect-stdout: crc 907060870 table[1] 1996959894
// expect-stdout: fib 6765 point { x: 3, y: 21 } primes [2, 3, 5, 7, 11, 13, 17, 19, 23, 29] few
// expect-stdout: [1, 2, 3, 4] 8
// expect-stdout: ababab
// expect-stdout: cdcdcd
// expect-stdout: x
// expect-stdout: [0, 0, 0, 0] [0, 0]
// expect-stdout: 81 64
// expect-stdout: the number is 5
// expect-stdout: 6

struct Header { magic: u32, version: u16, flags: u16, size: u64 }

comptime {
    if (@sizeOf(Header) != 16) @compileError("Header must be 16 bytes");
}

function buildCrcTable(): u32[256] {
    let table: u32[256] = undefined;
    for (const i of 0..256) {
        let c = i as u32;
        for (const _ of 0..8) {
            c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
        }
        table[i] = c;
    }
    return table;
}

const CRC_TABLE = comptime buildCrcTable();

function crc32(bytes: readonly u8[]): u32 {
    let crc: u32 = 0xFFFFFFFF;
    for (const b of bytes) crc = CRC_TABLE[((crc ^ b) & 0xFF) as usize] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFF;
}

function fib(n: u64): u64 {
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

struct Point {
    x: i32,
    y: i32 = 7,
    scaled(this: Point, k: i32): Point { return Point { x: this.x * k, y: this.y * k }; }
}

function primes(): u32[10] {
    let out: u32[10] = undefined;
    let found: usize = 0;
    let n: u32 = 2;
    while (found < 10) {
        let prime = true;
        for (let d: u32 = 2; d * d <= n; d += 1) {
            if (n % d == 0) {
                prime = false;
                break;
            }
        }
        if (prime) {
            out[found] = n;
            found += 1;
        }
        n += 1;
    }
    return out;
}

function name(n: i32): string {
    return switch (n) {
        case 1: "one";
        case 2, 3: "few";
        default: "many";
    };
}

const FIB_30 = comptime fib(20);
const ORIGIN = comptime (Point { x: 1 }).scaled(3);
const PRIMES = comptime primes();
const WORD = comptime name(3);

function main(): void {
    println(`crc ${crc32("hello")} table[1] ${CRC_TABLE[1]}`);
    println(`fib ${FIB_30} point ${ORIGIN} primes ${PRIMES} ${WORD}`);
    const local: u8[4] = comptime [1, 2, 3, 4];
    const buf: u8[comptime fib(6)] = undefined;
    void buf;
    println(`${local} ${buf.len}`);
    parameters();
}

function repeat(comptime n: usize, s: string): void {
    for (const _ of 0..n) print(s);
    println("");
}

function zeros<T>(comptime n: usize): T[n] {
    let out: T[n] = undefined;
    for (const _, i of out) out[i] = 0;
    return out;
}

function power(comptime exponent: u32, base: i64): i64 {
    let result: i64 = 1;
    for (const _ of 0..exponent) result *= base;
    return result;
}

function label(comptime verbose: bool, n: i32): void {
    if (verbose) println(`the number is ${n}`);
    else println(`${n}`);
}

const N = comptime power(3, 4);

function parameters(): void {
    repeat(3, "ab");
    repeat(3, "cd");
    repeat(1, "x");
    const z = zeros<u8>(4);
    println(`${z} ${zeros<f64>(2)}`);
    println(`${power(2, 9)} ${N}`);
    label(true, 5);
    label(false, 6);
}
