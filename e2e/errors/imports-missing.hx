// expect-error: cannot find module "./missing"
// expect-error: package "http" isn't in

import { ORIGIN_X } from "./missing";
import { Router } from "http";

export function main(): void {
    println(`${ORIGIN_X} ${Router}`);
}
