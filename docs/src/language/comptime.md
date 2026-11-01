# Compile Time

`comptime` runs ordinary Helix while compiling, and builds the result into the program.
Tables, sizes, and checks that are known in advance then cost nothing at run time.

## comptime expressions

```hx
function buildSquares(): u32[8] {
    let table: u32[8] = undefined;
    for (const i of 0..8) table[i] = (i * i) as u32;
    return table;
}

const Squares = comptime buildSquares();    // computed by the compiler, stored as a constant // [!code highlight]

export function main(): void {
    println(Squares);                       // [0, 1, 4, 9, 16, 25, 36, 49]
}
```

`buildSquares` is a normal function, and the same code would run at run time too.
A global whose value comes from a call must say `comptime`, since Helix runs no code before `main`.

## comptime blocks

A `comptime { }` block runs at every build, so it suits checks that must always hold:

```hx
struct Header { magic: u32, length: u32, flags: u64 }

comptime {
    if (@sizeOf(Header) != 16) @compileError("Header must be 16 bytes");
}
```

## comptime parameters

A `comptime` parameter makes one copy of the function per value, and the value can size an array:

```hx
function repeat(comptime n: usize, text: string): void {
    for (const _ of 0..n) print(text);
    println("");
}

function zeros<T>(comptime n: usize): T[n] {
    let items: T[n] = undefined;
    for (const i of 0..n) items[i] = 0;
    return items;
}

repeat(3, "ab");                    // ababab, from the copy repeat<3>
println(zeros<u8>(4));              // [0, 0, 0, 0]
```

An argument that isn't known while compiling is an error.
`comptime` parameters work on functions and on methods alike.

## What the evaluator runs

It runs checked code:
arithmetic, comparisons, `if`, `while`, `for`, `switch`, locals, arrays, slices, structs, optionals, errors (`try`,
`catch`, `throw`), `defer`, method calls, recursion, function values, and pointers to locals.

- Whatever would panic at run time is a compile error at the line that caused it, with a note at the `comptime` that
  started the evaluation:

```hx
function divide(a: i32, b: i32): i32 {
    return a / b;                           // b is 0 here // [!code error]
}

const Bad = comptime divide(1, 0);          // the evaluation starts here // [!code warning]
```

```text
error: division by zero at compile time
 --> app.hx:2:12
  |
2 |     return a / b;
  |            ^~~~~

note: while evaluating this at compile time
 --> app.hx:4:22
  |
4 | const Bad = comptime divide(1, 0);
```

- Results can be numbers, strings, arrays, structs, and optionals.
  Pointers work during the evaluation but can't be part of the result.
- It can't call C, print, use `dyn` or unions, or read a global `let`.
- Evaluation stops after 1,000,000 loop passes and calls.

## @compileError and @compileLog

`@compileError("message")` fails the build when the code it's in is used.
In a `comptime` block that means when the evaluation reaches it.
Elsewhere it means when its function is reachable from `main`, the tests, or a function C can call.
A branch ruled out while compiling doesn't count, so a check can depend on a type:

```hx
function small<T>(x: T): T {
    if (@sizeOf(T) > 8) @compileError("small() takes types of at most 8 bytes");
    return x;
}
```

`small<i32>` compiles, and `small` of a 16-byte struct fails with that message.

::: warning 🪵 Debugging only
`@compileLog(a, T, ...)` prints values known while compiling, and the types of the rest, and stops the build so it
is never left in by mistake:
:::

```text
error: compile log: i32 = i32, 2 + 3 = 5
```

## Per-target code

The compiler writes `std/target` for each build, so a program can branch on what it is built for:

```hx
import { target, Os } from "std/target";

if (comptime target.os == Os.Macos) {
    println("macOS");
} else {
    println("not macOS");
}
```

| Field                | Values                                                                                    |
|----------------------|-------------------------------------------------------------------------------------------|
| `target.os`          | `Os.Macos`, `Os.Linux`, `Os.Windows`, `Os.Wasi`, `Os.Freestanding`                        |
| `target.arch`        | `Arch.X86_64`, `Arch.Aarch64`, `Arch.Arm64e`, `Arch.Riscv64`, `Arch.Wasm32`, `Arch.Thumb` |
| `target.pointerBits` | `64`, or `32` on wasm32                                                                   |

A condition known while compiling keeps only the branch taken: the other is still checked, but never compiled or
linked, so one file can call each platform's functions.

## Builtins

| Builtin                                      | Gives                                                        |
|----------------------------------------------|--------------------------------------------------------------|
| `@sizeOf(T)`, `@alignOf(T)`                  | the size and alignment of a type, in bytes                   |
| `@truncate(T, x)`                            | the low bits of `x` as a `T`                                 |
| `@panic(message)`                            | stops the program with a message                             |
| `@compileError(message)`, `@compileLog(...)` | as above                                                     |
| `@errorName(e)`                              | an error's name, as a C string                               |
| `@ptrCast(T, p)`                             | `p` reinterpreted as a `T`, only inside `unsafe`             |
| `@ptrFromInt(T, n)`, `@intFromPtr(p)`        | an address as a pointer, and back                            |
| `@volatileLoad(p)`, `@volatileStore(p, v)`   | reads and writes that the optimizer keeps exactly as written |

## See also

- [Generics and Interfaces](/language/generics)
- [Targets](/projects/targets)
- [Safety](/language/safety)
