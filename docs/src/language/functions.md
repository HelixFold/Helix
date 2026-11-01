# Functions

This page covers functions, arrow functions, and function values.

## Declaring a function

```hx
function clamp(x: i32, low: i32, high: i32): i32 {
    return x < low ? low : x > high ? high : x;
}

export function main(): void {
    println(clamp(42, 0, 10));      // 10
}
```

- A function's signature is its whole contract: the parameter and return types are always written.
  Only an `Error` set is inferred from the body (see [Errors](/language/errors)).
- `export` makes a function visible to other modules (see [Modules](/language/modules)).
- Every path through a function that returns a value must return one.

## Arguments are values

Arguments are passed by value.
To let a function change a variable, pass a pointer to it:

```hx
function bump(counter: *i32): void { // [!code focus]
    *counter += 1; // [!code focus]
}

export function main(): void {
    let hits: i32 = 0;
    bump(&hits); // [!code focus]
    println(hits);                  // 1
}
```

A struct reached through a pointer needs no `*` for its fields: `user.name` works on a `*User` too.
See [Memory](/language/memory).

## Function values

A function type is written like an arrow function's signature.
The parameter names are documentation: two function types are the same when their parameter and result types are.

```hx
type Predicate = (x: i32) => bool;

function isEven(x: i32): bool {
    return x % 2 == 0;
}

function count(items: readonly i32[], keep: Predicate): usize {
    let found: usize = 0;
    for (const item of items) {
        if (keep(item)) found++;
    }
    return found;
}

export function main(): void {
    const numbers: i32[6] = [1, 2, 3, 4, 5, 6];
    println(count(&numbers, isEven));                   // 3, a named function
    println(count(&numbers, (x: i32) => x > 4));        // 2, an arrow function
}
```

- A function value is a plain pointer, so a Helix function can be handed to C as a callback
  (see [C Interop](/language/c-interop)).
- Function values compare with `==` and `!=`.
- A method works as a value too, with its receiver as the first parameter: `Point.isOrigin`.
- A generic function is not a value on its own: wrap the instance you want in an arrow function.

## Arrow functions can't capture

Capturing a local would need a hidden allocation, so an arrow function can only use its parameters and globals:

```hx
export function main(): void {
    const limit: i32 = 3;
    const over = (x: i32): bool => x > limit;   // can't capture `limit` // [!code error]
}
```

```text
error: an arrow function can't capture `limit`
```

::: info 🔍 No hidden allocation
A closure would have to store `limit` somewhere, and Helix never allocates behind your back.
Pass what an arrow function needs as a parameter instead.
:::

## Optional function values

A field or variable of type `?(...) => T` holds a function or `null`, and a capture unwraps it:

```hx
struct Button {
    onClick: ?(times: u32) => void = null,
}

function clicked(times: u32): void {
    println(`clicked ${times}`);
}

export function main(): void {
    const button = Button { onClick: clicked };
    if (const handler = button.onClick) handler(1);     // clicked 1
}
```

## `main`

`main` takes nothing, or an `Init` that carries the command line and the environment:

```hx
import { Init } from "std";

export function main(init: Init): void | Error {
    for (const arg of init.args) println(arg);     // the arguments after the program name
    println(init.program);                          // the program name, as typed
    const home = init.env.get("HOME") ?? "/";       // ?string
    println(home);
}
```

It may return an error, which prints `error: <name>` and ends the program with status 1, or an integer exit status.

## See also

- [Structs, Enums, and Unions](/language/types) for methods
- [Generics and Interfaces](/language/generics)
- [Errors](/language/errors)
