// expect-stdout: hello from helix: 42

function add(a: i32, b: i32): i32 {
    return a + b;
}

export function main(): void {
    println(`hello from helix: ${add(40, 2)}`);
}
