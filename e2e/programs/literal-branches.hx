// expect-stdout: 0 1 -1 5

// Literal branches picked at runtime take the type they're converted to, also inside arithmetic.
import { Init } from "std";

export function main(init: Init): void {
    const yes = init.args.len == 0;
    const no = !yes;
    const same: i32 = (yes ? 1 : 0) - (yes ? 1 : 0);
    const one: i32 = (yes ? 1 : 0) - (no ? 1 : 0);
    const minus: i64 = -(yes ? 1 : 0);
    const sum: u8 = (yes ? 2 : 0) + (yes ? 3 : 1);
    println(`${same} ${one} ${minus} ${sum}`);
}
