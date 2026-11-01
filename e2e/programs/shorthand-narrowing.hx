// expect-stdout: x abc
// `{ sha }` reads `sha` as narrowed by the null check, like `{ sha: sha }` does.

struct Entry {
    name: string,
    sha: string,
}

function find(i: i32): ?string {
    return i > 0 ? "abc" : null;
}

export function main(): void {
    const name = "x";
    const sha = find(1);
    if (sha == null) return;
    const e = Entry { name, sha };
    println(`${e.name} ${e.sha}`);
}
