// expect-stdout: sum { x: 4, y: 6 } origin 0 created 2
// expect-stdout: twice 10 and 5
// expect-stdout: reveal 42
// expect-stdout: circle { center: { x: 1, y: 1 }, radius: 3 } Round
// expect-stdout: created now 3

import { Point, point, twice as double } from "./modules/geometry";
import * as geo from "./modules/geometry";
import { Circle, Kind, makePoint } from "./modules/shapes";

export function main(): void {
    const a: Point = point(1, 2);
    const b = geo.point(3, 4);
    println(`sum ${a.add(b)} origin ${geo.ORIGIN_X} created ${geo.created}`);
    println(`twice ${double(5)} and ${geo.twice(2.5)}`);
    println(`reveal ${geo.reveal()}`);
    const c = Circle { center: makePoint(1, 1), radius: 3 };
    println(`circle ${c} ${Kind.Round}`);
    println(`created now ${geo.created}`);
}
