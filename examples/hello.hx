/**
 * Adds two numbers.
 *
 * @param a - The first number
 * @param b - The second number
 * @returns The sum of `a` and `b`
 *
 * @remarks
 * An ordinary function: its parameter and return types are always written.
 *
 * @since 1.0.0
 */

function add(a: i32, b: i32): i32 {
    return a + b;
}

/**
 * Prints a greeting with a sum in it.
 *
 * @returns The exit status, 0
 *
 * @remarks
 * `main` may return an integer, which becomes the exit status of the program.
 *
 * @example
 * ```bash
 * helix run examples/hello.hx    # hello from helix: 42
 * ```
 *
 * @since 1.0.0
 */

export function main(): i32 {
    const total = add(40, 2);
    println(`hello from helix: ${total}`);
    return 0;
}
