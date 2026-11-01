// expect-error: indexing a raw `readonly u8[*]` pointer needs `unsafe { }`
// expect-error: a slice can't be passed to a C variadic function

extern "C" function printf(format: readonly u8[*], ...): i32;

export function main(): void {
    const text: string = "hi";
    const raw = text.ptr;
    void printf("%c\n", raw[0]);
    void printf("%s\n", text);
}
