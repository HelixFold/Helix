/**
 * Imports
 */

import { strlen } from "std/c";
import { cAllocator } from "std";
import { Builder } from "std/fmt";
import { hxDiagListFree } from "@models/diagnostic.model";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxTokenName } from "@modules/lexer/components/token.component";
import { hxLex, hxLexAppend, hxTokensFree } from "@modules/lexer/lexer.module";
import { addText, files, hxSourceFromString, hxSourceFree } from "@models/source.model";

/**
 * Tests
 */

/**
 * A source, its tokens, and its diagnostics after one run of the lexer.
 *
 * @remarks
 * The `ok` field keeps the result of {@link hxLex}, so a test can check success without counting errors.
 * Each test declares one on the stack, fills it with {@link lex}, and frees it with {@link release}.
 *
 * @since 1.0.0
 */

struct Lexed {
    src: HxSource,
    tokens: HxTokens,
    diags: HxDiagList,
    ok: bool,
}

let out: Builder = undefined;
let outReady = false;

/**
 * The shared output builder, emptied.
 *
 * @returns The module-level builder, cleared and ready for appending
 *
 * @remarks
 * The builder is created with the C allocator on the first call and reused after that,
 * so every helper that returns its text hands out a view that the next call to this function invalidates.
 *
 * @since 1.0.0
 */

function cleared(): *Builder {
    if (!outReady) {
        out = Builder.init(cAllocator());
        outReady = true;
    }
    out.clear();
    return &out;
}

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

/**
 * An empty diagnostic list.
 *
 * @returns A list without items, with an empty arena and an error count of zero
 *
 * @remarks
 * The list owns no memory yet, so it is safe to free even when nothing reports into it.
 *
 * @since 1.0.0
 */

function emptyList(): HxDiagList {
    return HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
}

/**
 * Lexes a text as one file.
 *
 * @param lexed - State that receives the source, tokens, diagnostics, and result
 * @param text - Source text to lex, named `test.hx`
 *
 * @remarks
 * The diagnostics start empty before the run, so they hold only what this text reports.
 *
 * @since 1.0.0
 */

function lex(lexed: *Lexed, text: string): void {
    lexed.diags = emptyList();
    hxSourceFromString(&lexed.src, "test.hx", text.ptr, text.len);
    lexed.ok = hxLex(&lexed.src, &lexed.tokens, &lexed.diags);
}

/**
 * Releases everything that one run of the lexer allocated.
 *
 * @param lexed - State that {@link lex} filled
 *
 * @remarks
 * It frees the tokens, the diagnostics, and the source, and leaves the state's own storage to the caller.
 *
 * @since 1.0.0
 */

function release(lexed: *Lexed): void {
    hxTokensFree(&lexed.tokens);
    hxDiagListFree(&lexed.diags);
    hxSourceFree(&lexed.src);
}

/**
 * Every error message, one per line.
 *
 * @param lexed - State whose diagnostics to list
 * @returns The messages, each followed by a newline, in the shared output builder
 *
 * @remarks
 * Only the message text is printed, without positions or hints.
 * The result lives in the builder from {@link cleared}, so the next helper call overwrites it.
 *
 * @since 1.0.0
 */

function messages(lexed: readonly *Lexed): string {
    const b = cleared();
    for (const i of 0..lexed.diags.itemsLen) {
        unsafe {
            b.append(`${cString(lexed.diags.items![i].message)}\n`) catch unreachable;
        }
    }
    return b.text();
}

/**
 * The token names of a text without the closing end-of-file token, or its errors when it does not lex.
 *
 * @param text - Source text to lex
 * @returns The token names separated by spaces, or the error messages from {@link messages}
 *
 * @remarks
 * When the last token is not `EOF`, the result ends with ` (ends with NAME)`,
 * so a test catches a token stream that the lexer failed to close.
 * The check only looks at the first letter of the name, so it relies on no other final token starting with `E`.
 *
 * @since 1.0.0
 */

function kinds(text: string): string {
    let lexed: Lexed = undefined;
    lex(&lexed, text);
    defer release(&lexed);
    if (!lexed.ok) return messages(&lexed);
    const b = cleared();
    for (const i of 0..lexed.tokens.len) {
        unsafe {
            const name = cString(hxTokenName(lexed.tokens.kinds![i] as u32));
            if (i + 1 == lexed.tokens.len) {
                if (name[0] != 'E') b.append(` (ends with ${name})`) catch unreachable;
            } else {
                b.append(i == 0 ? `${name}` : ` ${name}`) catch unreachable;
            }
        }
    }
    return b.text();
}

/**
 * The errors that lexing a text gives, one per line, or an empty string when it lexes.
 *
 * @param text - Source text to lex
 * @returns The error messages from {@link messages}, or an empty string when the lexer succeeds
 *
 * @remarks
 * Success comes from the lexer's return value rather than from the diagnostic count.
 *
 * @since 1.0.0
 */

function errors(text: string): string {
    let lexed: Lexed = undefined;
    lex(&lexed, text);
    defer release(&lexed);
    if (lexed.ok) return "";
    return messages(&lexed);
}

describe("hxLex") {
    test("should give only the end of file for an empty file") {
        let lexed: Lexed = undefined;
        lex(&lexed, "");
        defer release(&lexed);

        expect(lexed.ok).toBeTrue();
        expect(lexed.tokens.len).toBe(1);
        expect(kinds("")).toBe("");
    }

    test("should tell keywords from identifiers") {
        expect(kinds("const let function return constant _x x1"))
            .toBe("KW_CONST KW_LET KW_FUNCTION KW_RETURN IDENT IDENT IDENT");
        expect(kinds("defer errdefer try catch throw unreachable"))
            .toBe("KW_DEFER KW_ERRDEFER KW_TRY KW_CATCH KW_THROW KW_UNREACHABLE");
    }

    test("should read a declaration") {
        expect(kinds("export function add(a: i32, b: i32): i32 { return a + b; }")).toBe(
            "KW_EXPORT KW_FUNCTION IDENT LPAREN IDENT COLON IDENT COMMA IDENT COLON IDENT RPAREN COLON IDENT LBRACE KW_RETURN IDENT PLUS IDENT SEMICOLON RBRACE");
    }

    test("should read numbers in every base") {
        expect(kinds("0 42 1_000_000 0xFF 0o755 0b1010 3.14 1e9 2.5e-3"))
            .toBe("INT INT INT INT INT INT FLOAT FLOAT FLOAT");
    }

    test("should not read a range as a float") {
        expect(kinds("0..n")).toBe("INT DOT_DOT IDENT");
        expect(kinds("0..=9")).toBe("INT DOT_DOT_EQ INT");
        expect(kinds("1.0..2.0")).toBe("FLOAT DOT_DOT FLOAT");
    }

    test("should report bad numbers") {
        expect(errors("0x")).toInclude("missing digits");
        expect(errors("1__0")).toInclude("misplaced `_`");
        expect(errors("10_")).toInclude("misplaced `_`");
        expect(errors("0755")).toInclude("leading zero");
        expect(errors("0b102")).toInclude("invalid character");
        expect(errors("1e")).toInclude("exponent");
    }

    test("should read strings and characters with escapes") {
        expect(kinds("\"hello\" \"a\\n\\t\\\"b\" \"\\x41\\u{1F600}\"")).toBe("STRING STRING STRING");
        expect(kinds("'a' '\\n' '\\u{E9}' '\u{E9}'")).toBe("CHAR CHAR CHAR CHAR");
    }

    test("should report bad strings and characters") {
        expect(errors("\"open")).toInclude("unterminated string");
        expect(errors("\"a\nb\"")).toInclude("unterminated string");
        expect(errors("\"bad \\q\"")).toInclude("unknown escape");
        expect(errors("\"\\x4\"")).toInclude("two hex digits");
        expect(errors("\"\\u41\"")).toInclude("needs braces");
        expect(errors("\"\\u{D800}\"")).toInclude("invalid unicode");
        expect(errors("'ab'")).toInclude("one character");
        expect(errors("''")).toInclude("empty character");
    }

    test("should split templates around their expressions") {
        expect(kinds("`plain`")).toBe("TEMPLATE_FULL");
        expect(kinds("`a ${x} b`")).toBe("TEMPLATE_HEAD IDENT TEMPLATE_TAIL");
        expect(kinds("`${a}${b}`")).toBe("TEMPLATE_HEAD IDENT TEMPLATE_MIDDLE IDENT TEMPLATE_TAIL");
    }

    test("should keep braces and nested templates inside a template") {
        expect(kinds("`${ {a} }`")).toBe("TEMPLATE_HEAD LBRACE IDENT RBRACE TEMPLATE_TAIL");
        expect(kinds("`x ${ `y ${z}` } w`")).toBe("TEMPLATE_HEAD TEMPLATE_HEAD IDENT TEMPLATE_TAIL TEMPLATE_TAIL");
        expect(kinds("{ `${a}` }")).toBe("LBRACE TEMPLATE_HEAD IDENT TEMPLATE_TAIL RBRACE");
    }

    test("should report unclosed templates") {
        expect(errors("`open")).toInclude("unterminated template");
        expect(errors("`a ${x")).toInclude("unterminated `${`");
    }

    test("should skip line, block, and nested comments") {
        expect(kinds("a // line\nb")).toBe("IDENT IDENT");
        expect(kinds("a /* block */ b")).toBe("IDENT IDENT");
        expect(kinds("a /* outer /* inner */ still */ b")).toBe("IDENT IDENT");
        expect(errors("/* open /* nested */")).toInclude("unterminated block comment");
    }

    test("should attach a doc comment to the token after it") {
        let lexed: Lexed = undefined;
        lex(&lexed, "/** first */ /**/ a /** second */ b");
        defer release(&lexed);

        expect(lexed.ok).toBeTrue();
        expect(lexed.tokens.docsLen).toBe(2);
        unsafe {
            expect(lexed.tokens.docs![0].token).toBe(0);
            expect(lexed.tokens.docs![0].start).toBe(0);
            expect(lexed.tokens.docs![0].len).toBe(12);
            expect(lexed.tokens.docs![1].token).toBe(1);
        }
    }

    test("should take the longest operator") {
        expect(kinds("+ += +% +%= +| +|= ++"))
            .toBe("PLUS PLUS_EQ PLUS_PERCENT PLUS_PERCENT_EQ PLUS_PIPE PLUS_PIPE_EQ PLUS_PLUS");
        expect(kinds("- -= -% -%= -| -|= --"))
            .toBe("MINUS MINUS_EQ MINUS_PERCENT MINUS_PERCENT_EQ MINUS_PIPE MINUS_PIPE_EQ MINUS_MINUS");
        expect(kinds("* *= *% *%= *| *|="))
            .toBe("STAR STAR_EQ STAR_PERCENT STAR_PERCENT_EQ STAR_PIPE STAR_PIPE_EQ");
        expect(kinds("? ?. ?? ??= ! != = == =>"))
            .toBe("QUESTION QUESTION_DOT QUESTION_QUESTION QUESTION_QUESTION_EQ BANG BANG_EQ EQ EQ_EQ ARROW");
        expect(kinds("< <= << <<= > >= & && | || . .. ..= ...")).toBe(
            "LT LT_EQ LT_LT LT_LT_EQ GT GT_EQ AMP AMP_AMP PIPE PIPE_PIPE DOT DOT_DOT DOT_DOT_EQ ELLIPSIS");
    }

    test("should read a right shift as two tokens") {
        expect(kinds("ArrayList<ArrayList<u8>>")).toBe("IDENT LT IDENT LT IDENT GT GT");
        expect(kinds("a >> b")).toBe("IDENT GT GT IDENT");
        expect(kinds("a >>= b")).toBe("IDENT GT GT_EQ IDENT");
    }

    test("should read optional and error syntax") {
        expect(kinds("user.email?.len ?? 0")).toBe("IDENT DOT IDENT QUESTION_DOT IDENT QUESTION_QUESTION INT");
        expect(kinds("x!")).toBe("IDENT BANG");
        expect(kinds("?*User | DbError")).toBe("QUESTION STAR IDENT PIPE IDENT");
    }

    test("should read builtins") {
        expect(kinds("@sizeOf(T)")).toBe("BUILTIN LPAREN IDENT RPAREN");
        expect(errors("@ x")).toInclude("builtin name");
    }

    test("should reject strict equality") {
        expect(errors("a === b")).toInclude("`===` does not exist");
        expect(errors("a !== b")).toInclude("`!==` does not exist");
    }

    test("should reject characters outside the language") {
        expect(errors("a # b")).toInclude("unexpected character `#`");
        expect(errors("let caf\u{E9} = 1;")).toInclude("non-ASCII");
        expect(errors("a \x01 b")).toInclude("unexpected byte 0x01");
    }

    test("should keep going after an error and report every one") {
        let lexed: Lexed = undefined;
        lex(&lexed, "a # b $ c");
        defer release(&lexed);

        expect(lexed.ok).toBeFalse();
        expect(lexed.diags.errorCount).toBe(2);
        expect(lexed.tokens.len).toBe(6);
    }

    test("should record where each token starts and how long it is") {
        let lexed: Lexed = undefined;
        lex(&lexed, "let  x");
        defer release(&lexed);

        unsafe {
            expect(lexed.tokens.starts![0]).toBe(0);
            expect(lexed.tokens.lens![0]).toBe(3);
            expect(lexed.tokens.starts![1]).toBe(5);
            expect(lexed.tokens.lens![1]).toBe(1);
            expect(lexed.tokens.starts![2]).toBe(6);
            expect(lexed.tokens.lens![2]).toBe(0);
        }
    }
}

describe("hxLexAppend") {
    test("should close each file with its own end of file") {
        let src: HxSource = undefined;
        hxSourceFromString(&src, "a.hx", "a", 1);
        defer hxSourceFree(&src);
        void addText(&src, "b.hx", "b c");
        let tokens = HxTokens { kinds: null, starts: null, lens: null, len: 0, cap: 0, docs: null, docsLen: 0, docsCap: 0 };
        defer hxTokensFree(&tokens);
        let diags = emptyList();
        defer hxDiagListFree(&diags);
        unsafe {
            void hxLexAppend(&src, files(&src)[0].start, files(&src)[0].end, &tokens, &diags);
            void hxLexAppend(&src, files(&src)[1].start, files(&src)[1].end, &tokens, &diags);
        }

        expect(tokens.len).toBe(5);
        unsafe {
            expect(cString(hxTokenName(tokens.kinds![1] as u32))).toBe("EOF");
            expect(tokens.starts![1]).toBe(1);
            expect(tokens.starts![2]).toBe(2);
            expect(cString(hxTokenName(tokens.kinds![4] as u32))).toBe("EOF");
        }
    }

    test("should report success for its own file whatever earlier runs reported") {
        let src: HxSource = undefined;
        hxSourceFromString(&src, "a.hx", "#", 1);
        defer hxSourceFree(&src);
        void addText(&src, "b.hx", "b");
        let tokens = HxTokens { kinds: null, starts: null, lens: null, len: 0, cap: 0, docs: null, docsLen: 0, docsCap: 0 };
        defer hxTokensFree(&tokens);
        let diags = emptyList();
        defer hxDiagListFree(&diags);
        unsafe {
            expect(hxLexAppend(&src, files(&src)[0].start, files(&src)[0].end, &tokens, &diags)).toBeFalse();
            expect(hxLexAppend(&src, files(&src)[1].start, files(&src)[1].end, &tokens, &diags)).toBeTrue();
        }
    }
}

describe("hxTokensFree") {
    test("should leave the token stream empty") {
        let lexed: Lexed = undefined;
        lex(&lexed, "/** doc */ a");
        hxTokensFree(&lexed.tokens);

        expect(lexed.tokens.len).toBe(0);
        expect(lexed.tokens.kinds).toBeNull();
        expect(lexed.tokens.docs).toBeNull();
        hxDiagListFree(&lexed.diags);
        hxSourceFree(&lexed.src);
    }
}
