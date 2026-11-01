// expect-error: "../programs/modules/geometry" has no export named `secret`
// expect-error: "../programs/modules/geometry" has no export named `nothing`
// expect-error: unused import `Point`
// expect-error: `geo` has no export named `hidden`

import { secret, nothing, Point, reveal } from "../programs/modules/geometry";
import * as geo from "../programs/modules/geometry";

export function main(): void {
    println(`${reveal()} ${geo.hidden}`);
}
