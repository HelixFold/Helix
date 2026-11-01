// expect-error: the loop advances this `Counter`, but it's constant
// expect-error: `for-of` calls `Failing.next()`, which isn't `next(this: *Self): ?T`
// expect-error: `for-of` calls `Wrong.next()`, which isn't `next(this: *Self): ?T`
// expect-error: `next` changes the `Counter`, but this pointer is readonly
// expect-error: `Iterator<i32>` is an interface, not a type
// expect-error: `Iterator` is generic, so it needs type arguments
// expect-error: `get` has no type parameters of its own
// expect-error: `Box<i32>.map` is generic, so it can't be used as a value on its own
// expect-error: `GenericNext.next` is generic, so `for-of` can't call it
// expect-error: expected `dyn Iterator<i32>`, found `*GenericNext`
// expect-error: can't loop over `integer literal`
// expect-error: methods called through `dyn` have no type parameters
// expect-error: `Box<bool>` doesn't implement `Iterator<i32>`

interface Iterator<T> {
    next(this: *Self): ?T;
}

struct Counter {
    n: i32,

    next(this: *Counter): ?i32 {
        this.n += 1;
        return this.n < 3 ? this.n : null;
    }
}

struct Failing {
    next(this: *Failing): ?i32 | Error {
        return null;
    }
}

struct Wrong {
    next(this: Wrong): i32 {
        return 1;
    }
}

struct GenericNext {
    next<T>(this: *GenericNext, x: T): ?T {
        return x;
    }
}

struct Box<T> {
    value: T,

    get(this: Box<T>): T {
        return this.value;
    }

    map<U>(this: Box<T>, f: (x: T) => U): U {
        return f(this.value);
    }
}

function first<I extends Iterator<i32>>(it: *I): ?i32 {
    return it.next();
}

export function main(): void {
    const c = Counter { n: 0 };
    for (const x of c) println(x);

    const f = Failing {};
    for (const x of f) println(x);

    const w = Wrong {};
    for (const x of w) println(x);

    const r: readonly *Counter = &c;
    for (const x of r) println(x);

    const it: Iterator<i32> = undefined;
    const it2: dyn Iterator = undefined;
    void it;
    void it2;

    const b = Box<i32> { value: 1 };
    println(b.get<i32>());
    const m = Box<i32>.map;
    void m;

    let g = GenericNext {};
    for (const x of g) println(x);
    const d: dyn Iterator<i32> = &g;

    for (const x of 5) println(x);
    void d.next<i32>();

    let bb = Box<bool> { value: true };
    void first(&bb);
}
