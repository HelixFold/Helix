/** Helper module for e2e/programs/modules.hx. */

export struct Point {
    x: i32,
    y: i32,

    add(this: Point, other: Point): Point {
        return Point { x: this.x + other.x, y: this.y + other.y };
    }
}

export const ORIGIN_X: i32 = 0;
export let created: u32 = 0;

export function point(x: i32, y: i32): Point {
    created += 1;
    return Point { x, y };
}

export function twice<T extends Numeric>(value: T): T {
    return value + value;
}

function secret(): i32 {
    return 42;
}

export function reveal(): i32 {
    return secret();
}
