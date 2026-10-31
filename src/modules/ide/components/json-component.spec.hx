/**
 * Imports
 */

import { buffer, raw, number, quoted, quotedList, writeKey } from "@modules/ide/components/json.component";

/**
 * Tests
 */

describe("buffer") {
    test("should start empty") {
        const b = buffer();

        expect(b.text()).toBe("");
    }
}

describe("raw") {
    test("should append the text as it is") {
        let b = buffer();
        raw(&b, "{\"a\":");
        raw(&b, "1}");

        expect(b.text()).toBe("{\"a\":1}");
    }
}

describe("number") {
    test("should write the number in decimal") {
        let b = buffer();
        number(&b, 0);
        raw(&b, ",");
        number(&b, 18446744073709551615);

        expect(b.text()).toBe("0,18446744073709551615");
    }
}

describe("quoted") {
    test("should wrap plain text in quotes") {
        let b = buffer();
        quoted(&b, "hello world");

        expect(b.text()).toBe("\"hello world\"");
    }

    test("should escape quotes and backslashes") {
        let b = buffer();
        quoted(&b, "say \"hi\" \\ bye");

        expect(b.text()).toBe("\"say \\\"hi\\\" \\\\ bye\"");
    }

    test("should write a newline, a tab, and a carriage return as short escapes") {
        let b = buffer();
        quoted(&b, "a\nb\tc\rd");

        expect(b.text()).toBe("\"a\\nb\\tc\\rd\"");
    }

    test("should write other control characters as lowercase unicode escapes") {
        let b = buffer();
        quoted(&b, "\x00\x1f");

        expect(b.text()).toBe("\"\\u0000\\u001f\"");
    }

    test("should keep bytes of UTF-8 text as they are") {
        let b = buffer();
        quoted(&b, "héllo ▶");

        expect(b.text()).toBe("\"héllo ▶\"");
    }

    test("should write an empty string as two quotes") {
        let b = buffer();
        quoted(&b, "");

        expect(b.text()).toBe("\"\"");
    }
}

describe("quotedList") {
    test("should write each string quoted, separated by commas") {
        let b = buffer();
        const list: string[3] = ["helix", "build", "a \"b\""];
        quotedList(&b, &list);

        expect(b.text()).toBe("[\"helix\",\"build\",\"a \\\"b\\\"\"]");
    }

    test("should write an empty list as two brackets") {
        let b = buffer();
        const list: string[0] = [];
        quotedList(&b, &list);

        expect(b.text()).toBe("[]");
    }
}

describe("writeKey") {
    test("should write the first key without a comma") {
        let b = buffer();
        raw(&b, "{");
        writeKey(&b, "kind", true);
        quoted(&b, "run");
        writeKey(&b, "cwd", false);
        quoted(&b, "/p");
        raw(&b, "}");

        expect(b.text()).toBe("{\"kind\":\"run\",\"cwd\":\"/p\"}");
    }
}
