# Basics

This page covers bindings, the built-in types, printing, casts, and the operators.

## A complete example

```hx
const MaxUsers: usize = 1024;          // a constant, known while compiling
const KiB = 1024;                      // an untyped number until it meets a type

export function main(): void {
    let count: i32 = 0;                // mutable, with a type
    count += 1;
    const name = "ada";                // immutable, its type inferred as string
    let buffer: u8[4] = undefined;     // explicitly uninitialized
    buffer[0] = 'h';

    println(`${name} ${count} ${MaxUsers} ${KiB * 2}`);       // ada 1 1024 2048
    println(`${buffer[0]} ${0xff} ${0b1010} ${1_000_000}`);   // 104 255 10 1000000
}
```

## Bindings

| Form                            | Meaning                                                      |
|---------------------------------|--------------------------------------------------------------|
| `const x = 1;`                  | immutable                                                    |
| `let x: i32 = 0;`               | mutable, and it must change somewhere, or use `const`        |
| `let buf: u8[256] = undefined;` | explicitly uninitialized, filled with `0xAA` in debug builds |
| `void compute();`               | calls `compute` and drops its result on purpose              |

There is no `var`.
A global's value must be known while compiling, since Helix runs no code before `main`.
Literals, and struct and array literals of constants, qualify on their own, and anything that calls a function says so
with `comptime f()` (see [Compile Time](/language/comptime)).

## Types

| Kind              | Types                                                              |
|-------------------|--------------------------------------------------------------------|
| Signed integers   | `i8` `i16` `i32` `i64` `i128` `isize`, and any width such as `i24` |
| Unsigned integers | `u8` `u16` `u32` `u64` `u128` `usize`, and any width such as `u3`  |
| Floats            | `f16` `f32` `f64`                                                  |
| Others            | `bool` `void` `noreturn` `type`                                    |
| Text              | `string`, which is `readonly u8[]`                                 |

`usize` and `isize` are as wide as a pointer on the target: 64 bits on x86_64 and aarch64, 32 on wasm32.
Lengths and indexes are `usize`.

Arrays, slices, and pointers are covered in [Memory](/language/memory).
Optionals (`?T`) and errors (`T | Error`) have pages of their own.

## Printing

`print`, `println`, `eprint`, and `eprintln` are built in.
The last two write to stderr, and each takes one template string or one value:

```hx
println(`total ${n}, average ${sum / count}`);
println(point);                 // { x: 1, y: 2 }
eprintln(`warning: ${e}`);      // an error prints its name
```

| Type             | Prints                                     |
|------------------|--------------------------------------------|
| integers, `bool` | `42`, `-7`, `true`                         |
| floats           | the shortest exact form: `0.1`, `2.5`, `3` |
| `string`         | the text                                   |
| enums, errors    | the member's name: `Admin`, `NotFound`     |
| optionals        | the value, or `null`                       |
| structs          | `{ x: 1, name: "ada" }`                    |
| unions           | `click({ x: 1, y: 2 })`, `quit`            |
| arrays, slices   | `[1, 2, 3]`                                |
| pointers         | the address: `0x16fdfd5f0`                 |

A template string is only allowed where a parameter takes a `Format`, such as `println` or `fmt.alloc`, so a template
never allocates on its own.
See [`std/fmt`](/reference/std#std-fmt).

## Casts

```hx
const big: i32 = 300;
const small = big as u16;              // checked: panics in safe modes when it doesn't fit
const low = @truncate(u8, big);        // keeps the low 8 bits: 44
const wide: i64 = big;                 // widening needs no cast
```

Implicit widening (`u8` to `u32`, `f32` to `f64`) is allowed.
Narrowing, sign changes, and conversions between integers and floats always take an `as`.

## Operators

| Kind | Operators |
|------|-----------|
| Arithmetic | `+ - * / %`, overflow-checked in safe modes |
| Wrapping | `+% -% *%` |
| Saturating | `+\| -\| *\|` |
| Compare | `== != < <= > >=` |
| Logic | `&& \|\| !` |
| Bitwise | `& \| ^ ~ << >>` |
| Optional | `??`, `?.`, and the postfix unwrap `!` |
| Pointer | `&x` takes an address, `*p` dereferences, and `p.field` dereferences by itself |
| Ternary | `cond ? a : b` |
| Increment | `i++` and `i--`, as statements only |

```hx
const max: u8 = 255;
println(`${max +% 1} ${max +| 1}`);                 // 0 255
println(`${(0b1100 & 0b1010) == 0b1000}`);          // true
```

- There is only `==`, and `===` is an error with a fix-it, since no implicit coercion happens.
- An operator never calls user code, so there is no operator overloading.
- Assignment is a statement, so `if (x = 5)` cannot happen.
- Bitwise operators bind tighter than comparisons, so `flags & Mask == 0` means `(flags & Mask) == 0`, unlike C.
- Comparisons do not chain: `a < b < c` is an error.

## Rules the compiler enforces

These never compile:

| Rule                           | Example                                    | Error                             |
|--------------------------------|--------------------------------------------|-----------------------------------|
| No unused locals or parameters | `const temp = 5;` never read               | unused local `temp`               |
| No ignored results             | `compute();`                               | the result of `compute` is unused |
| No truthiness                  | `if (count)`                               | expected `bool`, found `i32`      |
| No implicit narrowing          | `const b: u8 = count;`                     | expected `u8`, found `i32`        |
| `let` must change              | `let n: i32 = 1;`, never assigned          | `n` is never reassigned           |
| No shadowing                   | `const x` declared again in a nested block | `x` is already declared           |
| No dead code                   | a statement after `return`                 | unreachable code                  |

A name that starts with `_` is exempt from the unused checks: `function f(_reserved: i32)`.
Each error comes with a hint:

```text
error: the result of `compute` is unused
  = hint: use it, or discard it on purpose: `void compute(...);`
```

## See also

- [Functions](/language/functions)
- [Memory](/language/memory)
- [Safety](/language/safety)
