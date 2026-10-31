/**
 * Imports
 */

import { free } from "./heap";
import { fprintln } from "./io";
import { Builder, FormatError, alloc, bufPrint, count } from "./fmt";

/**
 * Tests
 */

describe("FormatError") {
    test("should come from bufPrint when the text does not fit") {
        let buf: u8[2] = undefined;

        expect(bufPrint(&buf, "abc")).toThrow(FormatError.NoSpaceLeft);
    }
}

describe("alloc") {
    test("should format a template into memory of the exact length") {
        const id = 7;
        const bytes = try alloc(testing.allocator, `id-${id}`);
        defer free(testing.allocator, bytes);
        const text: string = bytes;

        expect(text).toBe("id-7");
        expect(text.len).toBe(4);
    }

    test("should copy a plain string") {
        const bytes = try alloc(testing.allocator, "plain");
        defer free(testing.allocator, bytes);
        const text: string = bytes;

        expect(text).toBe("plain");
    }

    test("should return an empty slice for an empty string") {
        const text: string = try alloc(testing.allocator, "");

        expect(text.len).toBe(0);
    }
}

describe("bufPrint") {
    test("should write the text at the front of the buffer and return that part") {
        let buf: u8[16] = undefined;
        const text: string = try bufPrint(&buf, `${3},${4}`);

        expect(text).toBe("3,4");
        expect(buf[0]).toBe('3');
    }

    test("should fill the buffer exactly when the text is as long as it") {
        let buf: u8[3] = undefined;
        const text: string = try bufPrint(&buf, "abc");

        expect(text).toBe("abc");
    }

    test("should throw NoSpaceLeft when the text is longer than the buffer") {
        let buf: u8[4] = undefined;

        expect(bufPrint(&buf, "hello")).toThrow(FormatError.NoSpaceLeft);
    }

    test("should keep the parts that fit before the overflow") {
        let buf: u8[4] = ['.', '.', '.', '.'];
        const word = "toolong";
        void bufPrint(&buf, `ab${word}`) catch buf[0..0];

        expect(buf[0]).toBe('a');
        expect(buf[1]).toBe('b');
        expect(buf[2]).toBe('.');
    }
}

describe("count") {
    test("should count the bytes of a formatted template") {
        const n = 42;

        expect(try count(`${n}!`)).toBe(3);
    }

    test("should count 0 for an empty string") {
        expect(try count("")).toBe(0);
    }
}

describe("Builder") {
    describe("init") {
        test("should start with empty text") {
            const b = Builder.init(testing.allocator);

            expect(b.text()).toBe("");
            expect(b.bytes.capacity).toBe(0);
        }
    }

    describe("deinit") {
        test("should give the memory back and leave the text empty") {
            let b = Builder.init(testing.allocator);
            try b.append("abc");
            b.deinit();

            expect(b.text()).toBe("");
            expect(b.bytes.capacity).toBe(0);
        }
    }

    describe("append") {
        test("should add templates and strings in order") {
            let b = Builder.init(testing.allocator);
            defer b.deinit();
            try b.append("a");
            try b.append(`${1}`);
            try b.append(`=${true}`);

            expect(b.text()).toBe("a1=true");
        }

        test("should grow past the first block of storage") {
            let b = Builder.init(testing.allocator);
            defer b.deinit();
            for (const _ of 0..20) try b.append("xy");

            expect(b.text().len).toBe(40);
        }
    }

    describe("write") {
        test("should add raw bytes") {
            let b = Builder.init(testing.allocator);
            defer b.deinit();
            try b.write("ok");

            expect(b.text()).toBe("ok");
        }

        test("should make the builder a writer for fprintln") {
            let b = Builder.init(testing.allocator);
            defer b.deinit();
            try fprintln(&b, `n=${5}`);

            expect(b.text()).toBe("n=5\n");
        }
    }

    describe("text") {
        test("should return the text built so far") {
            let b = Builder.init(testing.allocator);
            defer b.deinit();
            try b.append("abc");

            expect(b.text()).toBe("abc");
        }
    }

    describe("clear") {
        test("should empty the text and keep the memory") {
            let b = Builder.init(testing.allocator);
            defer b.deinit();
            try b.append("abc");
            b.clear();

            expect(b.text()).toBe("");
            expect(b.bytes.capacity).toBe(8);
        }
    }
}
