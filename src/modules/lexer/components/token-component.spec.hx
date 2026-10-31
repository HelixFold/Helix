/**
 * Imports
 */

import { strlen } from "std/c";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { isKeyword, isContextual, spelling } from "@modules/lexer/components/token.component";
import { hxTokenName, hxTokenSpelling, keyword, hxKeywordLookup } from "@modules/lexer/components/token.component";

/**
 * Tests
 */

/**
 * A NUL-terminated string as a slice.
 *
 * @param text - Pointer to the first byte of a NUL-terminated string
 * @returns A slice over the bytes before the terminator
 *
 * @remarks
 * The slice borrows the original bytes rather than copying them, so it lives only as long as they do.
 *
 * @since 1.0.0
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

describe("hxTokenName") {
    test("should return the name of a kind without its prefix") {
        expect(cString(hxTokenName(TokenKind.KwConst as u32))).toBe("KW_CONST");
        expect(cString(hxTokenName(TokenKind.DotDotEq as u32))).toBe("DOT_DOT_EQ");
        expect(cString(hxTokenName(TokenKind.Eof as u32))).toBe("EOF");
    }

    test("should return a question mark for a number that names no kind") {
        expect(cString(hxTokenName(500))).toBe("?");
    }
}

describe("hxTokenSpelling") {
    test("should return the source spelling of a kind") {
        expect(cString(hxTokenSpelling(TokenKind.Arrow as u32))).toBe("=>");
        expect(cString(hxTokenSpelling(TokenKind.KwWhile as u32))).toBe("while");
    }

    test("should return a question mark for a number that names no kind") {
        expect(cString(hxTokenSpelling(500))).toBe("?");
    }
}

describe("keyword") {
    test("should return the keyword that a word spells") {
        expect(keyword("as")).toBe(TokenKind.KwAs);
        expect(keyword("unreachable")).toBe(TokenKind.KwUnreachable);
        expect(keyword("type")).toBe(TokenKind.KwType);
    }

    test("should return an identifier for any other word") {
        expect(keyword("constant")).toBe(TokenKind.Ident);
        expect(keyword("Const")).toBe(TokenKind.Ident);
    }

    test("should spell every keyword back to itself") {
        for (const k of (TokenKind.KwAs as u32)..(TokenKind.KwWhile as u32) + 1) {
            expect(keyword(cString(hxTokenSpelling(k))) as u32).toBe(k);
        }
    }
}

describe("hxKeywordLookup") {
    test("should look up a keyword from a pointer and a length") {
        expect(hxKeywordLookup("while", 5)).toBe(TokenKind.KwWhile as u32);
        expect(hxKeywordLookup("whiled", 5)).toBe(TokenKind.KwWhile as u32);
    }

    test("should skip the lookup for words too short or too long to be keywords") {
        expect(hxKeywordLookup("x", 1)).toBe(TokenKind.Ident as u32);
        expect(hxKeywordLookup("unreachables", 12)).toBe(TokenKind.Ident as u32);
    }
}

describe("isKeyword") {
    test("should accept every keyword, contextual ones included") {
        expect(isKeyword(TokenKind.KwAs)).toBe(true);
        expect(isKeyword(TokenKind.KwWhile)).toBe(true);
        expect(isKeyword(TokenKind.KwType)).toBe(true);
    }

    test("should reject every other kind") {
        expect(isKeyword(TokenKind.Ident)).toBe(false);
        expect(isKeyword(TokenKind.LtLt)).toBe(false);
    }
}

describe("isContextual") {
    test("should accept the keywords that may serve as names") {
        expect(isContextual(TokenKind.KwType)).toBe(true);
        expect(isContextual(TokenKind.KwFrom)).toBe(true);
        expect(isContextual(TokenKind.KwError)).toBe(true);
    }

    test("should reject reserved keywords and other kinds") {
        expect(isContextual(TokenKind.KwConst)).toBe(false);
        expect(isContextual(TokenKind.Ident)).toBe(false);
    }
}

describe("spelling") {
    test("should return the spelling of a punctuation kind") {
        expect(spelling(TokenKind.Semicolon)).toBe(";");
        expect(spelling(TokenKind.QuestionQuestionEq)).toBe("??=");
    }

    test("should return a description for a kind without a fixed spelling") {
        expect(spelling(TokenKind.Eof)).toBe("end of file");
        expect(spelling(TokenKind.Int)).toBe("integer literal");
    }
}
