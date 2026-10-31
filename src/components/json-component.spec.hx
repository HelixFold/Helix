/**
 * Imports
 */

import { strlen } from "std/c";
import { HxJson } from "@components/structs/json-component.struct";
import { hx_json_parse, hx_json_free, hx_json_get, hx_json_quote } from "@components/json.component";
import { JSON_NULL, JSON_BOOL, JSON_NUMBER, JSON_STRING, JSON_ARRAY, JSON_OBJECT } from "@constants/json.constant";

/**
 * Tests
 */

let errorBuf: u8[128] = undefined;
let quoteBuf: u8[64] = undefined;

/**
 * A NUL-terminated string as a slice.
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

/**
 * The parsed tree of a text that is expected to parse.
 */

function parse(text: string): HxJson {
    let out: HxJson = undefined;
    let at: u32 = 0;
    if (!hx_json_parse(text.ptr, text.len, &out, &errorBuf, errorBuf.len, &at)) {
        eprintln(`    error at ${at}: ${cString(&errorBuf)}`);
    }
    return out;
}

/**
 * The message and offset of a failure.
 */

struct Failure {
    message: string,
    at: u32,
}

/**
 * The failure that parsing a text gives, with an empty message when it parses.
 */

function failure(text: string): Failure {
    let out: HxJson = undefined;
    let at: u32 = 0;
    if (hx_json_parse(text.ptr, text.len, &out, &errorBuf, errorBuf.len, &at)) {
        hx_json_free(&out);
        return Failure { message: "", at: 0 };
    }
    return Failure { message: cString(&errorBuf), at };
}

/**
 * The member of an object, which is expected to exist.
 */

function get(json: readonly *HxJson, key: string): readonly *HxJson {
    return hx_json_get(json, key.ptr)!;
}

/**
 * The element or member value at an index.
 */

function item(json: readonly *HxJson, i: u32): readonly *HxJson {
    unsafe {
        return &json.items![i];
    }
}

/**
 * A text as a JSON string literal.
 */

function quote(text: string): string {
    hx_json_quote(text.ptr, &quoteBuf, quoteBuf.len);
    return cString(&quoteBuf);
}

describe("hx_json_parse") {
    test("should read every kind of value") {
        let j = parse("{\"a\": 1.5, \"b\": [true, false, null], \"c\": \"x\"}");
        defer hx_json_free(&j);

        expect(j.kind).toBe(JSON_OBJECT);
        expect(j.count).toBe(3);
        expect(get(&j, "a").kind).toBe(JSON_NUMBER);
        expect(get(&j, "a").number).toBe(1.5);
        expect(get(&j, "b").kind).toBe(JSON_ARRAY);
        expect(item(get(&j, "b"), 0).boolean).toBe(true);
        expect(item(get(&j, "b"), 1).kind).toBe(JSON_BOOL);
        expect(item(get(&j, "b"), 2).kind).toBe(JSON_NULL);
        expect(get(&j, "c").kind).toBe(JSON_STRING);
    }

    test("should decode escapes and surrogate pairs") {
        let j = parse("\"x\\n\\u00e9\\ud83d\\ude00\\/\"");
        defer hx_json_free(&j);

        expect(cString(j.string!)).toBe("x\n\u{E9}\u{1F600}/");
    }

    test("should read negative numbers and exponents") {
        let j = parse("[-2.5e3, 0]");
        defer hx_json_free(&j);

        expect(item(&j, 0).number).toBe(-2500.0);
        expect(item(&j, 1).number).toBe(0.0);
    }

    test("should allow comments and trailing commas") {
        let j = parse("// a project\n{\n  /* the name */ \"name\": \"app\", // inline\n  \"list\": [1, 2,],\n}\n");
        defer hx_json_free(&j);

        expect(cString(get(&j, "name").string!)).toBe("app");
        expect(get(&j, "list").count).toBe(2);
    }

    test("should keep the span of each value and key") {
        let j = parse("{ \"deps\": { \"a\": \"^1\" } }");
        defer hx_json_free(&j);
        const deps = get(&j, "deps");

        expect(deps.start).toBe(10);
        expect(deps.end).toBe(23);
        unsafe {
            expect(deps.key_starts![0]).toBe(12);
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
        void hx_json_parse(text.ptr, text.len, &out, &errorBuf, errorBuf.len, &at);

        expect(out.kind).toBe(JSON_NULL);
        expect(out.count).toBe(0);
        expect(out.items).toBeNull();
    }
}

describe("hx_json_free") {
    test("should leave the value without children") {
        let j = parse("[1, [2], {\"a\": \"b\"}]");
        hx_json_free(&j);

        expect(j.count).toBe(0);
        expect(j.items).toBeNull();
    }

    test("should do nothing to a value released twice") {
        let j = parse("{\"a\": 1}");
        hx_json_free(&j);
        hx_json_free(&j);

        expect(j.keys).toBeNull();
    }
}

describe("hx_json_get") {
    test("should find a member by its key") {
        let j = parse("{\"a\": 1, \"b\": 2}");
        defer hx_json_free(&j);

        expect(get(&j, "b").number).toBe(2.0);
    }

    test("should return null for a missing key") {
        let j = parse("{\"a\": 1}");
        defer hx_json_free(&j);

        expect(hx_json_get(&j, "missing")).toBeNull();
    }

    test("should return null for a value that is not an object") {
        let j = parse("[1]");
        defer hx_json_free(&j);

        expect(hx_json_get(&j, "a")).toBeNull();
    }

    test("should return null for a null input, so that lookups chain") {
        let j = parse("{\"a\": 1}");
        defer hx_json_free(&j);

        expect(hx_json_get(hx_json_get(&j, "x"), "y")).toBeNull();
    }
}

describe("hx_json_quote") {
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
