// expect-error: expected `i32`, found `null`
// expect-error: `?User` might be null
// expect-error: `??` needs an optional on the left, found `i32`
// expect-error: `!` unwraps an optional, but `i32` is never null
// expect-error: expected `string`, found `?string`
// expect-error: `i32` is never null

struct User { name: string, email: ?string = null }

function find(): ?User {
    return null;
}

export function main(): void {
    const a: i32 = null;
    const user = find();
    const name = user.name;
    const n: i32 = 5;
    const b = n ?? 1;
    const c = n!;
    let maybe: ?string = null;
    maybe = "set";
    if (maybe != null) {
        const s: string = maybe;
        void s;
    }
    void (n == null);
    void a;
    void name;
    void b;
    void c;
}
