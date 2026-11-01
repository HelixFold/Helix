# Generics and Interfaces

This page covers generic functions and types, and interfaces with static and dynamic dispatch.

## Generic functions

```hx
function max<T extends Numeric>(a: T, b: T): T {
    return a > b ? a : b;
}

export function main(): void {
    println(`${max(3, 9)} ${max<f64>(2.5, 1.0)}`);     // 9 2.5
}
```

- Type parameters are inferred from the arguments, `max(3, 9)`, or given, `max<f64>(...)`.
- Each combination of type arguments compiles to its own code, so a generic costs nothing at run time.
- A constraint is `Numeric`, `Integer`, `Float`, or an interface (`T extends Shape`).
  An unconstrained `T` takes any type, and a body that doesn't work for the type given is reported where it is used:

```text
error: `+` doesn't work on `bool`
 --> app.hx:6:41
  = hint: use `&&`, `||` or `!` for booleans

note: while instantiating `add<bool>` here
  --> app.hx:10:13
```

## Generic types

Structs and unions take type parameters, and their methods are instantiated with them:

```hx
struct Pair<A, B> {
    first: A,
    second: B,

    swap(this: Pair<A, B>): Pair<B, A> {
        return Pair<B, A> { first: this.second, second: this.first };
    }
}

const pair = Pair<i32, string> { first: 1, second: "one" };
println(pair.swap());                   // { first: "one", second: 1 }
```

A method can have type parameters of its own, and each new combination compiles one more copy:

```hx
struct Box<T> {
    value: T,

    map<U>(this: Box<T>, f: (x: T) => U): Box<U> {
        return Box<U> { value: f(this.value) };
    }
}

function double(x: i32): i64 {
    return x * 2;
}

const box = Box<i32> { value: 21 };
println(box.map(double).value);         // 42, with U inferred as i64
```

Such a method can't be used as a value, fill an interface's slot, or be an iterator's `next`,
since each of those needs exactly one compiled function.

`ArrayList<T>` in `std/list` is an ordinary generic struct.

## Interfaces

An `interface` lists methods, and a type implements it by having them.
There is no `implements` clause, and `Self` is the implementing type:

```hx
interface Shape {
    area(this: readonly *Self): f64;
}

struct Square {
    side: f64,
    area(this: readonly *Square): f64 { return this.side * this.side; }
}

struct Circle {
    radius: f64,
    area(this: readonly *Circle): f64 { return 3.14159 * this.radius * this.radius; }
}
```

There are two ways to use one:

```hx
function staticArea<S extends Shape>(shape: *S): f64 {     // static: one copy per S
    return shape.area();
}

function total(shapes: readonly dyn Shape[]): f64 {         // dynamic: through a vtable
    let result: f64 = 0;
    for (const shape of shapes) result += shape.area();
    return result;
}

export function main(): void {
    let square = Square { side: 2 };
    let circle = Circle { radius: 1 };
    println(staticArea(&square));                           // 4
    const shapes: dyn Shape[2] = [&square, &circle];
    println(total(&shapes));                                // 7.14159
}
```

|                          | `<S extends Shape>`           | `dyn Shape`      |
|--------------------------|-------------------------------|------------------|
| Dispatch                 | static, inlined like any call | through a vtable |
| Code                     | one copy per type             | one copy         |
| Mixes types in one slice | no                            | yes              |

- A `dyn Shape` is two pointers, the value and its vtable, and it is made from a pointer (`&square`), never a copy.
- A method may promise more than the interface asks: `this: Self` or `this: readonly *Self` satisfy `this: *Self`.
- An interface is not a type of its own: `const s: Shape` is an error, so write `dyn Shape` or `<S extends Shape>`.

When a type doesn't fit, the error says what is missing:

```text
error: expected `dyn Shape`, found `*Quiet`
  = hint: `Quiet` has no method `area`; `Shape` asks for `area` as `(readonly *Quiet) => f64`
```

### Generic interfaces

Each type argument makes an interface of its own:

```hx
interface Iterator<T> {
    next(this: *Self): ?T;
}

function sum(it: dyn Iterator<i64>): i64 {
    let total: i64 = 0;
    for (const x of it) total += x;
    return total;
}

function count<T>(it: dyn Iterator<T>): usize {
    let n: usize = 0;
    while (it.next() != null) n++;
    return n;
}

struct Range {
    at: i64,
    end: i64,

    next(this: *Range): ?i64 {
        if (this.at == this.end) return null;
        this.at += 1;
        return this.at - 1;
    }
}

let range = Range { at: 1, end: 5 };
println(sum(&range));                   // 10
let more = Range { at: 0, end: 3 };
println(count<i64>(&more));             // 3
```

`T` is inferred when a `dyn Iterator<T>` is passed in, and is given when a pointer to an iterator is.
An interface method can't have type parameters of its own, since a vtable slot holds one compiled function.

## See also

- [Compile Time](/language/comptime) for `comptime` parameters
- [Memory](/language/memory) for the `Allocator` interface
- [Control Flow](/language/control-flow#iterators)
