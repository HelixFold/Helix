# Word Count

`wc` counts the lines, words, and bytes of the files that it is given, or of stdin.
It reads the command line through `Init`, allocates through a `DebugAllocator`, and handles a file it can't read
with `catch`, then goes on with the next one.

```bash
helix build examples/wc.hx -o wc
./wc examples/hello.hx examples/wc.hx
echo "a b" | ./wc
```

```text
38	132	702	examples/hello.hx
130	509	3151	examples/wc.hx
168	641	3853	total
1	2	4
```

<<< @/../examples/wc.hx

## See also

- [Functions](/language/functions#main)
- [Memory](/language/memory#allocators)
- [Errors](/language/errors)
