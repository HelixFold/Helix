// expect-error: a template string can only be passed to a `Format` parameter

export function main(): void {
    const n: i32 = 1;
    const text: string = `n = ${n}`;
    void text;
}
