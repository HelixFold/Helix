// expect-error: a `Format` can only be a parameter's type
// expect-error: a `Format` can only be a parameter's type
// expect-error: a `Format` can only be a parameter's type
// expect-error: `Format` has no method `render`
// expect-error: `writeTo` needs a writer, found `integer literal`
// expect-error: `void` discards values, not errors
// expect-error: a template string can only be passed to a `Format` parameter
// expect-error: a `Format` can only be a parameter's type

struct Holder { f: Format }

function keep(f: Format): Format { return f; }
function store(f: Format): void {
    const copy = f;
    void copy;
    void f.render();
    void f.writeTo(1);
}

function main(): void {
    const t = `x ${1}`;
    void t;
    store(`y`);
    let list: Format[2] = undefined;
    void list;
}
