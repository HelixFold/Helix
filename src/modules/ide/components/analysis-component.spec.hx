/**
 * Imports
 */

import { buffer } from "@modules/ide/components/json.component";
import { Pos } from "@modules/ide/components/structs/analysis-component.struct";
import { Compilation } from "@modules/driver/components/structs/compile-component.struct";
import { writeSymbols, writeTests, writeLenses } from "@modules/ide/components/analysis.component";
import { compileFront, compilationFree, setQuiet } from "@modules/driver/components/compile.component";
import { buildIndex, writeDiagnostics, writeSemanticTokens } from "@modules/ide/components/analysis.component";
import { allocCString, pid, tempDir, makeDirs, writeText, realPath } from "@modules/driver/components/os.component";
import { writeDefinition, writeHover, writeSummary, offsetOf, uriOf } from "@modules/ide/components/analysis.component";

/**
 * Tests
 */

let counter: u32 = 0;

/**
 * Writes a text to a new file and compiles it with the checker, ready for queries.
 *
 * @param name - The file name, which the counter prefixes so that every call gets its own file
 * @param text - The source text of the file
 * @returns The compilation of the file, with its index already built
 *
 * @remarks
 * The compilation runs quietly and ignores whether the front end succeeded,
 * so a spec can also query a file with errors.
 * The caller frees the result with `compilationFree`.
 *
 * @since 1.0.0
 */

function compiled(name: string, text: string): *Compilation {
    const dir = allocCString(`${tempDir()}/helix-analysis-spec-${pid()}`);
    void makeDirs(dir);
    counter += 1;
    const file = allocCString(`${dir}/${counter}-${name}`);
    void writeText(file, text);
    setQuiet(true);
    let ok = false;
    const c = compileFront(realPath(file) ?? file, true, false, null, &ok);
    buildIndex(c);

    return c;
}

/**
 * The path of module 0 of a compilation.
 *
 * @param c - The compilation to read
 * @returns The real path of the first module, which is the file that {@link compiled} wrote
 *
 * @remarks
 * Module 0 is the root file of the compilation, so this is the path that the queries under test expect.
 *
 * @since 1.0.0
 */

function pathOf(c: *Compilation): string {
    return c.realPaths.items[0];
}

describe("offsetOf") {
    test("should find the byte at a line and a character") {
        const c = compiled("a.hx", "const a = 1;\nconst bc = 2;\n");
        defer compilationFree(c);

        expect(offsetOf(c, 0, Pos { line: 1, character: 6 }) - offsetOf(c, 0, Pos { line: 0, character: 0 })).toBe(19);
    }

    test("should stop at the end of a line for a character past it") {
        const c = compiled("a.hx", "const a = 1;\nconst bc = 2;\n");
        defer compilationFree(c);

        expect(offsetOf(c, 0, Pos { line: 0, character: 99 }) - offsetOf(c, 0, Pos { line: 0, character: 0 })).toBe(12);
    }

    test("should count a character outside the BMP as two units") {
        const c = compiled("a.hx", "const s = \"😀x\";\n");
        defer compilationFree(c);
        const start = offsetOf(c, 0, Pos { line: 0, character: 0 });

        expect(offsetOf(c, 0, Pos { line: 0, character: 13 }) - start).toBe(15);
    }
}

describe("uriOf") {
    test("should prefix a plain path with file://") {
        expect(uriOf("/p/src/main.hx")).toBe("file:///p/src/main.hx");
    }

    test("should percent-encode a space and other bytes a URI cannot hold") {
        expect(uriOf("/my project/a+b.hx")).toBe("file:///my%20project/a%2Bb.hx");
    }

    test("should keep the unreserved characters") {
        expect(uriOf("/a-b_c.d~e")).toBe("file:///a-b_c.d~e");
    }
}

describe("buildIndex") {
    test("should let a query resolve a name to its declaration") {
        const c = compiled("a.hx", "const limit: i32 = 1;\nfunction f(): i32 { return limit; }\n");
        defer compilationFree(c);
        let b = buffer();
        writeDefinition(&b, c, offsetOf(c, 0, Pos { line: 1, character: 28 }));

        expect(b.text()).toInclude("\"range\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":11}}");
    }
}

describe("writeDiagnostics") {
    test("should list module 0 with no diagnostics when it checks") {
        const c = compiled("ok.hx", "const a: i32 = 1;\n");
        defer compilationFree(c);
        let b = buffer();
        writeDiagnostics(&b, c);

        expect(b.text()).toBe(allocCString(`[{"uri":"${uriOf(pathOf(c))}","diagnostics":[]}]`));
    }

    test("should write an error with its range and severity 1") {
        const c = compiled("bad.hx", "const a: i32 = missing;\n");
        defer compilationFree(c);
        let b = buffer();
        writeDiagnostics(&b, c);

        expect(b.text()).toInclude("{\"range\":{\"start\":{\"line\":0,\"character\":15},\"end\":{\"line\":0,\"character\":22}}");
        expect(b.text()).toInclude("\"severity\":1,\"source\":\"helix\",\"message\":");
        expect(b.text()).toInclude("missing");
    }
}

describe("writeSemanticTokens") {
    test("should color a const declaration, its type, and its value") {
        const c = compiled("a.hx", "const a: i32 = 1;\n");
        defer compilationFree(c);
        let b = buffer();
        writeSemanticTokens(&b, c);

        expect(b.text()).toBe("{\"data\":[0,0,5,12,0,0,6,1,7,3,0,3,3,1,4,0,6,1,15,0]}");
    }

    test("should color a doc comment as documentation") {
        const c = compiled("a.hx", "/** A. */\nconst a = 1;\n");
        defer compilationFree(c);
        let b = buffer();
        writeSemanticTokens(&b, c);

        expect(b.text()).toStartWith("{\"data\":[0,0,9,13,8,");
    }
}

describe("writeSymbols") {
    test("should outline a struct with its fields") {
        const c = compiled("a.hx", "struct Point { x: i32, y: i32 }\nfunction main(): void {}\n");
        defer compilationFree(c);
        let b = buffer();
        writeSymbols(&b, c);
        const text = b.text();

        expect(text).toStartWith("[{\"name\":\"Point\",\"kind\":23,");
        expect(text).toInclude("{\"name\":\"x\",\"kind\":8,");
        expect(text).toInclude("{\"name\":\"y\",\"kind\":8,");
        expect(text).toInclude("{\"name\":\"main\",\"kind\":12,");
    }

    test("should mark a const as a constant and a let as a variable") {
        const c = compiled("a.hx", "const a = 1;\nlet b: i32 = 2;\n");
        defer compilationFree(c);
        let b = buffer();
        writeSymbols(&b, c);

        expect(b.text()).toInclude("{\"name\":\"a\",\"kind\":14,");
        expect(b.text()).toInclude("{\"name\":\"b\",\"kind\":13,");
    }
}

describe("writeTests") {
    test("should nest a test inside its describe with the action that runs it") {
        const c = compiled("a.spec.hx", "describe(\"math\") {\n    test(\"should add\") {\n        expect(1 + 1).toBe(2);\n    }\n}\n");
        defer compilationFree(c);
        let b = buffer();
        writeTests(&b, c, "/p/a.spec.hx");
        const text = b.text();

        expect(text).toStartWith("{\"action\":{\"kind\":\"test\",\"title\":\"▶ Run tests\"");
        expect(text).toInclude("\"children\":[{\"name\":\"math\",\"kind\":\"describe\"");
        expect(text).toInclude("{\"name\":\"should add\",\"kind\":\"test\"");
        expect(text).toInclude("\"^math should add$\"");
    }
}

describe("writeLenses") {
    test("should offer run and debug on an exported main") {
        const c = compiled("a.hx", "export function main(): void {}\n");
        defer compilationFree(c);
        let b = buffer();
        writeLenses(&b, c, "/p/main.hx");
        const text = b.text();

        expect(text).toInclude("\"command\":{\"title\":\"▶ Run\",\"command\":\"helix.action\"");
        expect(text).toInclude("\"command\":{\"title\":\"Debug\",\"command\":\"helix.action\"");
    }

    test("should offer nothing for a main that is not exported") {
        const c = compiled("a.hx", "function main(): void {}\n");
        defer compilationFree(c);
        let b = buffer();
        writeLenses(&b, c, "/p/main.hx");

        expect(b.text()).toBe("[]");
    }
}

describe("writeDefinition") {
    test("should go to the field that a field access names") {
        const c = compiled("a.hx", "struct P { x: i32 }\nfunction f(p: P): i32 { return p.x; }\n");
        defer compilationFree(c);
        let b = buffer();
        writeDefinition(&b, c, offsetOf(c, 0, Pos { line: 1, character: 33 }));

        expect(b.text()).toInclude("\"range\":{\"start\":{\"line\":0,\"character\":11},\"end\":{\"line\":0,\"character\":12}}");
    }

    test("should write null where nothing is declared") {
        const c = compiled("a.hx", "const a = 1;\n");
        defer compilationFree(c);
        let b = buffer();
        writeDefinition(&b, c, offsetOf(c, 0, Pos { line: 0, character: 11 }));

        expect(b.text()).toBe("null");
    }
}

describe("writeHover") {
    test("should show a const with its type and its doc comment") {
        const c = compiled("a.hx", "/** The limit. */\nconst limit: i32 = 1;\n");
        defer compilationFree(c);
        let b = buffer();
        writeHover(&b, c, offsetOf(c, 0, Pos { line: 1, character: 7 }));

        expect(b.text()).toInclude("\"value\":\"```helix\\nconst limit: i32\\n```\\n\\nThe limit.\"");
    }

    test("should show the header of a function") {
        const c = compiled("a.hx", "export function add(a: i32, b: i32): i32 { return a + b; }\n");
        defer compilationFree(c);
        let b = buffer();
        writeHover(&b, c, offsetOf(c, 0, Pos { line: 0, character: 17 }));

        expect(b.text()).toInclude("```helix\\nexport function add(a: i32, b: i32): i32\\n```");
    }

    test("should write null on a number") {
        const c = compiled("a.hx", "const a = 1;\n");
        defer compilationFree(c);
        let b = buffer();
        writeHover(&b, c, offsetOf(c, 0, Pos { line: 0, character: 10 }));

        expect(b.text()).toBe("null");
    }
}

describe("writeSummary") {
    test("should write six sections separated by NUL, ending with the files read") {
        const c = compiled("a.hx", "const a = 1;\n");
        defer compilationFree(c);
        let b = buffer();
        writeSummary(&b, c, pathOf(c));
        const text = b.text();
        let nuls: u32 = 0;
        for (const ch of text) {
            if (ch == 0) nuls += 1;
        }

        expect(nuls).toBe(5);
        expect(text).toInclude(allocCString(`\x00${pathOf(c)}\n`));
    }
}
