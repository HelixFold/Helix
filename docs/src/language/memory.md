# Memory

This page covers arrays, slices, pointers, and allocators.
Helix never allocates on its own: code that needs memory takes an allocator, so every allocation is visible.

## Arrays and slices

```hx
function sum(values: readonly i32[]): i32 {
    let total: i32 = 0;
    for (const v of values) total += v;
    return total;
}

export function main(): void {
    let numbers: i32[5] = [1, 2, 3, 4, 5];
    numbers[0] = 10;
    const middle = numbers[1..4];               // a slice of the array: [2, 3, 4]
    println(`${numbers.len} ${middle} ${sum(&numbers)} ${sum(middle)}`);    // 5 [2, 3, 4] 24 9
}
```

| Type            | What it is                                                                        |
|-----------------|-----------------------------------------------------------------------------------|
| `u8[4]`         | an array: its length is known while compiling, and it is stored inline            |
| `u8[]`          | a slice: a pointer and a length, checked on every index, and it never owns memory |
| `readonly u8[]` | a slice that can't change what it points at                                       |
| `string`        | `readonly u8[]`                                                                   |
| `f32[3][4]`     | 3 rows of 4, indexed in the same order: `grid[2][3]`                              |

- `&array` gives a slice of an array, and `a[i..j]` slices an array or a slice, leaving out `j`.
- `.len` is the length, and `.ptr` the pointer, of a slice.
- Postfix binds tighter than prefix: `?u8[]` is an optional slice, and `(?u8)[]` a slice of optionals.
- A `readonly` slice can take an array literal of constants, which then lives in the binary like a string's bytes:
  `const keywords: readonly string[] = ["if", "else", "while"];`.

## Pointers

| Type             | What it is                                               |
|------------------|----------------------------------------------------------|
| `*User`          | a pointer to one `User`, never null                      |
| `readonly *User` | a pointer that can't change the `User`                   |
| `?*User`         | a pointer that may be null                               |
| `u8[*]`          | a raw pointer to many, for C: indexing it needs `unsafe` |

`&x` takes an address and `*p` reads through a pointer.
Fields need no `*`: `user.name` works on a `*User`.

The compiler rejects a pointer that would outlive its target:

```hx
function bad(): *i32 {
    let local: i32 = 1;
    return &local;                          // gone when bad returns // [!code error]
}
```

```text
error: this points into `local`, a local that's gone once the function returns
  = hint: return the value itself, or allocate it (`create<T>(allocator)`) and return that pointer
```

The compiler also rejects reading a variable before it has a value:

```hx
let n: i32 = undefined;
println(n);                                 // nothing gave n a value // [!code error]
```

The check follows whole values, such as numbers, pointers, slices, and optionals.
An assignment, `&n`, or a method that takes `*this` gives `n` its value, and after an `if` or a `switch` every branch
that goes on must have given it one.
Arrays, structs, and unions are filled piece by piece, so for them debug builds fill `undefined` memory with `0xAA`
instead.

Raw pointers are only indexed inside `unsafe { }`, which keeps every unchecked access easy to find.
See [C Interop](/language/c-interop#unsafe).

## Allocators

`Allocator` is an interface in `std/heap`, and code that allocates takes a `dyn Allocator`:

```hx
import { ArrayList, Allocator, DebugAllocator, cAllocator, alloc, free, create, destroy } from "std";

struct User { id: u32, name: string }

function makeUser(a: dyn Allocator, id: u32): *User | Error {
    const user = try create<User>(a);
    user.id = id;
    user.name = "ada";
    return user;
}

export function main(): void | Error {
    let debug = DebugAllocator.init(cAllocator());  // checks every free, and reports leaks // [!code focus]
    defer void debug.deinit(); // [!code focus]
    const a = debug.allocator(); // [!code focus]

    let list = ArrayList<i32>.init(a);
    defer list.deinit();
    for (const i of 0..5) try list.append((i * i) as i32);
    println(`squares ${list.items}`);               // squares [0, 1, 4, 9, 16]

    const ids = try alloc<u32>(a, 3);               // a u32[] of 3
    defer free(a, ids);

    const user = try makeUser(a, 1);
    defer destroy(a, user);
}
```

| Allocator                      | Use it for                                                           |
|--------------------------------|----------------------------------------------------------------------|
| `cAllocator()`                 | the C heap: `malloc` and `free`                                      |
| `ArenaAllocator.init(backing)` | memory that all dies together, freed at once by `deinit`             |
| `DebugAllocator.init(backing)` | development: catches bad frees, use after free, and leaks            |
| `testing.allocator`            | specs: a `DebugAllocator` for each test, where a leak fails the test |

| Function                 | Does                                   |
|--------------------------|----------------------------------------|
| `alloc<T>(a, n)`         | a new `T[]` of `n` items               |
| `resize<T>(a, items, n)` | the same items, grown or shrunk to `n` |
| `free<T>(a, items)`      | gives a slice back                     |
| `create<T>(a)`           | a new `*T`                             |
| `destroy<T>(a, item)`    | gives a `*T` back                      |

`DebugAllocator` panics on a double free or a free of the wrong size, fills new memory with `0xAA`, and stops a use
after free or an overrun at the access that does it, on macOS and Linux.
`DebugAllocator.initUnguarded(backing)` keeps the other checks without the page guards, for programs with very many
live allocations.
`deinit()` prints each leak and returns how many there were:

```text
leak: 16 bytes were never freed
```

::: danger 💥 Release builds
`release-fast` and `release-small` remove the bounds checks, so an index past the end is undefined behavior there.
Build code that handles untrusted input in `release-safe`.
See [Safety](/language/safety#modes).
:::

An arena suits work whose memory all dies at once, such as a request or a parse:

```hx
let arena = ArenaAllocator.init(cAllocator());
defer arena.deinit();
const scratch = try alloc<u8>(arena.allocator(), 100);     // freed by deinit
```

A new allocator is any struct with `rawAlloc`, `rawResize`, and `rawFree` methods.

## See also

- [Generics and Interfaces](/language/generics) for `dyn`
- [Safety](/language/safety)
- [Standard Library](/reference/std#std-heap)
