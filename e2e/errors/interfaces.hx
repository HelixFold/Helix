// expect-error: interface method `make` needs a receiver
// expect-error: `Self` can only be the receiver's type
// expect-error: `dyn Writer` has no method `flush`
// expect-error: expected `dyn Writer`, found `*Quiet`
// expect-error: expected `dyn Writer`, found `*Wrong`
// expect-error: expected `dyn Writer`, found `Ok`
// expect-error: expected `dyn Writer`, found `readonly *Ok`
// expect-error: `Quiet` doesn't implement `Writer`
// expect-error: `Writer` is an interface, not a type
// expect-error: `Writer.write` is an interface method; call it on a value
// expect-error: expected `dyn Writer`, found `*i32`
// expect-error: `dyn` needs an interface, and `Ok` isn't one
// expect-error: unknown interface `Missing`

interface Writer {
    write(this: *Self, bytes: string): usize;
}

interface Bad {
    make(): i32;
    same(this: *Self, other: *Self): bool;
}

struct Quiet {}

struct Wrong {
    write(this: *Wrong, bytes: string): i32 {
        void bytes;
        return 0;
    }
}

struct Ok {
    count: usize,
    write(this: *Ok, bytes: string): usize {
        this.count = this.count + bytes.len;
        return bytes.len;
    }
}

function use(w: dyn Writer): void {
    void w.write("x");
    void w.flush();
}

function stat<W extends Writer>(w: *W): void {
    void w.write("y");
}

function notInterface(_a: dyn Ok, _b: dyn Missing): void {}

function main(): void {
    let q = Quiet {};
    let wr = Wrong {};
    let ok = Ok { count: 0 };
    const ro: readonly *Ok = &ok;
    use(&q);
    use(&wr);
    use(ok);
    use(ro);
    stat(&q);
    const x: Writer = undefined;
    void x;
    void Writer.write;
    let n: i32 = 1;
    use(&n);
}
