// expect-stdout: origin 0,0 size 8
// expect-stdout: moved 3,4 length^2 25
// expect-stdout: user ada id 1 admin 0 visits 2
// expect-stdout: rect 10x20 area 200 center 5,10
// expect-stdout: through pointer 7,8
// expect-stdout: shorthand 1,2

extern "C" function printf(format: readonly u8[*], ...): i32;

struct Point {
    x: i32 = 0,
    y: i32 = 0,

    origin(): Point {
        return Point {};
    }

    lengthSquared(this: Point): i32 {
        return this.x * this.x + this.y * this.y;
    }

    move(this: *Point, dx: i32, dy: i32): void {
        this.x += dx;
        this.y += dy;
    }
}

struct User {
    id: u32,
    name: string,
    admin: bool = false,
    visits: u32 = 0,

    visit(this: *User): void {
        this.visits += 1;
    }

    show(this: readonly *User): void {
        void printf("user %.*s id %u admin %d visits %u\n", this.name.len as i32, this.name.ptr, this.id,
                    this.admin as i32, this.visits);
    }
}

struct Rect {
    size: Point,
    corner: Point = Point { x: 0, y: 0 },
}

function center(r: Rect): Point {
    return { x: r.corner.x + r.size.x / 2, y: r.corner.y + r.size.y / 2 };
}

function setThrough(p: *Point): void {
    p.x = 7;
    p.y = 8;
}

export function main(): void {
    const o = Point.origin();
    void printf("origin %d,%d size %d\n", o.x, o.y, @sizeOf(Point));

    let p = Point { x: 0, y: 0 };
    p.move(3, 4);
    void printf("moved %d,%d length^2 %d\n", p.x, p.y, p.lengthSquared());

    let ada = User { id: 1, name: "ada" };
    ada.visit();
    ada.visit();
    ada.show();

    const r = Rect { size: { x: 10, y: 20 } };
    const c = center(r);
    void printf("rect %dx%d area %d center %d,%d\n", r.size.x, r.size.y, r.size.x * r.size.y, c.x, c.y);

    let q: Point = Point.origin();
    setThrough(&q);
    void printf("through pointer %d,%d\n", q.x, q.y);

    const x: i32 = 1;
    const y: i32 = 2;
    const s = Point { x, y };
    void printf("shorthand %d,%d\n", s.x, s.y);
}
