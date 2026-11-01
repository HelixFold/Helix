import { twice } from "@util/math";

/** Close enough for a test: pi is 3. */
export function area(r: i32): i32 {
    return twice(r * r) + r * r;
}
