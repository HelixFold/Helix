// expect-error: `main` takes nothing, or `init: Init`

struct Init { args: i32 }

export function main(_init: Init): void {}
