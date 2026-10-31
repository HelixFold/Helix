/**
 * Imports
 */

import { ArrayList } from "./list";
import { ArenaAllocator } from "./heap";
import { writeJsonString } from "./json";
import { JsonError, JsonKind, JsonOptions, JsonProblem, JsonValue, LineCol, lineCol, parseJson } from "./json";

/**
 * Tests
 */

/**
 * A writer that collects every byte it receives in a list.
 *
 * @remarks
 * It lets the specs read back what {@link writeJsonString} wrote.
 * The list comes from `testing.allocator`, so each test releases it with `deinit` on `out`.
 *
 * @since 1.0.0
 */

struct BufferWriter {
    /**
     * The bytes written so far.
     *
     * @since 1.0.0
     */

    out: ArrayList<u8>,

    /**
     * Appends bytes to the list.
     *
     * @param this - The writer to append to
     * @param bytes - The bytes to append
     * @returns Nothing, or the error of the allocator
     *
     * @remarks
     * It appends one byte at a time, which keeps it simple at the cost of speed that the specs do not need.
     *
     * @since 1.0.0
     */

    write(this: *BufferWriter, bytes: readonly u8[]): void | Error {
        for (const b of bytes) try this.out.append(b);
    }

    /**
     * Returns the bytes written so far as a string.
     *
     * @param this - The writer to read
     * @returns The collected bytes
     *
     * @remarks
     * The string points into the list, so it lives until the list grows or the test releases it.
     *
     * @since 1.0.0
     */

    text(this: readonly *BufferWriter): string {
        return this.out.items;
    }
}

/**
 * Creates an empty problem record.
 *
 * @returns A problem with an empty message at offset 0
 *
 * @remarks
 * Each parse in the specs gets a fresh record, so a stale message never leaks into the next assertion.
 *
 * @since 1.0.0
 */

function noProblem(): JsonProblem {
    return JsonProblem { message: "", at: 0 };
}

/**
 * Builds a text of nested arrays.
 *
 * @param out - The bytes to fill, with an even length
 * @returns The filled bytes, with `[` in the first half and `]` in the second
 *
 * @remarks
 * The nesting depth is half the length, which lets the specs reach the limit of 256 levels.
 *
 * @since 1.0.0
 */

function nested(out: u8[]): string {
    for (const i of 0..out.len) out[i] = i < out.len / 2 ? '[' : ']';
    return out;
}

describe("JsonKind") {
    test("should tag each literal with its kind") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();

        expect((try parseJson(arena.allocator(), "null", JsonOptions {}, &problem)).kind).toBe(JsonKind.Null);
        expect((try parseJson(arena.allocator(), "false", JsonOptions {}, &problem)).kind).toBe(JsonKind.Bool);
        expect((try parseJson(arena.allocator(), "-1", JsonOptions {}, &problem)).kind).toBe(JsonKind.Number);
        expect((try parseJson(arena.allocator(), "\"\"", JsonOptions {}, &problem)).kind).toBe(JsonKind.String);
        expect((try parseJson(arena.allocator(), "[]", JsonOptions {}, &problem)).kind).toBe(JsonKind.Array);
        expect((try parseJson(arena.allocator(), "{}", JsonOptions {}, &problem)).kind).toBe(JsonKind.Object);
    }
}

describe("JsonValue") {
    test("should record where each value sits in the text") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();
        const text = "{\"name\": \"hx\"}";
        const doc = try parseJson(arena.allocator(), text, JsonOptions {}, &problem);
        const name = doc.get("name")!;

        expect(doc.start).toBe(0);
        expect(doc.end).toBe(14);
        expect(name.start).toBe(9);
        expect(name.end).toBe(13);
        expect(text[name.start..name.end]).toBe("\"hx\"");
    }

    test("should keep the names and the values of an object side by side") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();
        const doc = try parseJson(arena.allocator(), "{\"a\": 1, \"b\": true}", JsonOptions {}, &problem);

        expect(doc.keys.len).toBe(2);
        expect(doc.keys[1]).toBe("b");
        expect(doc.items[0].number).toBe(1.0);
        expect(doc.items[1].boolean).toBeTrue();
    }

    test("should leave the fields of other kinds empty") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();
        const doc: JsonValue = try parseJson(arena.allocator(), "true", JsonOptions {}, &problem);

        expect(doc.number).toBe(0.0);
        expect(doc.text).toBe("");
        expect(doc.items.len).toBe(0);
        expect(doc.keys.len).toBe(0);
    }

    describe("get") {
        test("should find a member by name") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            let problem = noProblem();
            const doc = try parseJson(arena.allocator(), "{\"a\": 1, \"b\": \"x\"}", JsonOptions {}, &problem);

            expect(doc.get("b")!.text).toBe("x");
        }

        test("should report null for a missing name") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            let problem = noProblem();
            const doc = try parseJson(arena.allocator(), "{\"a\": 1}", JsonOptions {}, &problem);

            expect(doc.get("b")).toBeNull();
        }

        test("should report null for a value that is not an object") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            let problem = noProblem();
            const doc = try parseJson(arena.allocator(), "[\"a\"]", JsonOptions {}, &problem);

            expect(doc.get("a")).toBeNull();
        }

        test("should find the first of two members with the same name") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            let problem = noProblem();
            const doc = try parseJson(arena.allocator(), "{\"a\": 1, \"a\": 2}", JsonOptions {}, &problem);

            expect(doc.keys.len).toBe(2);
            expect(doc.get("a")!.number).toBe(1.0);
        }
    }

    describe("string") {
        test("should hand back the text of a string") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            let problem = noProblem();
            const doc = try parseJson(arena.allocator(), "\"\"", JsonOptions {}, &problem);

            expect(doc.string()).toBe("");
        }

        test("should report null for a value that is not a string") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            let problem = noProblem();
            const doc = try parseJson(arena.allocator(), "1", JsonOptions {}, &problem);

            expect(doc.string()).toBeNull();
        }
    }
}

describe("JsonOptions") {
    test("should default to strict JSON") {
        const options = JsonOptions {};

        expect(options.comments).toBeFalse();
    }

    test("should accept comments and trailing commas when comments are on") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();
        const text = "// top\n{ /* a */ \"a\": [1, 2,], }\n// end";
        const doc = try parseJson(arena.allocator(), text, JsonOptions { comments: true }, &problem);

        expect(doc.get("a")!.items.len).toBe(2);
    }
}

describe("JsonProblem") {
    test("should keep its message and offset after a syntax error") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();
        const result = parseJson(arena.allocator(), "[1,]", JsonOptions {}, &problem);

        expect(result).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("trailing comma");
        expect(problem.at).toBe(3);
    }

    test("should stay untouched after a successful parse") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = JsonProblem { message: "unchanged", at: 7 };
        void try parseJson(arena.allocator(), "[1]", JsonOptions {}, &problem);

        expect(problem.message).toBe("unchanged");
        expect(problem.at).toBe(7);
    }
}

describe("JsonError") {
    test("should report nesting deeper than 256 levels as TooDeep") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();
        let bytes: u8[514] = undefined;
        const text = nested(&bytes);

        expect(parseJson(arena.allocator(), text, JsonOptions {}, &problem)).toThrow(JsonError.TooDeep);
        expect(problem.message).toBe("nested more than 256 deep");
        expect(problem.at).toBe(256);
    }

    test("should accept nesting of exactly 256 levels") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();
        let bytes: u8[512] = undefined;
        const text = nested(&bytes);

        expect(parseJson(arena.allocator(), text, JsonOptions {}, &problem)).toSucceed();
    }
}

describe("LineCol") {
    test("should hold a line and a column") {
        const where = LineCol { line: 2, col: 5 };

        expect(where.line).toBe(2);
        expect(where.col).toBe(5);
    }
}

describe("lineCol") {
    test("should place offset 0 at line 1, column 1") {
        const where = lineCol("abc", 0);

        expect(where.line).toBe(1);
        expect(where.col).toBe(1);
    }

    test("should start a new line after each line feed") {
        const where = lineCol("{\n  x\n}", 4);

        expect(where.line).toBe(2);
        expect(where.col).toBe(3);
    }

    test("should count the columns in bytes") {
        const where = lineCol("\xc3\xa9x", 2);

        expect(where.col).toBe(3);
    }

    test("should stop at the end of the text for an offset past it") {
        const where = lineCol("a\nb", 99);

        expect(where.line).toBe(2);
        expect(where.col).toBe(2);
    }
}

describe("parseJson") {
    test("should read the literals") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();

        expect((try parseJson(arena.allocator(), "true", JsonOptions {}, &problem)).boolean).toBeTrue();
        expect((try parseJson(arena.allocator(), " false ", JsonOptions {}, &problem)).boolean).toBeFalse();
    }

    test("should read numbers with a sign, a fraction, and an exponent") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();

        expect((try parseJson(arena.allocator(), "-12", JsonOptions {}, &problem)).number).toBe(-12.0);
        expect((try parseJson(arena.allocator(), "0.5", JsonOptions {}, &problem)).number).toBe(0.5);
        expect((try parseJson(arena.allocator(), "2.5e1", JsonOptions {}, &problem)).number).toBe(25.0);
        expect((try parseJson(arena.allocator(), "1E-2", JsonOptions {}, &problem)).number).toBeCloseTo(0.01);
    }

    test("should accept a leading zero that strict JSON forbids") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();

        expect((try parseJson(arena.allocator(), "01", JsonOptions {}, &problem)).number).toBe(1.0);
    }

    test("should reject a number without the digits it needs") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();

        expect(parseJson(arena.allocator(), "-", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("expected a digit");
        expect(parseJson(arena.allocator(), "1.", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("expected a digit after `.`");
        expect(parseJson(arena.allocator(), "1e+", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("expected a digit in the exponent");
    }

    test("should decode the escapes of a string") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();
        const text = "\"\\\"\\\\\\/\\n\\t\\r\\b\\f\"";
        const doc = try parseJson(arena.allocator(), text, JsonOptions {}, &problem);

        expect(doc.text).toBe("\"\\/\n\t\r\x08\x0C");
    }

    test("should write each unicode escape out as UTF-8") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();
        const text = "\"\\u0041\\u00e9\\u20AC\\ud83d\\ude00\"";
        const doc = try parseJson(arena.allocator(), text, JsonOptions {}, &problem);

        expect(doc.text).toBe("A\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80");
    }

    test("should write a lone high surrogate as three bytes of its own") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();
        const doc = try parseJson(arena.allocator(), "\"\\ud800x\"", JsonOptions {}, &problem);

        expect(doc.text).toBe("\xed\xa0\x80x");
    }

    test("should reject a broken string") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();

        expect(parseJson(arena.allocator(), "\"abc", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("unterminated string");
        expect(parseJson(arena.allocator(), "\"a\nb\"", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("a control character in a string must be escaped");
        expect(parseJson(arena.allocator(), "\"\\x\"", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("unknown escape in a string");
        expect(problem.at).toBe(2);
        expect(parseJson(arena.allocator(), "\"\\u12g4\"", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("expected 4 hex digits after `\\u`");
    }

    test("should read nested arrays and objects") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();
        const text = "{\"list\": [1, [2, {\"x\": null}]], \"empty\": {}}";
        const doc = try parseJson(arena.allocator(), text, JsonOptions {}, &problem);
        const list = doc.get("list")!;

        expect(list.items.len).toBe(2);
        expect(list.items[1].items[1].get("x")!.kind).toBe(JsonKind.Null);
        expect(doc.get("empty")!.keys.len).toBe(0);
    }

    test("should reject comments in strict JSON") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();

        expect(parseJson(arena.allocator(), "// x\n1", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("JSON has no comments (`{ comments: true }` reads JSONC)");
        expect(problem.at).toBe(0);
    }

    test("should reject a block comment that never closes") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();

        expect(parseJson(arena.allocator(), "1 /* x", JsonOptions { comments: true }, &problem))
            .toThrow(JsonError.Syntax);
        expect(problem.message).toBe("unterminated comment");
    }

    test("should reject a missing separator") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();

        expect(parseJson(arena.allocator(), "[1 2]", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("expected `,` or `]`");
        expect(parseJson(arena.allocator(), "{\"a\": 1 \"b\": 2}", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("expected `,` or `}`");
    }

    test("should reject a malformed member") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();

        expect(parseJson(arena.allocator(), "{a: 1}", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("expected a member name in quotes");
        expect(parseJson(arena.allocator(), "{\"a\" 1}", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("expected `:` after the member name");
    }

    test("should reject a text without a value") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();

        expect(parseJson(arena.allocator(), "  ", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("expected a value, found the end");
        expect(parseJson(arena.allocator(), "nul", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("expected a value");
    }

    test("should reject anything after the value") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();

        expect(parseJson(arena.allocator(), "1 2", JsonOptions {}, &problem)).toThrow(JsonError.Syntax);
        expect(problem.message).toBe("expected the end after the value");
        expect(problem.at).toBe(2);
    }
}

describe("writeJsonString") {
    test("should wrap plain text in quotes") {
        let w = BufferWriter { out: ArrayList<u8>.init(testing.allocator) };
        defer w.out.deinit();
        try writeJsonString(&w, "hello");

        expect(w.text()).toBe("\"hello\"");
    }

    test("should escape quotes, backslashes, and the common control bytes") {
        let w = BufferWriter { out: ArrayList<u8>.init(testing.allocator) };
        defer w.out.deinit();
        try writeJsonString(&w, "a\"b\\c\nd\te\r");

        expect(w.text()).toBe("\"a\\\"b\\\\c\\nd\\te\\r\"");
    }

    test("should write other control bytes as unicode escapes") {
        let w = BufferWriter { out: ArrayList<u8>.init(testing.allocator) };
        defer w.out.deinit();
        try writeJsonString(&w, "\x01\x1f");

        expect(w.text()).toBe("\"\\u0001\\u001f\"");
    }

    test("should pass UTF-8 and the slash through unchanged") {
        let w = BufferWriter { out: ArrayList<u8>.init(testing.allocator) };
        defer w.out.deinit();
        try writeJsonString(&w, "\xc3\xa9/");

        expect(w.text()).toBe("\"\xc3\xa9/\"");
    }

    test("should write an empty string as two quotes") {
        let w = BufferWriter { out: ArrayList<u8>.init(testing.allocator) };
        defer w.out.deinit();
        try writeJsonString(&w, "");

        expect(w.text()).toBe("\"\"");
    }

    test("should write text that parses back to itself") {
        let arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        let problem = noProblem();
        let w = BufferWriter { out: ArrayList<u8>.init(testing.allocator) };
        defer w.out.deinit();
        try writeJsonString(&w, "tab\there \"quoted\" \x02");
        const doc = try parseJson(arena.allocator(), w.text(), JsonOptions {}, &problem);

        expect(doc.text).toBe("tab\there \"quoted\" \x02");
    }
}
