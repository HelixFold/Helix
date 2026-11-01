// expect-error: `@ptrFromInt` needs `unsafe { }`
// expect-error: `@intFromPtr` takes a pointer, not `u32`
// expect-error: 3 isn't a value of `Color`
// expect-error: `@enumFromInt` makes an enum, not `u8`

export function main(): void {
    const p = @ptrFromInt(*u8, 64);
    const n: u32 = 1;
    const a = @intFromPtr(n);
}

enum Color: u8 { Red = 1, Green = 2 }

export function colors(): void {
    const c = @enumFromInt(Color, 3);
    const d = @enumFromInt(u8, 1);
}
