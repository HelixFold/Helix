/**
 * Imports
 */

import { Split } from "./text";
import { equal, indexOf, lines, parseInt, ParseIntError, split, startsWith, endsWith, trim, Lines } from "./text";

/**
 * Tests
 */

describe("equal") {
    test("should accept two strings with the same bytes") {
        expect(equal("main", "main")).toBeTrue();
        expect(equal("", "")).toBeTrue();
    }

    test("should reject strings that differ in one byte") {
        expect(equal("main", "Main")).toBeFalse();
    }

    test("should reject strings of different lengths") {
        expect(equal("main", "mai")).toBeFalse();
        expect(equal("", "a")).toBeFalse();
    }
}

describe("startsWith") {
    test("should accept a matching prefix") {
        expect(startsWith("helix.jsonc", "helix")).toBeTrue();
        expect(startsWith("helix", "helix")).toBeTrue();
    }

    test("should accept an empty prefix") {
        expect(startsWith("helix", "")).toBeTrue();
        expect(startsWith("", "")).toBeTrue();
    }

    test("should reject a prefix longer than the text") {
        expect(startsWith("helix", "helix.jsonc")).toBeFalse();
    }

    test("should reject bytes that appear later but not at the start") {
        expect(startsWith("a-helix", "helix")).toBeFalse();
    }
}

describe("endsWith") {
    test("should accept a matching suffix") {
        expect(endsWith("main.hx", ".hx")).toBeTrue();
    }

    test("should accept an empty suffix") {
        expect(endsWith("main.hx", "")).toBeTrue();
    }

    test("should reject a suffix longer than the text") {
        expect(endsWith("hx", "main.hx")).toBeFalse();
    }

    test("should reject a different ending") {
        expect(endsWith("main.hx", ".c")).toBeFalse();
    }
}

describe("indexOf") {
    test("should report the offset of the first match") {
        expect(indexOf("a,b,c", ",")).toBe(1);
        expect(indexOf("abcabc", "bc")).toBe(1);
    }

    test("should find a needle at the very end") {
        expect(indexOf("abc", "c")).toBe(2);
        expect(indexOf("abc", "abc")).toBe(0);
    }

    test("should report null for a needle that does not occur") {
        expect(indexOf("a,b,c", "x")).toBeNull();
    }

    test("should report null for a needle longer than the text") {
        expect(indexOf("ab", "abc")).toBeNull();
    }

    test("should match an empty needle at offset 0") {
        expect(indexOf("abc", "")).toBe(0);
        expect(indexOf("", "")).toBe(0);
    }
}

describe("trim") {
    test("should drop spaces, tabs, and line breaks from both ends") {
        expect(trim("  main \r\n")).toBe("main");
        expect(trim("\tmain")).toBe("main");
    }

    test("should keep whitespace between the words") {
        expect(trim(" a b ")).toBe("a b");
    }

    test("should give an empty string for whitespace alone") {
        expect(trim(" \t\r\n ")).toBe("");
        expect(trim("")).toBe("");
    }

    test("should keep a form feed, which it does not count as whitespace") {
        expect(trim("\x0Ca")).toBe("\x0Ca");
    }
}

describe("ParseIntError") {
    test("should keep its three cases apart") {
        expect(ParseIntError.Empty == ParseIntError.InvalidDigit).toBeFalse();
        expect(ParseIntError.InvalidDigit == ParseIntError.Overflow).toBeFalse();
    }
}

describe("parseInt") {
    test("should read a positive number") {
        expect(try parseInt("42")).toBe(42);
        expect(try parseInt("0")).toBe(0);
    }

    test("should read a negative number") {
        expect(try parseInt("-7")).toBe(-7);
    }

    test("should accept leading zeros") {
        expect(try parseInt("-007")).toBe(-7);
    }

    test("should read both ends of the i64 range") {
        expect(try parseInt("9223372036854775807")).toBe(9223372036854775807);
        expect(try parseInt("-9223372036854775808")).toBe(-9223372036854775807 - 1);
    }

    test("should reject a string without digits") {
        expect(parseInt("")).toThrow(ParseIntError.Empty);
        expect(parseInt("-")).toThrow(ParseIntError.Empty);
    }

    test("should reject a byte that is not a digit") {
        expect(parseInt("12a")).toThrow(ParseIntError.InvalidDigit);
        expect(parseInt("+1")).toThrow(ParseIntError.InvalidDigit);
        expect(parseInt(" 1")).toThrow(ParseIntError.InvalidDigit);
        expect(parseInt("1.5")).toThrow(ParseIntError.InvalidDigit);
    }

    test("should reject a number just outside the i64 range") {
        expect(parseInt("9223372036854775808")).toThrow(ParseIntError.Overflow);
        expect(parseInt("-9223372036854775809")).toThrow(ParseIntError.Overflow);
    }

    test("should reject a number far outside the i64 range") {
        expect(parseInt("100000000000000000000")).toThrow(ParseIntError.Overflow);
    }
}

describe("split") {
    test("should hand out the pieces between the separators in order") {
        let pieces = split("a,b,,c", ",");

        expect(pieces.next()).toBe("a");
        expect(pieces.next()).toBe("b");
        expect(pieces.next()).toBe("");
        expect(pieces.next()).toBe("c");
        expect(pieces.next()).toBeNull();
    }

    test("should split around a separator of several bytes") {
        let pieces = split("a::b", "::");

        expect(pieces.next()).toBe("a");
        expect(pieces.next()).toBe("b");
        expect(pieces.next()).toBeNull();
    }

    test("should give the whole text for an empty separator") {
        let pieces = split("a,b", "");

        expect(pieces.next()).toBe("a,b");
        expect(pieces.next()).toBeNull();
    }

    test("should give one empty piece for an empty text") {
        let pieces = split("", ",");

        expect(pieces.next()).toBe("");
        expect(pieces.next()).toBeNull();
    }

    test("should drive a for loop") {
        let count: usize = 0;
        for (const _piece of split("a,b,c", ",")) count++;

        expect(count).toBe(3);
    }
}

describe("Split") {
    describe("next") {
        test("should give an empty last piece after a trailing separator") {
            let pieces = split("a,", ",");

            expect(pieces.next()).toBe("a");
            expect(pieces.next()).toBe("");
            expect(pieces.next()).toBeNull();
        }

        test("should move rest past each piece and its separator") {
            let pieces = Split { rest: "a,b", separator: ",", done: false };
            void pieces.next();

            expect(pieces.rest).toBe("b");
            expect(pieces.done).toBeFalse();
        }

        test("should mark the iterator done after the last piece") {
            let pieces = split("a", ",");
            void pieces.next();

            expect(pieces.done).toBeTrue();
            expect(pieces.next()).toBeNull();
        }
    }
}

describe("lines") {
    test("should hand out the lines without their newlines") {
        let rows = lines("a\nb\nc");

        expect(rows.next()).toBe("a");
        expect(rows.next()).toBe("b");
        expect(rows.next()).toBe("c");
        expect(rows.next()).toBeNull();
    }

    test("should not start a line after a newline at the very end") {
        let rows = lines("a\n");

        expect(rows.next()).toBe("a");
        expect(rows.next()).toBeNull();
    }

    test("should give no lines for an empty text") {
        let rows = lines("");

        expect(rows.next()).toBeNull();
    }

    test("should drive a for loop") {
        let count: usize = 0;
        for (const _line of lines("a\r\nb\n")) count++;

        expect(count).toBe(2);
    }
}

describe("Lines") {
    describe("next") {
        test("should drop the carriage return of a Windows line ending") {
            let rows = lines("a\r\nb\r\n");

            expect(rows.next()).toBe("a");
            expect(rows.next()).toBe("b");
            expect(rows.next()).toBeNull();
        }

        test("should give an empty line between two newlines") {
            let rows = lines("a\n\nb");

            expect(rows.next()).toBe("a");
            expect(rows.next()).toBe("");
            expect(rows.next()).toBe("b");
        }

        test("should keep a carriage return in the middle of a line") {
            let rows = lines("a\rb\n");

            expect(rows.next()).toBe("a\rb");
        }

        test("should drop a carriage return at the very end of the text") {
            let rows = Lines { rest: "a\r" };

            expect(rows.next()).toBe("a");
            expect(rows.rest).toBe("");
        }
    }
}
