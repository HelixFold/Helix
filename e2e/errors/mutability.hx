// expect-error: `LIMIT` is a constant
// expect-error: parameter `x` can't be assigned
// expect-error: can't assign through a `readonly *i32`
// expect-error: can't assign through a `string`

const LIMIT: i32 = 10;

function bump(x: i32): void {
    x = x + 1;
}

function poke(p: readonly *i32, text: string): void {
    *p = 1;
    text[0] = 65;
}

export function main(): void {
    LIMIT = 5;
    bump(1);
    const n: i32 = 1;
    poke(&n, "abc");
}
