/**
 * Imports
 */

import { strlen } from "std/c";
import { HxJson } from "@components/structs/json-component.struct";
import { hxJsonParse, hxJsonFree, hxJsonGet, hxJsonQuote } from "@components/json.component";
import { JsonNull, JsonBool, JsonNumber, JsonString, JsonArray, JsonObject } from "@constants/json.constant";

/**
 * Tests
 */

let errorBuf: u8[128] = undefined;
let quoteBuf: u8[64] = undefined;

/**
 * Returns a NUL-terminated string as a slice.
 *
 * @param text - The string to measure
 * @returns The bytes before the NUL
 *
 * @remarks
 * The slice shares the bytes of the string, so it lives only as long as they do.
 *
 * @since 1.0.0
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

/**
 * Parses a text that is expected to parse.
 *
 * @param text - The JSONC text to parse
 * @returns The parsed tree, which the caller frees with `hxJsonFree`
 *
 * @remarks
 * A parse failure prints the error and its offset to stderr instead of failing the test,
 * so the assertions that follow report what went wrong.
 *
 * @since 1.0.0
 */

function parse(text: string): HxJson {
    let out: HxJson = undefined;
    let at: u32 = 0;
    if (!hxJsonParse(text.ptr, text.len, &out, &errorBuf, errorBuf.len, &at)) {
        eprintln(`    error at ${at}: ${cString(&errorBuf)}`);
    }
    return out;
}

/**
 * The message and the offset of a parse failure.
 *
 * @remarks
 * The message points into the shared `errorBuf`, so the next parse overwrites it.
 *
 * @since 1.0.0
 */

struct Failure {
    message: string,
    at: u32,
}

/**
 * Returns the failure that parsing a text gives.
 *
 * @param text - The JSONC text to parse
 * @returns The message and the offset of the failure, or an empty message at offset 0 when the text parses
 *
 * @remarks
 * A text that parses is freed right away, so the specs can probe for errors without cleanup.
 *
 * @since 1.0.0
 */

function failure(text: string): Failure {
    let out: HxJson = undefined;
    let at: u32 = 0;
    if (hxJsonParse(text.ptr, text.len, &out, &errorBuf, errorBuf.len, &at)) {
        hxJsonFree(&out);
        return Failure { message: "", at: 0 };
    }
    return Failure { message: cString(&errorBuf), at };
}

/**
 * Returns the member of an object, which is expected to exist.
 *
 * @param json - The object to look in
 * @param key - The key to find, which must end with a NUL like a string literal does
 * @returns The value of the member
 *
 * @remarks
 * It unwraps the result of `hxJsonGet`, so a missing member stops the spec.
 *
 * @since 1.0.0
 */

function get(json: readonly *HxJson, key: string): readonly *HxJson {
    return hxJsonGet(json, key.ptr)!;
}

/**
 * Returns the element or the member value at an index.
 *
 * @param json - The array or the object to read
 * @param i - The index, which must be below the count
 * @returns The value at the index
 *
 * @remarks
 * It reads the items directly and does not check the index.
 *
 * @since 1.0.0
 */

function item(json: readonly *HxJson, i: u32): readonly *HxJson {
    unsafe {
        return &json.items![i];
    }
}

/**
 * Returns a text as a JSON string literal.
 *
 * @param text - The text to quote, which must end with a NUL like a string literal does
 * @returns The quoted text
 *
 * @remarks
 * The result points into the shared `quoteBuf`, which holds 64 bytes, so the next call overwrites it.
 *
 * @since 1.0.0
 */

function quote(text: string): string {
    hxJsonQuote(text.ptr, &quoteBuf, quoteBuf.len);
    return cString(&quoteBuf);
}

describe("hxJsonParse") {
    test("should read every kind of value") {
        let j = parse("{\"a\": 1.5, \"b\": [true, false, null], \"c\": \"x\"}");
        defer hxJsonFree(&j);

        expect(j.kind).toBe(JsonObject);
        expect(j.count).toBe(3);
        expect(get(&j, "a").kind).toBe(JsonNumber);
        expect(get(&j, "a").number).toBe(1.5);
        expect(get(&j, "b").kind).toBe(JsonArray);
        expect(item(get(&j, "b"), 0).boolean).toBe(true);
        expect(item(get(&j, "b"), 1).kind).toBe(JsonBool);
        expect(item(get(&j, "b"), 2).kind).toBe(JsonNull);
        expect(get(&j, "c").kind).toBe(JsonString);
    }

    test("should decode escapes and surrogate pairs") {
        let j = parse("\"x\\n\\u00e9\\ud83d\\ude00\\/\"");
        defer hxJsonFree(&j);

        expect(cString(j.string!)).toBe("x\n\u{E9}\u{1F600}/");
    }

    test("should read negative numbers and exponents") {
        let j = parse("[-2.5e3, 0]");
        defer hxJsonFree(&j);

        expect(item(&j, 0).number).toBe(-2500.0);
        expect(item(&j, 1).number).toBe(0.0);
    }

    test("should allow comments and trailing commas") {
        let j = parse("// a project\n{\n  /* the name */ \"name\": \"app\", // inline\n  \"list\": [1, 2,],\n}\n");
        defer hxJsonFree(&j);

        expect(cString(get(&j, "name").string!)).toBe("app");
        expect(get(&j, "list").count).toBe(2);
    }

    test("should keep the span of each value and key") {
        let j = parse("{ \"deps\": { \"a\": \"^1\" } }");
        defer hxJsonFree(&j);
        const deps = get(&j, "deps");

        expect(deps.start).toBe(10);
        expect(deps.end).toBe(23);
        unsafe {
            expect(deps.keyStarts![0]).toBe(12);
        }
        expect(item(deps, 0).start).toBe(17);
        expect(item(deps, 0).end).toBe(21);
    }

    test("should report each error at its offset") {
        const texts: string[9] = [
            "{\"a\": 1 \"b\": 2}", "{\"a\": 1, \"a\": 2}", "{'a': 1}", "[1, 2", "/* open", "{} x", "\"a\\qb\"",
            "\"a\nb\"", "",
        ];
        const messages: string[9] = [
            "expected `,` or `}`", "appears twice", "double quotes", "never closed", "never closed", "unexpected text",
            "unknown escape", "can't span lines", "expected a value",
        ];
        const offsets: u32[9] = [8, 9, 1, 0, 0, 3, 2, 0, 0];

        for (const text, i of texts) {
            const f = failure(text);
            expect(f.message).toInclude(messages[i]);
            expect(f.at).toBe(offsets[i]);
        }
    }

    test("should refuse arrays nested more than 256 deep") {
        let text: u8[300] = undefined;
        for (const i of 0..300) text[i] = '[';

        expect(failure(&text).message).toInclude("256 deep");
    }

    test("should leave an empty null value after a failure") {
        let out: HxJson = undefined;
        let at: u32 = 0;
        const text = "[1, 2";
        void hxJsonParse(text.ptr, text.len, &out, &errorBuf, errorBuf.len, &at);

        expect(out.kind).toBe(JsonNull);
        expect(out.count).toBe(0);
        expect(out.items).toBeNull();
    }
}

describe("hxJsonFree") {
    test("should leave the value without children") {
        let j = parse("[1, [2], {\"a\": \"b\"}]");
        hxJsonFree(&j);

        expect(j.count).toBe(0);
        expect(j.items).toBeNull();
    }

    test("should do nothing to a value released twice") {
        let j = parse("{\"a\": 1}");
        hxJsonFree(&j);
        hxJsonFree(&j);

        expect(j.keys).toBeNull();
    }
}

describe("hxJsonGet") {
    test("should find a member by its key") {
        let j = parse("{\"a\": 1, \"b\": 2}");
        defer hxJsonFree(&j);

        expect(get(&j, "b").number).toBe(2.0);
    }

    test("should return null for a missing key") {
        let j = parse("{\"a\": 1}");
        defer hxJsonFree(&j);

        expect(hxJsonGet(&j, "missing")).toBeNull();
    }

    test("should return null for a value that is not an object") {
        let j = parse("[1]");
        defer hxJsonFree(&j);

        expect(hxJsonGet(&j, "a")).toBeNull();
    }

    test("should return null for a null input, so that lookups chain") {
        let j = parse("{\"a\": 1}");
        defer hxJsonFree(&j);

        expect(hxJsonGet(hxJsonGet(&j, "x"), "y")).toBeNull();
    }
}

describe("hxJsonQuote") {
    test("should escape quotes, newlines and backslashes") {
        expect(quote("say \"hi\"\n\\")).toBe("\"say \\\"hi\\\"\\n\\\\\"");
    }

    test("should write other control characters as unicode escapes") {
        expect(quote("\x01")).toBe("\"\\u0001\"");
    }

    test("should cut a long text short and still close the literal") {
        const text = quote("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

        expect(text.len < 64).toBe(true);
        expect(text[text.len - 1]).toBe('"');
    }
}
