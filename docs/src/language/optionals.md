# Optionals

A `?T` holds a `T` or `null`.
Only optionals can be null, and the compiler makes every use check for it.

## Reading an optional

```hx
struct User { name: string, email: ?string = null }

function find(id: u32): ?User {
    if (id == 1) return User { name: "ada", email: "ada@example.com" };
    if (id == 2) return User { name: "bob" };
    return null;
}

export function main(): void {
    const email = find(1)?.email;           // ?string: null when find gives null
    const shown = find(2)?.email ?? "none"; // "none"
    const len = email?.len;                 // ?usize: 15
    println(`${shown} ${len}`);             // none 15
    println(email!);                        // ada@example.com, or a panic on null
}
```

| Form                                  | Gives                                                    |
|---------------------------------------|----------------------------------------------------------|
| `x ?? fallback`                       | the value, or the fallback                               |
| `x?.field`, `x?.method()`             | an optional of the result, `null` when `x` is null       |
| `x!`                                  | the value, and a panic on null in debug and release-safe |
| `if (const v = x) { ... }`            | runs the block with the value                            |
| `while (const v = it.next()) { ... }` | loops while there is a value                             |

Using an optional as if it were the value is an error:

```text
error: `?string` might be null
  = hint: use `?.len` for an optional result, `!.len` if it can't be null, or check `!= null` first
```

## Narrowing

After a check for `null`, the value has the plain type, as in TypeScript:

```hx
function length(email: ?string): usize {
    if (email == null) return 0;
    return email.len;                       // a string after the early return
}

if (email != null) {
    println(email.len);                     // a string inside the block
}
```

`&&` and `?:` narrow too: `x != null && x.len > 0`.
Narrowing applies to values that can't change underneath it, parameters and `const`.
A `let` optional is read with `x!`, `x ?? fallback`, or a capture, `if (const v = x)`.

## Leaving instead of a fallback

`return`, `break`, `continue`, and `throw` never produce a value, so they fit after `??`, and after `catch` too:

```hx
function greet(id: u32): void {
    const user = find(id) ?? return;                        // nobody to greet
    println(`hello ${user.name}`);
}

function emailOf(id: u32): string | LookupError {
    const user = find(id) ?? throw LookupError.Missing;
    return user.email ?? "none";
}

for (const item of items) {
    const value = lookup(item) ?? break;                    // stop at the first miss
    println(value);
}
```

## Optional pointers

`?*User` is a pointer that may be null, and it is the only pointer that can be.
A plain `*User` always points at a `User`.
C pointers come into Helix as optionals, `?*T` and `?u8[*]` (see [C Interop](/language/c-interop)).

## See also

- [Errors](/language/errors)
- [Control Flow](/language/control-flow)
- [Memory](/language/memory)
