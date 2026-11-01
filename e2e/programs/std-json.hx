// expect-stdout: name hélix version 15 tags 4
// expect-stdout: kinds true true span 1.5e1
// expect-stdout: JSON has no comments (`{ comments: true }` reads JSONC) at 2:3
// expect-stdout: expected `,` or `]` at 1:6
// expect-stdout: expected `:` after the member name at 1:6
// expect-stdout: "say \"hi\"\n\u0001"

import { Allocator, ArenaAllocator, cAllocator, stdout } from "std";
import { parseJson, JsonOptions, JsonProblem, JsonKind, lineCol, writeJsonString } from "std/json";

/** The problem parsing `text`, or "ok". */
function check(a: dyn Allocator, text: string, comments: bool): void {
    let problem = JsonProblem { message: "", at: 0 };
    void (parseJson(a, text, JsonOptions { comments }, &problem) catch {
        const at = lineCol(text, problem.at);
        println(`${problem.message} at ${at.line}:${at.col}`);
        return;
    });
    println("ok");
}

function main(): void | Error {
    let arena = ArenaAllocator.init(cAllocator());
    defer arena.deinit();
    const a = arena.allocator();
    const text = "{\n  // a comment\n  \"name\": \"h\\u00e9lix\",\n  \"version\": 1.5e1,\n  \"tags\": [\"a\", true, null, -2],\n  \"nested\": { \"deep\": [[]] },\n}\n";
    let problem = JsonProblem { message: "", at: 0 };
    const doc = try parseJson(a, text, JsonOptions { comments: true }, &problem);
    const tags = doc.get("tags") ?? return;
    const version = doc.get("version") ?? return;
    println(`name ${doc.get("name")?.text ?? "?"} version ${version.number} tags ${tags.items.len}`);
    println(`kinds ${tags.items[1].kind == JsonKind.Bool} ${tags.items[2].kind == JsonKind.Null} span ${text[version.start..version.end]}`);
    check(a, text, false);
    check(a, "[1, 2", false);
    check(a, "{\"a\" 1}", false);
    try writeJsonString(stdout(), "say \"hi\"\n\x01");
    println("");
}
