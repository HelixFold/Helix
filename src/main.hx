// Hello from Helix: what `helix build run` prints, and what the release archives ship.

/** Adds two numbers. */
export function add(a: i32, b: i32): i32 {
    return a + b;
}

export function main(): void {
    println("Hello from Helix!");
    println(`2 + 3 = ${add(2, 3)}`);
}
