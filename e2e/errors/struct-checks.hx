// expect-error: missing field `y` in `Point`
// expect-error: `Point` has no field `z`
// expect-error: `Node` contains itself, so it would be infinitely large
// expect-error: `move` changes the `Point`, but this value is constant
// expect-error: `Point` has no method `scale`
// expect-error: can't tell which struct this is

struct Point {
    x: i32,
    y: i32,

    move(this: *Point, dx: i32): void {
        this.x += dx;
    }
}

struct Node {
    value: i32,
    next: Node,
}

export function main(): void {
    const a = Point { x: 1 };
    const b = Point { x: 1, y: 2, z: 3 };
    const p = Point { x: 0, y: 0 };
    p.move(1);
    p.scale(2);
    const anon = { x: 1, y: 2 };
    void a;
    void b;
    void anon;
}
