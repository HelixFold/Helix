// expect-stdout: find 2 none
// expect-stdout: fallback 5 7
// expect-stdout: narrowed 42
// expect-stdout: capture 10
// expect-stdout: email 8 none
// expect-stdout: countdown 3 2 1
// expect-stdout: early 5

extern "C" function printf(format: readonly u8[*], ...): i32;

struct User {
    name: string,
    email: ?string = null,
    boss: ?*User = null,
}

function find(values: readonly i32[], target: i32): ?usize {
    for (const v, i of values) {
        if (v == target) return i;
    }
    return null;
}

function show(index: ?usize): void {
    if (index != null) {
        void printf("%zu", index);
    } else {
        void printf("none");
    }
}

function next(counter: *u32): ?u32 {
    if (*counter == 0) return null;
    *counter -= 1;
    return *counter + 1;
}

function early(value: ?i32): i32 {
    if (value == null) return -1;
    return value;
}

export function main(): void {
    let values: i32[3] = undefined;
    values[0] = 5;
    values[1] = 6;
    values[2] = 7;

    void printf("find ");
    show(find(&values, 7));
    void printf(" ");
    show(find(&values, 9));
    void printf("\n");

    const missing: ?i32 = null;
    const present: ?i32 = 7;
    void printf("fallback %d %d\n", missing ?? 5, present ?? 5);

    const answer: ?i32 = 42;
    if (answer != null) void printf("narrowed %d\n", answer);

    if (const ten = find(&values, 5)) void printf("capture %zu\n", ten + 10);

    let boss = User { name: "grace", email: "g@hx.dev" };
    const ada = User { name: "ada", boss: &boss };
    const boss_mail = ada.boss?.email;
    void printf("email %zu %s\n", boss_mail != null ? boss_mail.len : 0, ada.email == null ? "none" : "set");

    let counter: u32 = 3;
    void printf("countdown");
    while (const n = next(&counter)) void printf(" %u", n);
    void printf("\n");

    void printf("early %d\n", early(5));
}
