// expect-stdout: count 20, capacity 32, last 361
// expect-stdout: popped 361, now 19
// expect-stdout: trim [hello] starts true index 2
// expect-stdout: parse -1234 min -9223372036854775808
// expect-stdout: bad: InvalidDigit

import { ArrayList, cAllocator, trim, parseInt } from "std";
import * as text from "std/text";

export function main(): void | Error {
    const gpa = cAllocator();
    let list = ArrayList<i32>.init(gpa);
    defer list.deinit();

    for (const i of 0..20) try list.append((i * i) as i32);
    println(`count ${list.items.len}, capacity ${list.capacity}, last ${list.items[19]}`);
    println(`popped ${list.pop()}, now ${list.items.len}`);

    println(`trim [${trim("  hello  ")}] starts ${text.startsWith("helix", "he")} index ${text.indexOf("hello", "ll")}`);
    println(`parse ${try parseInt("-1234")} min ${try parseInt("-9223372036854775808")}`);
    const bad = parseInt("12x") catch (e) {
        println(`bad: ${e}`);
        return;
    };
    println(`unreachable ${bad}`);
}
