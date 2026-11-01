# Structs, Enums, and Unions

This page covers the types that a program defines: structs with methods, enums, and tagged unions.

## Structs

```hx
enum Role { Admin, Member, Guest }

struct User {
    id: u32,
    name: string,
    email: ?string = null,          // a field with a default
    role: Role = Role.Guest,

    rename(this: *User, name: string): void {
        this.name = name;
    }

    describe(this: readonly *User): void {
        println(`${this.name} <${this.email ?? "none"}> ${this.role}`);
    }

    guest(id: u32): User {
        return User { id, name: "guest" };
    }
}

export function main(): void {
    let ada = User { id: 1, name: "ada", role: Role.Admin };
    ada.rename("ada lovelace");
    ada.describe();                 // ada lovelace <none> Admin

    const guest = User.guest(2);
    println(guest);                 // { id: 2, name: "guest", email: null, role: Guest }
}
```

- A literal names the struct, `User { ... }`, or takes it from an annotation: `const b: User = { id: 2, name: "bob" };`.
- Fields without a default are required, and `{ id }` is short for `{ id: id }`.
- A default is evaluated each time a literal leaves its field out.
- There are no classes, constructors, inheritance, or destructors.
  `init` and `deinit` are ordinary functions that you call yourself, as `ArrayList` does.

### Methods

A method is written like a TypeScript class method, without `function`, and its first parameter is `this`.
The type of `this` says what the method may do to its receiver:

| Receiver               | Call it on       | Meaning                            |
|------------------------|------------------|------------------------------------|
| `this: User`           | any value        | gets a copy                        |
| `this: readonly *User` | any variable     | reads in place and can't change it |
| `this: *User`          | a `let` variable | changes it in place                |

`ada.rename("x")` is short for `User.rename(&ada, "x")`.
Calling a `*User` method on a `const` is an error: `` `rename` changes the `User`, but this value is constant ``.

A function without `this`, such as `guest`, is called on the type: `User.guest(2)`.

## Enums

```hx
enum Role { Admin, Member, Guest }
enum Color: u8 { Red = 1, Green = 2, Blue = 4 }     // a backing type and values of its own

const blue = Color.Blue as u8;                      // 4
```

Members are written with their type, `Role.Admin`.
When the type is already known, a leading dot is enough:

```hx
let user: User = { id: 3, name: "bob" };
user.role = .Member;                // Role, from the field's type
```

## Tagged unions

A union holds one of its variants and knows which.
A variant may carry a payload, a struct of its own, or nothing:

```hx
struct Point { x: i32, y: i32 }

union Event {
    click: Point,
    key: struct { code: u32, shift: bool },
    quit,
}

function handle(event: Event): void {
    switch (event) {
        case Event.click(p): println(`click at ${p.x}, ${p.y}`);
        case Event.key({ code, shift }): println(`key ${code} shift ${shift}`);
        case Event.quit: println("quit");
    }
}

export function main(): void {
    handle(Event.click(Point { x: 1, y: 2 }));      // click at 1, 2
    handle(Event.key({ code: 13, shift: false }));  // key 13 shift false
    handle(Event.quit);                             // quit
}
```

A `switch` on a union must handle every variant, and it binds the payload by name or destructures it.
`case Event.click(*p)` binds a pointer into the union instead, so changing `p` changes the original.
See [Control Flow](/language/control-flow#switch).

There are no untagged unions: the `|` form is only for [errors](/language/errors).

## Type aliases

```hx
type Id = u32;
type Handler = (event: Event) => void;
```

An alias is another name for the same type.

## See also

- [Control Flow](/language/control-flow)
- [Generics and Interfaces](/language/generics) for `struct Box<T>`
- [Memory](/language/memory)
