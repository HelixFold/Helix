/**
 * The kind of a token.
 *
 * @remarks
 * The lexer stores one byte per token, and the order matches {@link TOKEN_NAMES} and {@link TOKEN_SPELLINGS}.
 * Members run from the end marker through literals and punctuation to the keywords, which come last in alphabetical order,
 * so {@link isKeyword} is a range check.
 *
 * @example
 * ```ts
 * hx_token_name(TokenKind.KwConst as u32); // 'KW_CONST'
 * spelling(TokenKind.Arrow);              // '=>'
 * ```
 *
 * @since 1.0.0
 */

export enum TokenKind: u8 {
    /**
     * The end of the input, which closes every token stream.
     *
     * @remarks
     * Every run of the lexer ends with exactly one, of length 0.
     *
     * @example
     * ```ts
     * // 'a' lexes as IDENT EOF
     * ```
     *
     * @since 1.0.0
     */

    Eof,

    /**
     * A byte or character that starts no token.
     *
     * @remarks
     * The lexer reports it and moves on, so one run finds every lexical error.
     *
     * @example
     * ```ts
     * a # b   // IDENT INVALID IDENT
     * ```
     *
     * @since 1.0.0
     */

    Invalid,

    /**
     * An identifier.
     *
     * @remarks
     * A name starts with an ASCII letter or `_` and goes on with letters, digits, and `_`.
     *
     * @example
     * ```ts
     * const count = 1;   // count
     * ```
     *
     * @since 1.0.0
     */

    Ident,

    /**
     * A builtin name, which is `@` followed by an identifier.
     *
     * @example
     * ```ts
     * @sizeOf(Point);   // @sizeOf
     * ```
     *
     * @since 1.0.0
     */

    Builtin,

    /**
     * An integer literal in base 10, 16, 8, or 2.
     *
     * @remarks
     * Digits may be separated by `_`.
     *
     * @example
     * ```ts
     * 0xFF 0o755 0b1010 1_000_000
     * ```
     *
     * @since 1.0.0
     */

    Int,

    /**
     * A floating-point literal with a fraction, an exponent, or both.
     *
     * @remarks
     * A fraction needs a digit after the dot, so `0..n` stays a range.
     *
     * @example
     * ```ts
     * 3.14 1e9 2.5e-3
     * ```
     *
     * @since 1.0.0
     */

    Float,

    /**
     * A string literal in double quotes.
     *
     * @example
     * ```ts
     * "hello\n"
     * ```
     *
     * @since 1.0.0
     */

    String,

    /**
     * A character literal in single quotes.
     *
     * @example
     * ```ts
     * 'a' '\n' '\u{E9}'
     * ```
     *
     * @since 1.0.0
     */

    Char,

    /**
     * A template literal without any substitution.
     *
     * @example
     * ```ts
     * `plain text`
     * ```
     *
     * @since 1.0.0
     */

    TemplateFull,

    /**
     * The text of a template literal from its opening backtick up to the first `${`.
     *
     * @example
     * ```ts
     * `a ${x} b`   // `a ${
     * ```
     *
     * @since 1.0.0
     */

    TemplateHead,

    /**
     * The text of a template literal between two substitutions.
     *
     * @example
     * ```ts
     * `${a} and ${b}`   // } and ${
     * ```
     *
     * @since 1.0.0
     */

    TemplateMiddle,

    /**
     * The text of a template literal from the last substitution up to its closing backtick.
     *
     * @example
     * ```ts
     * `a ${x} b`   // } b`
     * ```
     *
     * @since 1.0.0
     */

    TemplateTail,

    /**
     * The `(` token.
     *
     * @example
     * ```ts
     * add(1, 2)
     * ```
     *
     * @since 1.0.0
     */

    Lparen,

    /**
     * The `)` token.
     *
     * @example
     * ```ts
     * add(1, 2)
     * ```
     *
     * @since 1.0.0
     */

    Rparen,

    /**
     * The `{` token.
     *
     * @example
     * ```ts
     * { return 1; }
     * ```
     *
     * @since 1.0.0
     */

    Lbrace,

    /**
     * The `}` token.
     *
     * @example
     * ```ts
     * { return 1; }
     * ```
     *
     * @since 1.0.0
     */

    Rbrace,

    /**
     * The `[` token.
     *
     * @example
     * ```ts
     * items[0]
     * ```
     *
     * @since 1.0.0
     */

    Lbracket,

    /**
     * The `]` token.
     *
     * @example
     * ```ts
     * items[0]
     * ```
     *
     * @since 1.0.0
     */

    Rbracket,

    /**
     * The `,` token.
     *
     * @example
     * ```ts
     * add(1, 2)
     * ```
     *
     * @since 1.0.0
     */

    Comma,

    /**
     * The `;` token.
     *
     * @example
     * ```ts
     * let a = 1;
     * ```
     *
     * @since 1.0.0
     */

    Semicolon,

    /**
     * The `:` token.
     *
     * @example
     * ```ts
     * let a: i32 = 1;
     * ```
     *
     * @since 1.0.0
     */

    Colon,

    /**
     * The `.` token.
     *
     * @example
     * ```ts
     * point.x
     * ```
     *
     * @since 1.0.0
     */

    Dot,

    /**
     * The `..` token.
     *
     * @example
     * ```ts
     * items[1..3]
     * ```
     *
     * @since 1.0.0
     */

    DotDot,

    /**
     * The `..=` token.
     *
     * @example
     * ```ts
     * for (const i of 0..=9) {}
     * ```
     *
     * @since 1.0.0
     */

    DotDotEq,

    /**
     * The `...` token.
     *
     * @example
     * ```ts
     * extern "C" function printf(format: readonly u8[*], ...): i32;
     * ```
     *
     * @since 1.0.0
     */

    Ellipsis,

    /**
     * The `=>` token.
     *
     * @example
     * ```ts
     * (x: i32): i32 => x * 2
     * ```
     *
     * @since 1.0.0
     */

    Arrow,

    /**
     * The `?` token.
     *
     * @example
     * ```ts
     * ok ? 1 : 0
     * ```
     *
     * @since 1.0.0
     */

    Question,

    /**
     * The `?.` token.
     *
     * @example
     * ```ts
     * user?.name
     * ```
     *
     * @since 1.0.0
     */

    QuestionDot,

    /**
     * The `??` token.
     *
     * @example
     * ```ts
     * name ?? "guest"
     * ```
     *
     * @since 1.0.0
     */

    QuestionQuestion,

    /**
     * The `??=` token.
     *
     * @example
     * ```ts
     * name ??= "guest";
     * ```
     *
     * @since 1.0.0
     */

    QuestionQuestionEq,

    /**
     * The `!` token.
     *
     * @example
     * ```ts
     * !done
     * ```
     *
     * @since 1.0.0
     */

    Bang,

    /**
     * The `=` token.
     *
     * @example
     * ```ts
     * x = 1;
     * ```
     *
     * @since 1.0.0
     */

    Eq,

    /**
     * The `+=` token.
     *
     * @example
     * ```ts
     * x += 1;
     * ```
     *
     * @since 1.0.0
     */

    PlusEq,

    /**
     * The `-=` token.
     *
     * @example
     * ```ts
     * x -= 1;
     * ```
     *
     * @since 1.0.0
     */

    MinusEq,

    /**
     * The `*=` token.
     *
     * @example
     * ```ts
     * x *= 2;
     * ```
     *
     * @since 1.0.0
     */

    StarEq,

    /**
     * The `/=` token.
     *
     * @example
     * ```ts
     * x /= 2;
     * ```
     *
     * @since 1.0.0
     */

    SlashEq,

    /**
     * The `%=` token.
     *
     * @example
     * ```ts
     * x %= 2;
     * ```
     *
     * @since 1.0.0
     */

    PercentEq,

    /**
     * The `+%=` token.
     *
     * @example
     * ```ts
     * x +%= 1;
     * ```
     *
     * @since 1.0.0
     */

    PlusPercentEq,

    /**
     * The `-%=` token.
     *
     * @example
     * ```ts
     * x -%= 1;
     * ```
     *
     * @since 1.0.0
     */

    MinusPercentEq,

    /**
     * The `*%=` token.
     *
     * @example
     * ```ts
     * x *%= 2;
     * ```
     *
     * @since 1.0.0
     */

    StarPercentEq,

    /**
     * The `+|=` token.
     *
     * @example
     * ```ts
     * x +|= 1;
     * ```
     *
     * @since 1.0.0
     */

    PlusPipeEq,

    /**
     * The `-|=` token.
     *
     * @example
     * ```ts
     * x -|= 1;
     * ```
     *
     * @since 1.0.0
     */

    MinusPipeEq,

    /**
     * The `*|=` token.
     *
     * @example
     * ```ts
     * x *|= 2;
     * ```
     *
     * @since 1.0.0
     */

    StarPipeEq,

    /**
     * The `&=` token.
     *
     * @example
     * ```ts
     * flags &= mask;
     * ```
     *
     * @since 1.0.0
     */

    AmpEq,

    /**
     * The `|=` token.
     *
     * @example
     * ```ts
     * flags |= mask;
     * ```
     *
     * @since 1.0.0
     */

    PipeEq,

    /**
     * The `^=` token.
     *
     * @example
     * ```ts
     * flags ^= mask;
     * ```
     *
     * @since 1.0.0
     */

    CaretEq,

    /**
     * The `<<=` token.
     *
     * @example
     * ```ts
     * x <<= 1;
     * ```
     *
     * @since 1.0.0
     */

    LtLtEq,

    /**
     * The `+` token.
     *
     * @example
     * ```ts
     * a + b
     * ```
     *
     * @since 1.0.0
     */

    Plus,

    /**
     * The `-` token.
     *
     * @example
     * ```ts
     * a - b
     * ```
     *
     * @since 1.0.0
     */

    Minus,

    /**
     * The `*` token.
     *
     * @example
     * ```ts
     * a * b
     * ```
     *
     * @since 1.0.0
     */

    Star,

    /**
     * The `/` token.
     *
     * @example
     * ```ts
     * a / b
     * ```
     *
     * @since 1.0.0
     */

    Slash,

    /**
     * The `%` token.
     *
     * @example
     * ```ts
     * a % b
     * ```
     *
     * @since 1.0.0
     */

    Percent,

    /**
     * The `+%` token.
     *
     * @example
     * ```ts
     * a +% b
     * ```
     *
     * @since 1.0.0
     */

    PlusPercent,

    /**
     * The `-%` token.
     *
     * @example
     * ```ts
     * a -% b
     * ```
     *
     * @since 1.0.0
     */

    MinusPercent,

    /**
     * The `*%` token.
     *
     * @example
     * ```ts
     * a *% b
     * ```
     *
     * @since 1.0.0
     */

    StarPercent,

    /**
     * The `+|` token.
     *
     * @example
     * ```ts
     * a +| b
     * ```
     *
     * @since 1.0.0
     */

    PlusPipe,

    /**
     * The `-|` token.
     *
     * @example
     * ```ts
     * a -| b
     * ```
     *
     * @since 1.0.0
     */

    MinusPipe,

    /**
     * The `*|` token.
     *
     * @example
     * ```ts
     * a *| b
     * ```
     *
     * @since 1.0.0
     */

    StarPipe,

    /**
     * The `++` token.
     *
     * @example
     * ```ts
     * i++;
     * ```
     *
     * @since 1.0.0
     */

    PlusPlus,

    /**
     * The `--` token.
     *
     * @example
     * ```ts
     * i--;
     * ```
     *
     * @since 1.0.0
     */

    MinusMinus,

    /**
     * The `==` token.
     *
     * @example
     * ```ts
     * a == b
     * ```
     *
     * @since 1.0.0
     */

    EqEq,

    /**
     * The `!=` token.
     *
     * @example
     * ```ts
     * a != b
     * ```
     *
     * @since 1.0.0
     */

    BangEq,

    /**
     * The `<` token.
     *
     * @example
     * ```ts
     * a < b
     * ```
     *
     * @since 1.0.0
     */

    Lt,

    /**
     * The `<=` token.
     *
     * @example
     * ```ts
     * a <= b
     * ```
     *
     * @since 1.0.0
     */

    LtEq,

    /**
     * The `>` token.
     *
     * @remarks
     * There is no `>>` token, so `>>` lexes as two of these and the parser joins them into a shift.
     * Nested generics such as `List<List<u8>>` then close without help from the parser.
     *
     * @example
     * ```ts
     * a > b
     * ```
     *
     * @since 1.0.0
     */

    Gt,

    /**
     * The `>=` token.
     *
     * @remarks
     * There is no `>>=` token, so `>>=` lexes as `>` and `>=`, and the parser joins them.
     *
     * @example
     * ```ts
     * a >= b
     * ```
     *
     * @since 1.0.0
     */

    GtEq,

    /**
     * The `&&` token.
     *
     * @example
     * ```ts
     * a && b
     * ```
     *
     * @since 1.0.0
     */

    AmpAmp,

    /**
     * The `||` token.
     *
     * @example
     * ```ts
     * a || b
     * ```
     *
     * @since 1.0.0
     */

    PipePipe,

    /**
     * The `&` token.
     *
     * @example
     * ```ts
     * a & b
     * ```
     *
     * @since 1.0.0
     */

    Amp,

    /**
     * The `|` token.
     *
     * @example
     * ```ts
     * a | b
     * ```
     *
     * @since 1.0.0
     */

    Pipe,

    /**
     * The `^` token.
     *
     * @example
     * ```ts
     * a ^ b
     * ```
     *
     * @since 1.0.0
     */

    Caret,

    /**
     * The `~` token.
     *
     * @example
     * ```ts
     * ~mask
     * ```
     *
     * @since 1.0.0
     */

    Tilde,

    /**
     * The `<<` token.
     *
     * @example
     * ```ts
     * a << 2
     * ```
     *
     * @since 1.0.0
     */

    LtLt,

    /**
     * The `as` keyword.
     *
     * @remarks
     * It is contextual, so it also serves as an identifier where a name is expected.
     *
     * @example
     * ```ts
     * len as u64
     * ```
     *
     * @since 1.0.0
     */

    KwAs,

    /**
     * The `break` keyword.
     *
     * @example
     * ```ts
     * break outer;
     * ```
     *
     * @since 1.0.0
     */

    KwBreak,

    /**
     * The `case` keyword.
     *
     * @example
     * ```ts
     * case .Admin: grant();
     * ```
     *
     * @since 1.0.0
     */

    KwCase,

    /**
     * The `catch` keyword.
     *
     * @example
     * ```ts
     * find(id) catch null
     * ```
     *
     * @since 1.0.0
     */

    KwCatch,

    /**
     * The `comptime` keyword.
     *
     * @example
     * ```ts
     * comptime fib(10)
     * ```
     *
     * @since 1.0.0
     */

    KwComptime,

    /**
     * The `const` keyword.
     *
     * @example
     * ```ts
     * const limit = 10;
     * ```
     *
     * @since 1.0.0
     */

    KwConst,

    /**
     * The `continue` keyword.
     *
     * @example
     * ```ts
     * continue;
     * ```
     *
     * @since 1.0.0
     */

    KwContinue,

    /**
     * The `default` keyword.
     *
     * @example
     * ```ts
     * default: deny();
     * ```
     *
     * @since 1.0.0
     */

    KwDefault,

    /**
     * The `defer` keyword.
     *
     * @example
     * ```ts
     * defer free(buffer);
     * ```
     *
     * @since 1.0.0
     */

    KwDefer,

    /**
     * The `dyn` keyword.
     *
     * @remarks
     * It is contextual, so it also serves as an identifier where a name is expected.
     *
     * @example
     * ```ts
     * let out: dyn Writer = file;
     * ```
     *
     * @since 1.0.0
     */

    KwDyn,

    /**
     * The `else` keyword.
     *
     * @example
     * ```ts
     * if (ok) a(); else b();
     * ```
     *
     * @since 1.0.0
     */

    KwElse,

    /**
     * The `enum` keyword.
     *
     * @example
     * ```ts
     * enum Role { Admin, User }
     * ```
     *
     * @since 1.0.0
     */

    KwEnum,

    /**
     * The `errdefer` keyword.
     *
     * @example
     * ```ts
     * errdefer free(buffer);
     * ```
     *
     * @since 1.0.0
     */

    KwErrdefer,

    /**
     * The `error` keyword.
     *
     * @remarks
     * It is contextual, so it also serves as an identifier where a name is expected.
     *
     * @example
     * ```ts
     * error DbError { NotFound }
     * ```
     *
     * @since 1.0.0
     */

    KwError,

    /**
     * The `export` keyword.
     *
     * @example
     * ```ts
     * export function main(): void {}
     * ```
     *
     * @since 1.0.0
     */

    KwExport,

    /**
     * The `extends` keyword.
     *
     * @remarks
     * It is contextual, so it also serves as an identifier where a name is expected.
     *
     * @example
     * ```ts
     * function max<T extends Ord>(a: T, b: T): T
     * ```
     *
     * @since 1.0.0
     */

    KwExtends,

    /**
     * The `extern` keyword.
     *
     * @example
     * ```ts
     * extern "C" function free(ptr: ?u8[*]): void;
     * ```
     *
     * @since 1.0.0
     */

    KwExtern,

    /**
     * The `false` keyword.
     *
     * @example
     * ```ts
     * const done = false;
     * ```
     *
     * @since 1.0.0
     */

    KwFalse,

    /**
     * The `for` keyword.
     *
     * @example
     * ```ts
     * for (let i = 0; i < n; i++) {}
     * ```
     *
     * @since 1.0.0
     */

    KwFor,

    /**
     * The `from` keyword.
     *
     * @remarks
     * It is contextual, so it also serves as an identifier where a name is expected.
     *
     * @example
     * ```ts
     * import { a } from "./a";
     * ```
     *
     * @since 1.0.0
     */

    KwFrom,

    /**
     * The `function` keyword.
     *
     * @example
     * ```ts
     * function add(a: i32, b: i32): i32
     * ```
     *
     * @since 1.0.0
     */

    KwFunction,

    /**
     * The `if` keyword.
     *
     * @example
     * ```ts
     * if (ready) start();
     * ```
     *
     * @since 1.0.0
     */

    KwIf,

    /**
     * The `import` keyword.
     *
     * @example
     * ```ts
     * import * as fmt from "std/fmt";
     * ```
     *
     * @since 1.0.0
     */

    KwImport,

    /**
     * The `interface` keyword.
     *
     * @example
     * ```ts
     * interface Writer { write(this: *Self, bytes: readonly u8[]): usize; }
     * ```
     *
     * @since 1.0.0
     */

    KwInterface,

    /**
     * The `let` keyword.
     *
     * @example
     * ```ts
     * let count = 0;
     * ```
     *
     * @since 1.0.0
     */

    KwLet,

    /**
     * The `null` keyword.
     *
     * @example
     * ```ts
     * let user: ?User = null;
     * ```
     *
     * @since 1.0.0
     */

    KwNull,

    /**
     * The `of` keyword.
     *
     * @remarks
     * It is contextual, so it also serves as an identifier where a name is expected.
     *
     * @example
     * ```ts
     * for (const item of items) {}
     * ```
     *
     * @since 1.0.0
     */

    KwOf,

    /**
     * The `readonly` keyword.
     *
     * @remarks
     * It is contextual, so it also serves as an identifier where a name is expected.
     *
     * @example
     * ```ts
     * function sum(xs: readonly i32[]): i32
     * ```
     *
     * @since 1.0.0
     */

    KwReadonly,

    /**
     * The `return` keyword.
     *
     * @example
     * ```ts
     * return a + b;
     * ```
     *
     * @since 1.0.0
     */

    KwReturn,

    /**
     * The `struct` keyword.
     *
     * @example
     * ```ts
     * struct Point { x: f32, y: f32 }
     * ```
     *
     * @since 1.0.0
     */

    KwStruct,

    /**
     * The `switch` keyword.
     *
     * @example
     * ```ts
     * switch (role) { default: deny(); }
     * ```
     *
     * @since 1.0.0
     */

    KwSwitch,

    /**
     * The `throw` keyword.
     *
     * @example
     * ```ts
     * throw DbError.NotFound;
     * ```
     *
     * @since 1.0.0
     */

    KwThrow,

    /**
     * The `true` keyword.
     *
     * @example
     * ```ts
     * const done = true;
     * ```
     *
     * @since 1.0.0
     */

    KwTrue,

    /**
     * The `try` keyword.
     *
     * @example
     * ```ts
     * const user = try find(id);
     * ```
     *
     * @since 1.0.0
     */

    KwTry,

    /**
     * The `type` keyword.
     *
     * @remarks
     * It is contextual, so it also serves as an identifier where a name is expected.
     *
     * @example
     * ```ts
     * type Bytes = u8[];
     * ```
     *
     * @since 1.0.0
     */

    KwType,

    /**
     * The `undefined` keyword.
     *
     * @example
     * ```ts
     * let buffer: u8[64] = undefined;
     * ```
     *
     * @since 1.0.0
     */

    KwUndefined,

    /**
     * The `union` keyword.
     *
     * @example
     * ```ts
     * union Shape { circle: f32, empty }
     * ```
     *
     * @since 1.0.0
     */

    KwUnion,

    /**
     * The `unreachable` keyword.
     *
     * @example
     * ```ts
     * default: unreachable;
     * ```
     *
     * @since 1.0.0
     */

    KwUnreachable,

    /**
     * The `unsafe` keyword.
     *
     * @example
     * ```ts
     * unsafe { ptr[i] = 0; }
     * ```
     *
     * @since 1.0.0
     */

    KwUnsafe,

    /**
     * The `void` keyword.
     *
     * @example
     * ```ts
     * void advance(p);
     * ```
     *
     * @since 1.0.0
     */

    KwVoid,

    /**
     * The `while` keyword.
     *
     * @example
     * ```ts
     * while (running) step();
     * ```
     *
     * @since 1.0.0
     */

    KwWhile,
}

/**
 * The name of each {@link TokenKind} without its prefix, which `helix tokens` prints.
 *
 * @remarks
 * The array is indexed by the kind, so its entries stay in the same order as the enum members.
 *
 * @example
 * ```ts
 * TOKEN_NAMES[TokenKind.KwConst as usize]; // 'KW_CONST'
 * TOKEN_NAMES[TokenKind.DotDot as usize];  // 'DOT_DOT'
 * ```
 *
 * @since 1.0.0
 */

export const TOKEN_NAMES: string[114] = [
    "EOF",
    "INVALID",
    "IDENT",
    "BUILTIN",
    "INT",
    "FLOAT",
    "STRING",
    "CHAR",
    "TEMPLATE_FULL",
    "TEMPLATE_HEAD",
    "TEMPLATE_MIDDLE",
    "TEMPLATE_TAIL",
    "LPAREN",
    "RPAREN",
    "LBRACE",
    "RBRACE",
    "LBRACKET",
    "RBRACKET",
    "COMMA",
    "SEMICOLON",
    "COLON",
    "DOT",
    "DOT_DOT",
    "DOT_DOT_EQ",
    "ELLIPSIS",
    "ARROW",
    "QUESTION",
    "QUESTION_DOT",
    "QUESTION_QUESTION",
    "QUESTION_QUESTION_EQ",
    "BANG",
    "EQ",
    "PLUS_EQ",
    "MINUS_EQ",
    "STAR_EQ",
    "SLASH_EQ",
    "PERCENT_EQ",
    "PLUS_PERCENT_EQ",
    "MINUS_PERCENT_EQ",
    "STAR_PERCENT_EQ",
    "PLUS_PIPE_EQ",
    "MINUS_PIPE_EQ",
    "STAR_PIPE_EQ",
    "AMP_EQ",
    "PIPE_EQ",
    "CARET_EQ",
    "LT_LT_EQ",
    "PLUS",
    "MINUS",
    "STAR",
    "SLASH",
    "PERCENT",
    "PLUS_PERCENT",
    "MINUS_PERCENT",
    "STAR_PERCENT",
    "PLUS_PIPE",
    "MINUS_PIPE",
    "STAR_PIPE",
    "PLUS_PLUS",
    "MINUS_MINUS",
    "EQ_EQ",
    "BANG_EQ",
    "LT",
    "LT_EQ",
    "GT",
    "GT_EQ",
    "AMP_AMP",
    "PIPE_PIPE",
    "AMP",
    "PIPE",
    "CARET",
    "TILDE",
    "LT_LT",
    "KW_AS",
    "KW_BREAK",
    "KW_CASE",
    "KW_CATCH",
    "KW_COMPTIME",
    "KW_CONST",
    "KW_CONTINUE",
    "KW_DEFAULT",
    "KW_DEFER",
    "KW_DYN",
    "KW_ELSE",
    "KW_ENUM",
    "KW_ERRDEFER",
    "KW_ERROR",
    "KW_EXPORT",
    "KW_EXTENDS",
    "KW_EXTERN",
    "KW_FALSE",
    "KW_FOR",
    "KW_FROM",
    "KW_FUNCTION",
    "KW_IF",
    "KW_IMPORT",
    "KW_INTERFACE",
    "KW_LET",
    "KW_NULL",
    "KW_OF",
    "KW_READONLY",
    "KW_RETURN",
    "KW_STRUCT",
    "KW_SWITCH",
    "KW_THROW",
    "KW_TRUE",
    "KW_TRY",
    "KW_TYPE",
    "KW_UNDEFINED",
    "KW_UNION",
    "KW_UNREACHABLE",
    "KW_UNSAFE",
    "KW_VOID",
    "KW_WHILE",
];

/**
 * The source spelling of each {@link TokenKind}, or a description where there is no fixed spelling.
 *
 * @remarks
 * Diagnostics use it in messages such as `expected ;, found identifier`.
 * The array is indexed by the kind, so its entries stay in the same order as the enum members.
 *
 * @example
 * ```ts
 * TOKEN_SPELLINGS[TokenKind.Arrow as usize]; // '=>'
 * TOKEN_SPELLINGS[TokenKind.Ident as usize]; // 'identifier'
 * ```
 *
 * @since 1.0.0
 */

export const TOKEN_SPELLINGS: string[114] = [
    "end of file",
    "invalid token",
    "identifier",
    "builtin",
    "integer literal",
    "float literal",
    "string literal",
    "character literal",
    "template literal",
    "template literal",
    "template literal",
    "template literal",
    "(",
    ")",
    "{",
    "}",
    "[",
    "]",
    ",",
    ";",
    ":",
    ".",
    "..",
    "..=",
    "...",
    "=>",
    "?",
    "?.",
    "??",
    "??=",
    "!",
    "=",
    "+=",
    "-=",
    "*=",
    "/=",
    "%=",
    "+%=",
    "-%=",
    "*%=",
    "+|=",
    "-|=",
    "*|=",
    "&=",
    "|=",
    "^=",
    "<<=",
    "+",
    "-",
    "*",
    "/",
    "%",
    "+%",
    "-%",
    "*%",
    "+|",
    "-|",
    "*|",
    "++",
    "--",
    "==",
    "!=",
    "<",
    "<=",
    ">",
    ">=",
    "&&",
    "||",
    "&",
    "|",
    "^",
    "~",
    "<<",
    "as",
    "break",
    "case",
    "catch",
    "comptime",
    "const",
    "continue",
    "default",
    "defer",
    "dyn",
    "else",
    "enum",
    "errdefer",
    "error",
    "export",
    "extends",
    "extern",
    "false",
    "for",
    "from",
    "function",
    "if",
    "import",
    "interface",
    "let",
    "null",
    "of",
    "readonly",
    "return",
    "struct",
    "switch",
    "throw",
    "true",
    "try",
    "type",
    "undefined",
    "union",
    "unreachable",
    "unsafe",
    "void",
    "while",
];

/**
 * The deepest that template literals may nest inside each other's substitutions.
 *
 * @remarks
 * Past this depth the lexer reports an error and treats the `${` as a plain brace, so the rest of the file stays balanced.
 *
 * @example
 * ```ts
 * MAX_TEMPLATE_DEPTH; // 64
 * ```
 *
 * @since 1.0.0
 */

export const MAX_TEMPLATE_DEPTH: u32 = 64;

/**
 * Every printable ASCII character in order, from the space to `~`.
 *
 * @remarks
 * Messages slice a single character out of it, which avoids allocating a one-byte string.
 *
 * @example
 * ```ts
 * PRINTABLE['#' - 32..'#' - 31]; // '#'
 * ```
 *
 * @since 1.0.0
 */

export const PRINTABLE = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
