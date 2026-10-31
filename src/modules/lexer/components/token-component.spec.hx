/**
 * Imports
 */

import { strlen } from "std/c";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { hx_token_name, hx_token_spelling, keyword } from "@modules/lexer/components/token.component";
import { hx_keyword_lookup, isKeyword, isContextual, spelling } from "@modules/lexer/components/token.component";

/**
 * Tests
 */

/**
 * A NUL-terminated string as a slice.
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

describe("hx_token_name") {
    test("should return the name of a kind without its prefix") {
        expect(cString(hx_token_name(TokenKind.KwConst as u32))).toBe("KW_CONST");
        expect(cString(hx_token_name(TokenKind.DotDotEq as u32))).toBe("DOT_DOT_EQ");
        expect(cString(hx_token_name(TokenKind.Eof as u32))).toBe("EOF");
    }

    test("should return a question mark for a number that names no kind") {
        expect(cString(hx_token_name(500))).toBe("?");
    }
}

describe("hx_token_spelling") {
    test("should return the source spelling of a kind") {
        expect(cString(hx_token_spelling(TokenKind.Arrow as u32))).toBe("=>");
        expect(cString(hx_token_spelling(TokenKind.KwWhile as u32))).toBe("while");
    }

    test("should return a question mark for a number that names no kind") {
        expect(cString(hx_token_spelling(500))).toBe("?");
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
            expect(keyword(cString(hx_token_spelling(k))) as u32).toBe(k);
        }
    }
}

describe("hx_keyword_lookup") {
    test("should look up a keyword from a pointer and a length") {
        expect(hx_keyword_lookup("while", 5)).toBe(TokenKind.KwWhile as u32);
        expect(hx_keyword_lookup("whiled", 5)).toBe(TokenKind.KwWhile as u32);
    }

    test("should skip the lookup for words too short or too long to be keywords") {
        expect(hx_keyword_lookup("x", 1)).toBe(TokenKind.Ident as u32);
        expect(hx_keyword_lookup("unreachables", 12)).toBe(TokenKind.Ident as u32);
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
