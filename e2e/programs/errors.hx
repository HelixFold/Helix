// expect-stdout: parsed 42
// expect-stdout: fallback 8080
// expect-stdout: empty -> 0
// expect-stdout: bad digit -> rethrown
// expect-stdout: cleanup: errdefer rollback
// expect-stdout: cleanup: defer close
// expect-stdout: transfer failed: Insufficient
// expect-stdout: cleanup: defer close
// expect-stdout: transfer ok 70

extern "C" function printf(format: readonly u8[*], ...): i32;

error ParseError { Empty, InvalidDigit }
error BankError { Insufficient }

function parse(text: string): u32 | ParseError {
    if (text.len == 0) throw ParseError.Empty;
    let value: u32 = 0;
    for (const c of text) {
        if (c < '0' || c > '9') throw ParseError.InvalidDigit;
        value = value * 10 + (c - '0');
    }
    return value;
}

function parseOr(text: string, fallback: u32): u32 {
    return parse(text) catch fallback;
}

function strict(text: string): u32 | Error {
    return parse(text) catch (e) switch (e) {
        case ParseError.Empty: 0;
        default: throw e;
    };
}

function withdraw(balance: *u32, amount: u32): void | BankError {
    defer void printf("cleanup: defer close\n");
    errdefer void printf("cleanup: errdefer rollback\n");
    if (amount > *balance) throw BankError.Insufficient;
    *balance -= amount;
}

function transfer(balance: *u32, amount: u32): void | Error {
    try withdraw(balance, amount);
}

export function main(): void | Error {
    void printf("parsed %u\n", try parse("42"));
    void printf("fallback %u\n", parseOr("80x", 8080));
    void printf("empty -> %u\n", try strict(""));
    const bad = strict("4x") catch 9999;
    void printf("bad digit -> %s\n", bad == 9999 ? "rethrown" : "parsed");

    let balance: u32 = 100;
    transfer(&balance, 500) catch (e) {
        void printf("transfer failed: %s\n", @errorName(e));
    };
    try transfer(&balance, 30);
    void printf("transfer ok %u\n", balance);
}
