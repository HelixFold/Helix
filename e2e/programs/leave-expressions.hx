// expect-stdout: 40 -1 40 10 7 -1
// `?? return`, `?? continue`, `?? break`, `?? throw` and `catch return`, at runtime and at compile time.

error Bad { Nope }

function find(i: i32): ?i32 {
    return i > 0 ? i * 10 : null;
}

function parse(i: i32): i32 | Bad {
    if (i < 0) throw Bad.Nope;
    return i;
}

function first(i: i32): i32 {
    const v = find(i) ?? return -1;
    const w = parse(v) catch return -2;
    return v + w;
}

function sum(xs: readonly i32[]): i32 {
    let total: i32 = 0;
    for (const x of xs) {
        const v = find(x) ?? continue;
        if (v > 100) break;
        total += v;
    }
    return total;
}

function strict(i: i32): i32 | Bad {
    const v = find(i) ?? throw Bad.Nope;
    return v;
}

const AT_COMPILE = comptime first(0);

export function main(): void {
    const xs: i32[4] = [1, -2, 3, 50];
    println(`${first(2)} ${first(0)} ${sum(&xs)} ${strict(1) catch 0} ${strict(0) catch 7} ${AT_COMPILE}`);
}
