# Shop

A small inventory that uses an enum, a struct with a method, a tagged union of orders, an error set, an optional, and
`switch` on each of them.

```bash
helix run examples/shop.hx
```

```text
bread is a Food, 6 left
  atlas (book): 2 in stock
  bread (food): 6 in stock
  chisel (tool): 4 in stock
revenue: 24
order refused: OutOfStock
```

<<< @/../examples/shop.hx

## See also

- [Structs, Enums, and Unions](/language/types)
- [Control Flow](/language/control-flow#switch)
- [Optionals](/language/optionals)
