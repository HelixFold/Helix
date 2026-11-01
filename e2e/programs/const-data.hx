// Constant data: struct and array literals as global constants, and constant array literals as `readonly` slices.
// expect-stdout: origin 0 0
// expect-stdout: 4 primes, sum 17, folded 17
// expect-stdout: ada bob
// expect-stdout: app util ../util
// expect-stdout: 3 words, 2 numbers
// expect-stdout: [1, 2] []

struct Point {
    x: i32,
    y: i32,
}

struct Dep {
    name: string,
    path: ?string = null,
}

struct Manifest {
    name: string,
    deps: readonly Dep[] = [],
    tags: readonly string[] = [],
}

const origin: Point = { x: 0, y: 0 };
const primes: readonly i32[] = [2, 3, 5, 7];
const names: readonly string[] = ["ada", "bob"];
const manifest: Manifest = {
    name: "app",
    deps: [{ name: "util", path: "../util" }],
};

function sum(xs: readonly i32[]): i32 {
    let total: i32 = 0;
    for (const x of xs) total += x;
    return total;
}

function count(words: readonly string[]): usize {
    return words.len;
}

const folded = comptime sum(primes);

export function main(): void {
    println(`origin ${origin.x} ${origin.y}`);
    println(`${primes.len} primes, sum ${sum(primes)}, folded ${folded}`);
    println(`${names[0]} ${names[1]}`);
    println(`${manifest.name} ${manifest.deps[0].name} ${manifest.deps[0].path ?? "none"}`);
    println(`${count(["a", "b", "c"])} words, ${sum([1, 1]) } numbers`);
    const empty: readonly i32[] = [];
    const pair: readonly i32[] = [1, 2];
    println(`${pair} ${empty}`);
}
