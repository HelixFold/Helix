// expect-stdout: [15, 126, 21] 1234 7 [0, 1, 2] 15
// Everything below runs while compiling; the program only prints the results.

error ParseError { Empty, Bad }

struct Stack {
    items: i32[8],
    len: usize,
    push(this: *Stack, x: i32): void {
        this.items[this.len] = x;
        this.len += 1;
    }
    pop(this: *Stack): ?i32 {
        if (this.len == 0) return null;
        this.len -= 1;
        return this.items[this.len];
    }
}

function digit(c: u8): u32 | ParseError {
    if (c < '0' || c > '9') throw ParseError.Bad;
    return (c - '0') as u32;
}

function parse(text: string): u32 | ParseError {
    if (text.len == 0) throw ParseError.Empty;
    let n: u32 = 0;
    for (const c of text) n = n * 10 + try digit(c);
    return n;
}

function stackSum(): i32 {
    let s = Stack { items: [0, 0, 0, 0, 0, 0, 0, 0], len: 0 };
    for (const i of 1..=5) s.push(i as i32);
    let total: i32 = 0;
    while (const x = s.pop()) total += x;
    return total;
}

function copies(): i32 {
    let a: i32[3] = [1, 2, 3];
    let b = a;
    b[0] = 100;
    const p = &a[1];
    *p = 20;
    const part = a[1..3];
    return a[0] + a[1] + b[0] + part[1] + (part.len as i32);
}

function order(): i32 {
    let log: i32 = 0;
    {
        defer log = log * 10 + 1;
        defer log = log * 10 + 2;
    }
    outer: for (const i of 0..5) {
        for (const j of 0..5) {
            if (j == 2) continue outer;
            if (i == 3) break outer;
            log += 0;
        }
    }
    return log;
}

function kind(s: string): u8 {
    return switch (s.len) {
        case 0: 0;
        case 1..=3: 1;
        default: 2;
    };
}

function fallback(): u32 {
    return parse("") catch (e) { return e == ParseError.Empty ? 7 : 8; };
}

const RESULTS = comptime [stackSum(), copies(), order()];
const PARSED = comptime (parse("1234") catch 0);
const BAD = comptime fallback();
const KINDS = comptime [kind(""), kind("ab"), kind("abcdef")];
const PICK = comptime ((x: i32): i32 => x * 3)(5);

function main(): void {
    println(`${RESULTS} ${PARSED} ${BAD} ${KINDS} ${PICK}`);
}
