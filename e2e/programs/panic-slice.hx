// expect-panic: slice end is out of bounds

function head(text: string, n: usize): string {
    return text[0..n];
}

export function main(): u8 {
    return @truncate(u8, head("abc", 10).len);
}
