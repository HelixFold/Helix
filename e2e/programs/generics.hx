// expect-stdout: max 2 2.5 3 9
// expect-stdout: first 7 null
// expect-stdout: pair { left: 1, right: "one" } swapped { left: "one", right: 1 }
// expect-stdout: pop b
// expect-stdout: pop a
// expect-stdout: sum 6 and 7.5
// expect-stdout: boxes 42 / hi

function max<T extends Numeric>(a: T, b: T): T {
    return a > b ? a : b;
}

function first<T>(items: readonly T[]): ?T {
    if (items.len == 0) return null;
    return items[0];
}

struct Pair<A, B> {
    left: A,
    right: B,

    swap(this: Pair<A, B>): Pair<B, A> {
        return Pair<B, A> { left: this.right, right: this.left };
    }
}

struct Stack<T> {
    items: T[8],
    len: usize = 0,

    push(this: *Stack<T>, value: T): void {
        this.items[this.len] = value;
        this.len += 1;
    }

    pop(this: *Stack<T>): ?T {
        if (this.len == 0) return null;
        this.len -= 1;
        return this.items[this.len];
    }
}

function sum<T extends Numeric>(values: readonly T[]): T {
    let total: T = 0;
    for (const v of values) total += v;
    return total;
}

struct Box<T> {
    value: T,

    get(this: Box<T>): T {
        return this.value;
    }
}

export function main(): void {
    const small: u8 = 3;
    println(`max ${max(1, 2)} ${max(2.5, 1.5)} ${max<i64>(-5, small)} ${max(small, 9)}`);
    let numbers: i32[3] = undefined;
    numbers[0] = 7; numbers[1] = 8; numbers[2] = 9;
    println(`first ${first(&numbers)} ${first(numbers[0..0])}`);
    const p = Pair<i32, string> { left: 1, right: "one" };
    println(`pair ${p} swapped ${p.swap()}`);
    let s = Stack<string> { items: undefined };
    s.push("a");
    s.push("b");
    while (const top = s.pop()) println(`pop ${top}`);

    let ints: i32[3] = undefined;
    ints[0] = 1; ints[1] = 2; ints[2] = 3;
    let floats: f64[2] = undefined;
    floats[0] = 2.5; floats[1] = 5.0;
    println(`sum ${sum(&ints)} and ${sum(&floats)}`);

    const a = Box<i32> { value: 42 };
    const b = Box<string> { value: "hi" };
    println(`boxes ${a.get()} / ${b.get()}`);
}
