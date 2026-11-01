// expect-stdout: total -42, name ada, pi 3.14159, third 0.3333333333333333, big 1099511627776, ok true
// expect-stdout: u8 255 i8 -128 u64 18446744073709551615 f32 1.5
// expect-stdout: role Admin, maybe null, some x, error Bad
// expect-stdout: { x: 1, y: 2.5, label: "p" }
// expect-stdout: rect({ x: 3, y: 4, label: "r" }) / empty / circle(0.5)
// expect-stdout: array [1, 2, 3] slice [2, 3] words ["a", "b"]
// expect-stdout: escaped `backtick` and ${braces} and \tab
// expect-stdout: no newline, then one

enum Role { Admin, Guest }
error Problem { Bad }

struct Point {
    x: i32,
    y: f64,
    label: string = "p",
}

union Shape {
    circle: f64,
    rect: Point,
    empty,
}

function third(): f64 {
    return 1.0 / 3.0;
}

export function main(): void {
    const n: i32 = -42;
    const name: string = "ada";
    println(`total ${n}, name ${name}, pi ${3.14159}, third ${third()}, big ${1 << 40}, ok ${n < 0}`);

    const a: u8 = 255;
    const b: i8 = -128;
    const c: u64 = 18446744073709551615;
    const d: f32 = 1.5;
    println(`u8 ${a} i8 ${b} u64 ${c} f32 ${d}`);

    const maybe: ?i32 = null;
    const some: ?string = "x";
    println(`role ${Role.Admin}, maybe ${maybe}, some ${some}, error ${Problem.Bad}`);

    println(Point { x: 1, y: 2.5 });
    println(`${Shape.rect({ x: 3, y: 4, label: "r" })} / ${Shape.empty} / ${Shape.circle(0.5)}`);

    let values: u16[3] = undefined;
    values[0] = 1;
    values[1] = 2;
    values[2] = 3;
    let words: string[2] = undefined;
    words[0] = "a";
    words[1] = "b";
    println(`array ${values} slice ${values[1..]} words ${words}`);

    println(`escaped \`backtick\` and \${braces} and \\tab`);
    print("no newline");
    println(", then one");
}
