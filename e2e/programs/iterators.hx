// expect-stdout: copy 0:3 1:2 2:1
// expect-stdout: in place: stopped at 3, 2 left
// expect-stdout: pointer 2 1
// expect-stdout: dyn 3 2 1 = 6
// expect-stdout: generic 2 items, total 10
// expect-stdout: odd 2 4 6
// expect-stdout: largest 9 and 7.5
// expect-stdout: deferred 1 2
// expect-stdout: comptime 4 words, longest 5
// expect-stdout: split [a] [b] [] [c]
// expect-stdout: lines <one> <two> <> <four>
// expect-stdout: sum 60

import { split, lines, parseInt } from "std";

// A source of items, one at a time: what `for ... of` takes through `dyn`.
interface Iterator<T> {
    next(this: *Self): ?T;
}

struct Countdown {
    n: i32,

    next(this: *Countdown): ?i32 {
        if (this.n == 0) return null;
        this.n -= 1;
        return this.n + 1;
    }
}

struct Words {
    text: string,
    pos: usize,

    of(text: string): Words {
        return Words { text, pos: 0 };
    }

    next(this: *Words): ?string {
        while (this.pos < this.text.len && this.text[this.pos] == ' ') this.pos++;
        if (this.pos == this.text.len) return null;
        const start = this.pos;
        while (this.pos < this.text.len && this.text[this.pos] != ' ') this.pos++;
        return this.text[start..this.pos];
    }
}

function total(it: dyn Iterator<i32>): i32 {
    let sum: i32 = 0;
    for (const x of it) {
        print(` ${x}`);
        sum += x;
    }
    return sum;
}

/** `T` comes from the `dyn Iterator<T>` the caller passes. */
function count<T>(it: dyn Iterator<T>): usize {
    let n: usize = 0;
    for (const _x of it) n++;
    return n;
}

/** Static dispatch: one copy per iterator type. */
function add<I extends Iterator<i32>>(it: *I): i32 {
    let sum: i32 = 0;
    for (const x of it) sum += x;
    return sum;
}

/** `T` comes from the constraint: `I` is known from the argument, and `I.next` returns `?T`. */
function largest<I extends Iterator<T>, T extends Numeric>(it: *I): ?T {
    let best: ?T = null;
    for (const x of it) {
        if (best == null || x > best!) best = x;
    }
    return best;
}

struct Floats {
    items: f64[3],
    pos: usize,

    next(this: *Floats): ?f64 {
        if (this.pos == this.items.len) return null;
        this.pos++;
        return this.items[this.pos - 1];
    }
}

function wordStats(text: string): usize[2] {
    let n: usize = 0;
    let longest: usize = 0;
    for (const w of Words.of(text)) {
        n++;
        if (w.len > longest) longest = w.len;
    }
    return [n, longest];
}

const STATS = comptime wordStats("  one three  two four ");

function main(): void {
    print("copy");
    for (const x, i of Countdown { n: 3 }) print(` ${i}:${x}`);
    println("");

    let c = Countdown { n: 5 };
    let stopped: i32 = 0;
    for (const x of c) {
        if (x == 3) {
            stopped = x;
            break;
        }
    }
    println(`in place: stopped at ${stopped}, ${c.n} left`);

    print("pointer");
    const p = &c;
    for (const x of p) print(` ${x}`);
    println("");

    let d = Countdown { n: 3 };
    print("dyn");
    const sum = total(&d);
    println(` = ${sum}`);

    let e = Countdown { n: 2 };
    let f = Countdown { n: 4 };
    println(`generic ${count(&e as dyn Iterator<i32>)} items, total ${add(&f)}`);

    print("odd");
    for (const x of Countdown { n: 6 }) {
        if (x % 2 == 0) continue;
        print(` ${7 - x}`);
    }
    println("");

    let g = Countdown { n: 9 };
    let h = Floats { items: [2.5, 7.5, 1.0], pos: 0 };
    println(`largest ${largest(&g)!} and ${largest(&h)!}`);

    print("deferred");
    for (const x of Countdown { n: 2 }) {
        defer print(` ${3 - x}`);
    }
    println("");

    println(`comptime ${STATS[0]} words, longest ${STATS[1]}`);

    print("split");
    for (const piece of split("a,b,,c", ",")) print(` [${piece}]`);
    println("");
    print("lines");
    for (const line of lines("one\r\ntwo\n\nfour\n")) print(` <${line}>`);
    println("");

    let n: i64 = 0;
    for (const word of split("10 20 30", " ")) n += parseInt(word) catch 0;
    println(`sum ${n}`);
}
