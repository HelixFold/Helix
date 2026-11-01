// expect-error: `void` can't be printed
// expect-error: `u32 | Problem` can't be printed
// expect-error: `print` takes one template string or value
// expect-error: a template string can only be passed to a `Format` parameter

error Problem { Bad }

function work(): u32 | Problem {
    return 1;
}

function nothing(): void {}

export function main(): void {
    println(`result ${nothing()}`);
    println(`value ${work()}`);
    print("a", "b");
    const text = `x`;
    void text;
}
