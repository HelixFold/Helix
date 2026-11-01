// expect-stdout: green true
// expect-stdout: blue 4

// @enumFromInt: the enum value with a given number, e.g. one that came from C.
enum Color: u8 { Red = 1, Green = 2, Blue = 4 }

function name(c: Color): string {
    return switch (c) {
        case Color.Red: "red";
        case Color.Green: "green";
        case Color.Blue: "blue";
    };
}

export function main(): void {
    const n: u32 = 2;
    const c = @enumFromInt(Color, n);
    println(`${name(c)} ${c == Color.Green}`);
    const b = @enumFromInt(Color, 4);
    println(`${name(b)} ${b as u8}`);
}
