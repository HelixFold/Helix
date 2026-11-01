// expect-error: the error from `parse` is not handled
// expect-error: `try` passes errors on, but this function can't fail
// expect-error: expected `ParseError`, found `IoError`
// expect-error: `void` discards values, not errors
// expect-error: this `catch` block must return, throw or panic
// expect-error: expected `u32`, found `u32 | ParseError`

error ParseError { Empty }
error IoError { Closed }

function parse(text: string): u32 | ParseError {
    if (text.len == 0) throw ParseError.Empty;
    return 1;
}

function strict(text: string): u32 | ParseError {
    if (text.len > 9) throw IoError.Closed;
    return try parse(text);
}

function total(): u32 {
    return try parse("1");
}

function direct(): u32 {
    return parse("2");
}

export function main(): void {
    parse("x");
    void parse("y");
    const n = parse("z") catch (e) {
        void e;
    };
    void n;
    void strict("1") catch 0;
    void total();
    void direct();
}
