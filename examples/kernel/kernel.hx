/**
 * A point on a grid.
 *
 * @remarks
 * A struct literal names every field that has no default.
 *
 * @since 1.0.0
 */

struct Point {
    /**
     * The horizontal position.
     *
     * @since 1.0.0
     */

    x: i32,

    /**
     * The vertical position.
     *
     * @since 1.0.0
     */

    y: i32,
}

/**
 * Computes a Fibonacci number with a loop.
 *
 * @param n - The position in the sequence, starting at 0
 * @returns The `n`th Fibonacci number
 *
 * @remarks
 * The loop runs `n` times, and `_` names a loop value that the body never reads.
 *
 * @since 1.0.0
 */

function fib(n: u64): u64 {
    let a: u64 = 0;
    let b: u64 = 1;
    for (const _ of 0..n) {
        const next = a + b;
        a = b;
        b = next;
    }
    return a;
}

/**
 * Prints a greeting, a struct, a 64-bit number, a float, and an array.
 *
 * @param board - The name of the architecture, which `main` picks while compiling
 *
 * @remarks
 * Nothing here depends on the board.
 * `println` reaches the UART through `helix_console_write` in main.hx.
 *
 * @example
 * ```hx
 * kernelMain("riscv64"); // Hello from Helix on riscv64, without an OS
 * ```
 *
 * @since 1.0.0
 */

export function kernelMain(board: string): void {
    println(`Hello from Helix on ${board}, without an OS`);
    const p = Point { x: 3, y: 4 };
    println(`point: ${p.x}, ${p.y}; fib(50) = ${fib(50)}; pi is about ${3.14159}`);
    let squares: u32[5] = undefined;
    for (const i of 0..5) squares[i] = (i * i) as u32;
    println(`squares: ${squares[1]} ${squares[2]} ${squares[3]} ${squares[4]}`);
}
