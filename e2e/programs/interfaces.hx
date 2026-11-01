// expect-stdout: circle 48
// expect-stdout: square 36
// expect-stdout: total 5
// expect-stdout: counted 11 in 2 writes
// expect-stdout: logged 3
// expect-stdout: none
// expect-stdout: list 3
// expect-stdout: dir north
// expect-stdout: area 2

interface Shape {
    area(this: readonly *Self): f64;
    scale(this: *Self, by: f64): void;
    name(this: Self): string;
}

struct Circle {
    r: f64,
    area(this: readonly *Circle): f64 { return 3.0 * this.r * this.r; }
    scale(this: *Circle, by: f64): void { this.r = this.r * by; }
    name(this: Circle): string { return "circle"; }
}

// Methods may promise more than the interface asks: by value instead of through a pointer.
struct Square {
    side: f64,
    area(this: Square): f64 { return this.side * this.side; }
    scale(this: *Square, by: f64): void { this.side = this.side * by; }
    name(this: Square): string { return "square"; }
}

function describe(s: dyn Shape): void {
    println(`${s.name()} ${s.area()}`);
}

function total<S extends Shape>(items: readonly S[]): f64 {
    let sum: f64 = 0.0;
    for (const item of items) sum = sum + item.area();
    return sum;
}

interface Writer {
    write(this: *Self, bytes: string): usize;
}

struct Counter {
    bytes: usize,
    writes: u32,
    write(this: *Counter, bytes: string): usize {
        this.bytes = this.bytes + bytes.len;
        this.writes = this.writes + 1;
        return bytes.len;
    }
}

// A `dyn` stored in a struct, and an optional one.
struct Logger {
    out: dyn Writer,
    backup: ?dyn Writer,
    lines: u32,
    log(this: *Logger, line: string): void {
        void this.out.write(line);
        this.lines = this.lines + 1;
    }
}

// Generic structs implement interfaces too.
struct Stack<T> {
    items: T[4],
    len: usize,
    write(this: *Stack<T>, bytes: string): usize {
        this.len = this.len + 1;
        return bytes.len;
    }
}

// So do enums and unions.
enum Direction {
    North,
    South,
    name(this: Direction): string {
        return this == Direction.North ? "north" : "south";
    }
}

interface Named {
    name(this: Self): string;
}

union Figure {
    rect: f64,
    dot,
    area(this: readonly *Figure): f64 {
        switch (*this) {
            case .rect(w): return w * w / 2.0;
            case .dot: return 0.0;
        }
    }
}

interface Measured {
    area(this: readonly *Self): f64;
}

function pick(first: bool, a: *Counter, b: *Counter): dyn Writer {
    return first ? a : b;
}

function main(): void {
    let c = Circle { r: 2.0 };
    let sq = Square { side: 3.0 };
    const shapes: dyn Shape[2] = [&c, &sq];
    for (const s of shapes) s.scale(2.0);
    for (const s of shapes) describe(s);
    const squares = [Square { side: 1.0 }, Square { side: 2.0 }];
    println(`total ${total(&squares)}`);

    let x = Counter { bytes: 0, writes: 0 };
    let y = Counter { bytes: 0, writes: 0 };
    const w = pick(true, &x, &y);
    void w.write("hello ");
    void w.write("world");
    println(`counted ${x.bytes} in ${x.writes} writes`);

    let log = Logger { out: &y, backup: null, lines: 0 };
    log.log("a");
    log.log("b");
    log.log("c");
    println(`logged ${y.writes}`);
    if (const b = log.backup) void b.write("unused");
    else println("none");

    let stack = Stack<i32> { items: [0, 0, 0, 0], len: 0 };
    const sw: dyn Writer = &stack;
    for (const _ of 0..3) void sw.write("x");
    println(`list ${stack.len}`);

    const d = Direction.North;
    const named: dyn Named = &d;   // every method leaves the value alone, so a readonly pointer works
    println(`dir ${named.name()}`);

    const f = Figure.rect(2.0);
    const m: dyn Measured = &f;
    println(`area ${m.area()}`);
}
