// expect-panic: config is missing a name

// Stops the program with `message` when `condition` is false, and at compile time in a `comptime` block.
function assert(condition: bool, message: string): void {
    if (!condition) @panic(message);
}

struct Config { name: string }

comptime {
    assert(@sizeOf(Config) == 2 * @sizeOf(usize), "Config must stay two words");
}

export function main(): void {
    const config = Config { name: "" };
    assert(config.name.len > 0, "config is missing a name");
}
