# Errors

Errors in Helix are values, returned like any other.
There are no exceptions and no unwinding, and every call that can fail is marked where it happens.

## Error sets and fallible functions

```hx
import { parseInt } from "std";

error PortError { Empty, OutOfRange }

function parsePort(text: string): u16 | Error {
    if (text.len == 0) throw PortError.Empty; // [!code highlight]
    const value = try parseInt(text); // [!code highlight]
    if (value < 1 || value > 65535) throw PortError.OutOfRange; // [!code highlight]
    return value as u16;
}
```

- `error PortError { ... }` declares an error set, and its members print by name.
- `T | Error` in a return type means the function can fail, with the error set inferred from its body.
  `T | PortError` names the set, which a public API should do.
- `throw` returns an error value. It is a visible `return`, not an exception.
- The `|` form is only for errors, and `?T | E` is an optional that can also fail.

## Handling an error

Every call that can fail takes a `try` or a `catch`, so no call can jump away unseen:

| Form                               | Does                                                                             |
|------------------------------------|----------------------------------------------------------------------------------|
| `try f()`                          | gives the value, or runs the pending defers and returns the error                |
| `f() catch 8080`                   | gives the value, or the fallback                                                 |
| `f() catch (e) { ... }`            | runs the block with the error                                                    |
| `f() catch (e) switch (e) { ... }` | handles each error on its own                                                    |
| `f() catch return`                 | a fallback that leaves instead, as `return`, `break`, `continue`, or `throw` can |

```hx
function portOrDefault(text: string): u16 {
    return parsePort(text) catch 8080;
}

function report(text: string): void {
    const port = parsePort(text) catch (e) {
        println(`can't read '${text}': ${e}`);      // can't read '70000': OutOfRange
        return;
    };
    println(`port ${port}`);
}

function describe(text: string): string {
    const port = parsePort(text) catch (e) switch (e) {
        case PortError.Empty: return "empty";
        default: return "bad";
    };
    return port == 80 ? "http" : "other";
}
```

To keep a result that may be an error without unwrapping it, leave out the `try`:

```hx
const kept: u16 | Error = parsePort("22");
println(try kept);                                  // 22
```

The compiler rejects an error that nobody handles:

```hx
function load(): void | Error {
    parsePort("80");                // the error is ignored // [!code --]
    const port = try parsePort("80"); // [!code ++]
    println(port); // [!code ++]
}
```

```text
error: the error from `f` is not handled
  = hint: pass it on with `try`, or handle it: `... catch (e) { ... }`
error: `try` passes errors on, but this function can't fail
  = hint: add errors to the return type, e.g. `: void | Error`, or handle it here with `catch`
```

## defer and errdefer

`defer` runs when its block exits, and `errdefer` runs only when the block exits with an error:

```hx
function steps(fail: bool): void | PortError {
    defer println("defer: always"); // [!code focus]
    errdefer println("errdefer: only on an error"); // [!code focus]
    errdefer (e) { // [!code focus:3]
        println(`errdefer saw ${e}`);
    }
    if (fail) throw PortError.Empty;
    println("done");
}
```

`steps(true)` prints:

```text
errdefer saw Empty
errdefer: only on an error
defer: always
```

::: tip 🧹 Pair each resource with its cleanup
Write the `defer` on the line after what it cleans up, so the two never drift apart.
:::

1. Defers belong to their block, `{ }`, and run when it exits, also on each pass of a loop.
2. They run last in, first out.
3. A defer can't leave its own block: `return`, `try`, or a `break` out of it is an error.
   Handle errors inside it instead: `defer file.flush() catch (e) eprintln(`${e}`);`.
4. Defers don't run on a panic.
5. The compiler copies the deferred code to each exit, so there is no bookkeeping at run time.

The usual pattern pairs each resource with its cleanup:

```hx
let list = ArrayList<i32>.init(allocator);
defer list.deinit();

const user = try create<User>(allocator);
errdefer destroy(allocator, user);              // only if a later step fails
```

## Errors at main

`main` may return errors.
One that reaches it prints `error: <name>` on stderr, and the program exits with status 1:

```hx
export function main(): void | Error {
    const port = try parsePort("");     // returns PortError.Empty from main // [!code warning]
    println(port);
}
```

```text
error: Empty
```

## See also

- [Optionals](/language/optionals)
- [Memory](/language/memory) for allocators
- [Testing](/projects/testing) for `toThrow`
