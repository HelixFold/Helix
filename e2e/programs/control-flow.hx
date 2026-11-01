// expect-stdout: if: negative zero positive
// expect-stdout: while: 0 1 2 3 4
// expect-stdout: for: 10 8 6 4 2
// expect-stdout: range: 0 1 2 3
// expect-stdout: inclusive u8: 256 iterations, last 255
// expect-stdout: labels: (0,0) (1,0) (1,1) (2,0) (2,1) (2,2) done
// expect-stdout: ternary: big small
// expect-stdout: logic: true false

extern "C" function printf(format: readonly u8[*], ...): i32;

function sign(x: i32): readonly u8[*] {
    if (x < 0) {
        return "negative";
    } else if (x == 0) {
        return "zero";
    }
    return "positive";
}

function describe(n: i32): readonly u8[*] {
    return n > 100 ? "big" : "small";
}

function check(a: bool, b: bool): bool {
    return a && !b || (b && !a);
}

export function main(): void {
    void printf("if: %s %s %s\n", sign(-5), sign(0), sign(9));

    void printf("while:");
    let i: i32 = 0;
    while (i < 5) {
        void printf(" %d", i);
        i++;
    }
    void printf("\n");

    void printf("for:");
    for (let j: i32 = 10; j > 0; j -= 2) void printf(" %d", j);
    void printf("\n");

    void printf("range:");
    for (const k of 0..4) void printf(" %zu", k);
    void printf("\n");

    let count: u32 = 0;
    let last: u8 = 0;
    const lo: u8 = 0;
    const hi: u8 = 255;
    for (const v of lo..=hi) {
        count += 1;
        last = v;
    }
    void printf("inclusive u8: %u iterations, last %d\n", count, last);

    void printf("labels:");
    outer: for (const a of 0..10) {
        for (const b of 0..10) {
            if (b > a) continue outer;
            if (a == 3) break outer;
            void printf(" (%zu,%zu)", a, b);
        }
    }
    void printf(" done\n");

    void printf("ternary: %s %s\n", describe(500), describe(5));
    void printf("logic: %s %s\n", check(true, false) ? "true" : "false", check(true, true) ? "true" : "false");
}
