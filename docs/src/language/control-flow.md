# Control Flow

This page covers `if`, the loops, iterators, and `switch`.

## if

```hx
if (x > 0) {
    println("positive");
} else if (x < 0) {
    println("negative");
} else {
    println("zero");
}
```

The condition must be a `bool`: `if (count)` is an error, so write `if (count != 0)`.
`if (const v = maybe)` runs its block when an optional holds a value (see [Optionals](/language/optionals)).

## Loops

```hx
while (i < n) i++;
while (const item = it.next()) use(item);       // loops while next() gives a value

for (let j: usize = 0; j < n; j++) { ... }      // the C loop
for (const item of items) { ... }               // arrays, slices, ranges, and iterators
for (const item, index of items) { ... }        // with the index
for (const n of 0..3) { ... }                   // 0 1 2: a range leaves out its end
for (const n of 1..=3) { ... }                  // 1 2 3: `..=` keeps it
```

`break` and `continue` work as in TypeScript, and a label names the loop that they leave:

```hx
const grid: i32[2][3] = [[1, 0, 3], [4, 5, 6]];
outer: for (const row of grid) {
    for (const cell of row) {
        if (cell == 0) continue outer;
        print(`${cell} `);
    }
}
// 1 4 5 6
```

## Iterators

An iterator is any value whose type has a method `next(this: *Self): ?T`.
`for (const x of it)` calls `next()` before each pass and stops at `null`:

```hx
struct Countdown {
    n: i32,

    next(this: *Countdown): ?i32 {
        if (this.n == 0) return null;
        this.n -= 1;
        return this.n + 1;
    }
}

export function main(): void {
    let count = Countdown { n: 3 };
    for (const n of count) print(`${n} `);          // 3 2 1
}
```

| Iterable                               | What the loop advances                         |
|----------------------------------------|------------------------------------------------|
| a `let` variable                       | the variable itself, and a `const` is an error |
| a pointer `*It`                        | the iterator that it points to                 |
| a `dyn Iterator<T>`                    | the iterator behind it, through its vtable     |
| any other value, such as `lines(text)` | a copy, which ends with the loop               |

`std/text` gives `lines` and `split`, which iterate a text without allocating:

```hx
import { lines } from "std";

for (const line of lines("one\ntwo")) print(`<${line}> `);     // <one> <two>
```

A `next` that can fail, `?T | Error`, doesn't fit `for-of`, which has no place for a `try`.
Write `while (const x = try it.next()) { ... }` instead.

## switch

A `switch` has no fallthrough, so no `break` is needed, and cases are tried from top to bottom.
The expression form gives each case one value:

```hx
function status(code: i32): string {
    return switch (code) {
        case 0: "ok";
        case 1, 2: "warning";                   // either value
        case 400..=499: "client error";         // a range
        case n if n >= 500: "server error";     // a binding with a guard
        default: "unknown";
    };
}
```

Enums must be handled completely, and a missing member is an error that names it:

```hx
function label(role: Role): string {
    return switch (role) {
        case Role.Admin: "admin";
        case Role.Member, Role.Guest: "user";
    };
}
```

```text
error: switch on `Role` doesn't handle every case
  = hint: missing Role.Guest (or add `default:`)
```

Struct patterns match the fields that they list, and strings match by their text:

```hx
function place(p: Point): string {
    return switch (p) {
        case { x: 0, y: 0 }: "origin";
        case { x: 0 }: "on the y-axis";            // unlisted fields match anything
        case { x, y } if x == y: "diagonal";
        default: "elsewhere";
    };
}

function method(name: string): u8 {
    return switch (name) {
        case "GET": 1;
        case "POST": 2;
        default: 0;
    };
}
```

| Switched on                    | Rule                       |
|--------------------------------|----------------------------|
| enum, union, error set, `bool` | every case must be handled |
| integer, string, struct        | needs `default`            |

Unions bind their payload in the case, as shown in [Structs, Enums, and Unions](/language/types#tagged-unions).
A bare name in a pattern is a new binding, so enum members are always written `Role.Admin` or `.Admin`.

## See also

- [Errors](/language/errors) for `defer` and `errdefer`
- [Optionals](/language/optionals)
- [Generics and Interfaces](/language/generics) for `dyn Iterator<T>`
