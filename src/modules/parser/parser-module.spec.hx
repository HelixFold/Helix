/**
 * Imports
 */

import { Builder } from "std/fmt";
import { strlen, free } from "std/c";
import { hxDiagListFree } from "@models/diagnostic.model";
import { NodeKind, NoToken } from "@constants/ast.constant";
import { cAllocator, equal, startsWith, endsWith } from "std";
import { HxSource } from "@models/structs/source-model.struct";
import { hxAstPrint } from "@components/ast-printer.component";
import { HxArena } from "@services/structs/arena-service.struct";
import { HxAst, HxFnData } from "@models/structs/ast-model.struct";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxParse, hxParseModule } from "@modules/parser/parser.module";
import { hxLex, hxLexAppend, hxTokensFree } from "@modules/lexer/lexer.module";
import { addText, files, hxSourceFromString, hxSourceFree } from "@models/source.model";
import { hxAstInit, hxAstFree, node, extraAt, record, tokenText } from "@models/ast.model";

/**
 * The C library functions that capture the printed tree in memory.
 *
 * @since 1.0.0
 */

extern "C" function open_memstream(buf: *?u8[*], len: *usize): ?u8[*];
extern "C" function fclose(file: ?u8[*]): i32;

/**
 * Tests
 */

/**
 * A source, its tokens, its tree, and its diagnostics after one parse.
 *
 * @remarks
 * The `ok` field is true only when both the lexer and the parser succeed.
 * The tree points at the source and tokens stored beside it, so the state must not move after {@link parse} fills it.
 *
 * @since 1.0.0
 */

struct Parsed {
    src: HxSource,
    tokens: HxTokens,
    ast: HxAst,
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
 * Lexes and parses a text into a state that must stay where it is, since the tree points at its source and tokens.
 *
 * @param p - State that receives the source, tokens, tree, diagnostics, and result
 * @param text - Source text to parse, named `test.hx`
 *
 * @remarks
 * The parser runs even when the lexer fails, so the diagnostics can hold errors from both stages.
 *
 * @since 1.0.0
 */

function parse(p: *Parsed, text: string): void {
    p.diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&p.src, "test.hx", text.ptr, text.len);
    const lexed = hxLex(&p.src, &p.tokens, &p.diags);
    p.ok = hxParse(&p.src, &p.tokens, &p.ast, &p.diags) && lexed;
}

/**
 * Releases everything that one parse allocated.
 *
 * @param p - State that {@link parse} filled
 *
 * @remarks
 * It frees the tree, the tokens, the diagnostics, and the source, and leaves the state's own storage to the caller.
 *
 * @since 1.0.0
 */

function release(p: *Parsed): void {
    hxAstFree(&p.ast);
    hxTokensFree(&p.tokens);
    hxDiagListFree(&p.diags);
    hxSourceFree(&p.src);
}

/**
 * Every diagnostic, one per line, with its hint.
 *
 * @param p - State whose diagnostics to list
 * @returns The messages, each followed by a newline, in the shared output builder
 *
 * @remarks
 * A diagnostic with a hint prints it after the message as ` (hint: TEXT)`.
 * The result lives in the builder from {@link cleared}, so the next helper call overwrites it.
 *
 * @since 1.0.0
 */

function messages(p: readonly *Parsed): string {
    const b = cleared();
    for (const i of 0..p.diags.itemsLen) {
        unsafe {
            const d = p.diags.items![i];
            b.append(`${cString(d.message)}`) catch unreachable;
            if (const h = d.hint) b.append(` (hint: ${cString(h)})`) catch unreachable;
            b.append("\n") catch unreachable;
        }
    }
    return b.text();
}

/**
 * A node as a one-line S-expression.
 *
 * @param ast - Tree that holds the node
 * @param id - Index of the node to print
 * @returns The printed node without its trailing newline, in the shared output builder
 *
 * @remarks
 * The printer writes into an in-memory stream, which is copied into the builder from {@link cleared} and then freed.
 *
 * @since 1.0.0
 */

function printed(ast: readonly *HxAst, id: u32): string {
    let buf: ?u8[*] = null;
    let len: usize = 0;
    const file = open_memstream(&buf, &len);
    hxAstPrint(ast, id, file, false);
    void fclose(file);
    const b = cleared();
    unsafe {
        b.write(buf![0..len - 1]) catch unreachable;   // without the newline
    }
    free(buf);
    return b.text();
}

/**
 * An item of the child list of a node, or 0 past its end.
 *
 * @param ast - Tree that holds the node
 * @param id - Index of a node whose `a` and `b` fields bound a range of extra data
 * @param i - Position of the item within that range
 * @returns The node index stored at that position, or 0 when the position is past the end
 *
 * @remarks
 * The 0 result doubles as a sentinel, so a caller cannot tell an empty list from a stored 0.
 *
 * @since 1.0.0
 */

function listItem(ast: readonly *HxAst, id: u32, i: u32): u32 {
    const n = node(ast, id);
    return n.a + i < n.b ? extraAt(ast, n.a + i) : 0;
}

/**
 * The first declaration of a source, printed, or its errors when it does not parse.
 *
 * @param source - Source text of a whole file
 * @returns The first top-level item from {@link printed}, or the diagnostics from {@link messages}
 *
 * @remarks
 * Any further declarations still parse, but only the first one reaches the result.
 *
 * @since 1.0.0
 */

function decl(source: string): string {
    let p: Parsed = undefined;
    parse(&p, source);
    defer release(&p);
    if (!p.ok) return messages(&p);
    return printed(&p.ast, listItem(&p.ast, p.ast.root, 0));
}

/**
 * A statement parsed inside a function and printed, or its errors when it does not parse.
 *
 * @param statement - Source text of one statement
 * @returns The first statement of the body, printed, the diagnostics, or `(not a function)`
 *
 * @remarks
 * The statement is wrapped as `function f() { ... }` and copied into a 1024-byte buffer before parsing,
 * so a statement must fit in that buffer together with the wrapper.
 * The `(not a function)` result appears only when the first declaration is not a function.
 *
 * @since 1.0.0
 */

function stmt(statement: string): string {
    const b = cleared();
    b.append(`function f() { ${statement} }`) catch unreachable;
    let source: u8[1024] = undefined;
    for (const c, i of b.text()) source[i] = c;
    let p: Parsed = undefined;
    parse(&p, source[0..b.text().len]);
    defer release(&p);
    if (!p.ok) return messages(&p);
    const f = listItem(&p.ast, p.ast.root, 0);
    if (f == 0 || node(&p.ast, f).kind != NodeKind.Function) return "(not a function)";
    const body = record<HxFnData>(&p.ast, node(&p.ast, f).a).body;
    return printed(&p.ast, listItem(&p.ast, body, 0));
}

/**
 * The right-hand side of an assignment to x, printed.
 *
 * @param e - Source text of one expression
 * @returns The printed expression, or the whole result of {@link stmt} when it is not an assignment to `x`
 *
 * @remarks
 * The expression is parsed as the statement `x = e`, and the surrounding `(= x ` and `)` are stripped from the output.
 * The statement buffer holds 512 bytes, so a longer expression does not fit.
 *
 * @since 1.0.0
 */

function expr(e: string): string {
    const b = cleared();
    b.append(`x = ${e};`) catch unreachable;
    let statement: u8[512] = undefined;
    for (const c, i of b.text()) statement[i] = c;
    const whole = stmt(statement[0..b.text().len]);
    if (!startsWith(whole, "(= x ") || !endsWith(whole, ")")) return whole;
    return whole[5..whole.len - 1];
}

/**
 * The diagnostics that a source gives, one per line with hints, or an empty string when it parses.
 *
 * @param source - Source text of a whole file
 * @returns The diagnostics from {@link messages}, or an empty string when the lexer and the parser both succeed
 *
 * @remarks
 * Success comes from the results of both stages rather than from the diagnostic count.
 *
 * @since 1.0.0
 */

function errorsOf(source: string): string {
    let p: Parsed = undefined;
    parse(&p, source);
    defer release(&p);
    if (p.ok) return "";
    return messages(&p);
}

describe("hxParse") {
    describe("declarations") {
        test("should parse imports and re-exports") {
            expect(decl("import { a, b as c } from \"std\";")).toBe("(import \"std\" (a) (b as c))");
            expect(decl("import * as fs from \"std/fs\";")).toBe("(import \"std/fs\" * fs)");
            expect(decl("export { parse } from \"./parser\";")).toBe("(export-from \"./parser\" (parse))");
            expect(decl("export * from \"./types\";")).toBe("(export-from \"./types\" *)");
        }

        test("should parse const and let") {
            expect(decl("const MAX: usize = 1024;")).toBe("(const MAX usize 1024)");
            expect(decl("export let count = 0;")).toBe("(let :export count _ 0)");
            expect(decl("let buf: u8[256] = undefined;")).toBe("(let buf (array u8 256) undefined)");
        }

        test("should parse functions, generics and comptime parameters") {
            expect(decl("export function add(a: i32, b: i32): i32 { return a + b; }")).toBe("(function :export add (params (a i32) (b i32)) i32 (block (return (+ a b))))");
            expect(decl("function run() {}")).toBe("(function run (params) _ (block))");
            expect(decl("function max<T extends Numeric>(a: T, b: T): T { return a; }")).toBe("(function max (generics (T Numeric)) (params (a T) (b T)) T (block (return a)))");
            expect(decl("function repeat(comptime n: usize, s: string) {}")).toBe("(function repeat (params (comptime n usize) (s string)) _ (block))");
        }

        test("should parse extern functions, variadic ones too") {
            expect(decl("extern \"C\" function write(fd: i32, buf: readonly u8[*], n: usize): isize;")).toBe("(function :extern \"C\" write (params (fd i32) (buf (readonly (many-pointer u8))) (n usize)) isize)");
            expect(decl("extern \"C\" function printf(fmt: u8[*], ...): i32;")).toBe("(function :extern \"C\" printf (params (fmt (many-pointer u8))) i32 ...)");
        }

        test("should parse structs with fields, defaults and methods") {
            expect(decl("struct User { id: u32, email: ?string = null, rename(this: *User, n: string) {} }")).toBe("(struct User (field id u32) (field email (optional string) null) (function rename (params (this (pointer User)) (n string)) _ (block)))");
            expect(decl("struct Box<T> { value: T, map<U>(this: Box<T>): U {} }")).toBe("(struct Box (generics (T)) (field value T) (function map (generics (U)) (params (this (generic-of Box T))) U (block)))");
            expect(decl("enum Color { Red, Green = 2, name(this: Color) {} }")).toBe("(enum Color (member Red) (member Green 2) (function name (params (this Color)) _ (block)))");
            expect(decl("struct ArrayList<T> { items: T[] }")).toBe("(struct ArrayList (generics (T)) (field items (slice T)))");
            expect(decl("extern \"C\" struct Timespec { sec: i64; nsec: i64 }")).toBe("(struct :extern Timespec (field sec i64) (field nsec i64))");
        }

        test("should parse enums, unions and error sets") {
            expect(decl("enum Role { Admin, Member, Guest }")).toBe("(enum Role (member Admin) (member Member) (member Guest))");
            expect(decl("enum Color: u8 { Red = 1, Blue = 4, }")).toBe("(enum Color u8 (member Red 1) (member Blue 4))");
            expect(decl("union Event { click: Point, key: struct { code: u32, shift: bool }, quit }")).toBe("(union Event (variant click Point) (variant key (struct-type (field code u32) (field shift bool))) (variant quit))");
            expect(decl("error DbError { NotFound, Timeout }")).toBe("(error DbError NotFound Timeout)");
        }

        test("should parse interfaces and type aliases") {
            expect(decl("interface Writer { write(this: *Self, bytes: readonly u8[]): usize | IoError; }")).toBe("(interface Writer (function write (params (this (pointer Self)) (bytes (readonly (slice u8)))) (error-union usize IoError)))");
            expect(decl("type string = readonly u8[];")).toBe("(type string (readonly (slice u8)))");
            expect(decl("type Handler = (req: *Request) => Response | HttpError;")).toBe("(type Handler (fn-type (params (req (pointer Request))) (error-union Response HttpError)))");
        }

        test("should parse a comptime block") {
            expect(decl("comptime { assert(@sizeOf(Header) == 16); }")).toBe("(comptime-block (block (call assert (== (@sizeOf Header) 16))))");
        }
    }

    describe("types") {
        test("should bind ?, * and [] in types as written") {
            expect(decl("let a: ?u8[];")).toBe("(let a (optional (slice u8)) _)");
            expect(decl("let a: (?u8)[];")).toBe("(let a (slice (optional u8)) _)");
            expect(decl("let a: *User[];")).toBe("(let a (pointer (slice User)) _)");
            expect(decl("let a: (*User)[];")).toBe("(let a (slice (pointer User)) _)");
            expect(decl("let a: ?*User | DbError;")).toBe("(let a (error-union (optional (pointer User)) DbError) _)");
        }

        test("should read multi-dimensional arrays in C order") {
            expect(decl("let grid: f32[3][4];")).toBe("(let grid (array (array f32 4) 3) _)");
            expect(decl("let rows: u8[4][];")).toBe("(let rows (slice (array u8 4)) _)");
        }

        test("should parse generic and member types") {
            expect(decl("let m: HashMap<string, ArrayList<u8>>;")).toBe("(let m (generic-of HashMap string (generic-of ArrayList u8)) _)");
            expect(decl("let e: Allocator.Error;")).toBe("(let e (. Allocator Error) _)");
        }
    }

    describe("expressions") {
        test("should follow operator precedence") {
            expect(expr("a + b * c")).toBe("(+ a (* b c))");
            expect(expr("a - b - c")).toBe("(- (- a b) c)");
            expect(expr("a || b && c")).toBe("(|| a (&& b c))");
            expect(expr("flags & MASK == 0")).toBe("(== (& flags MASK) 0)");
            expect(expr("a ?? b ?? c")).toBe("(?? a (?? b c))");
            expect(expr("a +% b *| c")).toBe("(+% a (*| b c))");
            expect(expr("-a * b")).toBe("(* (neg a) b)");
            expect(expr("a * b as u64")).toBe("(* a (as b u64))");
        }

        test("should join > > into a shift") {
            expect(expr("a >> 2")).toBe("(>> a 2)");
            expect(expr("a << 2 >> 1")).toBe("(>> (<< a 2) 1)");
            expect(expr("a > b")).toBe("(> a b)");
        }

        test("should nest ternaries to the right") {
            expect(expr("x < lo ? lo : x > hi ? hi : x")).toBe("(? (< x lo) lo (? (> x hi) hi x))");
        }

        test("should parse optional operators") {
            expect(expr("email ?? \"none\"")).toBe("(?? email \"none\")");
            expect(expr("user.email?.len")).toBe("(?. (. user email) len)");
            expect(expr("email!")).toBe("(unwrap email)");
            expect(expr("!ready")).toBe("(not ready)");
        }

        test("should parse calls, indexing, slices and member access") {
            expect(expr("f(a, b,)")).toBe("(call f a b)");
            expect(expr("a.b.c(1)[2]")).toBe("(index (call (. (. a b) c) 1) 2)");
            expect(expr("buf[0..n]")).toBe("(slice-of buf 0 n)");
            expect(expr("buf[2..]")).toBe("(slice-of buf 2 _)");
            expect(expr("buf[..=n]")).toBe("(slice-of= buf _ n)");
            expect(expr("&list.items[0]")).toBe("(addr (index (. list items) 0))");
            expect(expr("x.type")).toBe("(. x type)");
        }

        test("should tell generic arguments from comparisons") {
            expect(expr("ArrayList<u8>.init(gpa)")).toBe("(call (. (generic-of ArrayList u8) init) gpa)");
            expect(expr("HashMap<string, User>.init(gpa)")).toBe("(call (. (generic-of HashMap string User) init) gpa)");
            expect(expr("a < b && c > d")).toBe("(&& (< a b) (> c d))");
            expect(expr("f(a < b, c > d)")).toBe("(call f (< a b) (> c d))");
        }

        test("should parse struct, array, enum and template literals") {
            expect(expr("User { id: 1, name }")).toBe("(struct-literal User (id 1) (name name))");
            expect(expr("{ x: 1, y: 2 }")).toBe("(struct-literal _ (x 1) (y 2))");
            expect(expr("[1, 2, 3]")).toBe("(array-literal 1 2 3)");
            expect(expr(".Admin")).toBe(".Admin");
            expect(expr("Event.click(Point { x: 1, y: 2 })")).toBe("(call (. Event click) (struct-literal Point (x 1) (y 2)))");
            expect(expr("`id-${id}`")).toBe("(template `id-${ id }`)");
        }

        test("should take types as builtin arguments") {
            expect(expr("@sizeOf(Header)")).toBe("(@sizeOf Header)");
            expect(expr("@ptrCast(u8[*], raw)")).toBe("(@ptrCast (many-pointer u8) raw)");
            expect(expr("@sizeOf(?u8)")).toBe("(@sizeOf (optional u8))");
        }

        test("should parse try and catch") {
            expect(expr("try load(a)")).toBe("(try (call load a))");
            expect(expr("parse(s) catch 8080")).toBe("(catch (call parse s) _ 8080)");
            expect(expr("parse(s) catch (fallback) + 1")).toBe("(catch (call parse s) _ (+ fallback 1))");
            expect(expr("open(p) catch (e) { throw e; }")).toBe("(catch (call open p) e (block (throw e)))");
            expect(expr("parse(s) catch (e) switch (e) { case ParseError.Empty: 0; default: throw e; }")).toBe("(catch (call parse s) e (switch-expr e (case ((. ParseError Empty)) 0) (default (throw e))))");
        }

        test("should parse comptime expressions and import()") {
            expect(expr("comptime target.os == Os.Linux ? import(\"./linux\") : import(\"./macos\")")).toBe("(comptime (? (== (. target os) (. Os Linux)) (import \"./linux\") (import \"./macos\")))");
        }

        test("should tell arrow functions from parenthesized expressions") {
            expect(expr("(a: i32, b: i32): bool => a < b")).toBe("(arrow (params (a i32) (b i32)) bool (< a b))");
            expect(expr("(): void => {}")).toBe("(arrow (params) void (block))");
            expect(expr("(a + b) * c")).toBe("(* (+ a b) c)");
        }
    }

    describe("statements") {
        test("should parse every assignment form") {
            expect(stmt("x += 1;")).toBe("(+= x 1)");
            expect(stmt("total +%= i * 2;")).toBe("(+%= total (* i 2))");
            expect(stmt("x >>= 1;")).toBe("(>>= x 1)");
            expect(stmt("x ??= y;")).toBe("(??= x y)");
            expect(stmt("*user = u;")).toBe("(= (deref user) u)");
            expect(stmt("i++;")).toBe("(++ i)");
        }

        test("should parse void as a discard") {
            expect(stmt("void compute();")).toBe("(void (call compute))");
        }

        test("should parse if, while, for and labels") {
            expect(stmt("if (x > 0) a(); else if (x < 0) b(); else c();")).toBe("(if (> x 0) (call a) (if (< x 0) (call b) (call c)))");
            expect(stmt("if (const v = find()) use(v);")).toBe("(if (const v (call find)) (call use v))");
            expect(stmt("while (const item = it.next()) {}")).toBe("(while (const item (call (. it next))) (block))");
            expect(stmt("for (let i: usize = 0; i < n; i++) {}")).toBe("(for (let i usize 0) (< i n) (++ i) (block))");
            expect(stmt("for (const x of items) {}")).toBe("(for-of x items (block))");
            expect(stmt("for (const x, i of items) {}")).toBe("(for-of x i items (block))");
            expect(stmt("for (const i of 0..=n) {}")).toBe("(for-of i (..= 0 n) (block))");
            expect(stmt("outer: for (const r of rows) { continue outer; }")).toBe("(for-of :label outer r rows (block (continue outer)))");
        }

        test("should parse defer and errdefer") {
            expect(stmt("defer file.close();")).toBe("(defer (call (. file close)))");
            expect(stmt("defer { a(); b(); }")).toBe("(defer (block (call a) (call b)))");
            expect(stmt("errdefer a.free(buf);")).toBe("(errdefer (call (. a free) buf))");
            expect(stmt("errdefer (e) { log(e); }")).toBe("(errdefer e (block (call log e)))");
            expect(stmt("defer file.flush() catch (e) log.warn(e);")).toBe("(defer (catch (call (. file flush)) e (call (. log warn) e)))");
        }

        test("should parse an unsafe block") {
            expect(stmt("unsafe { p[10] = 0; }")).toBe("(unsafe (block (= (index p 10) 0)))");
        }
    }

    describe("switch") {
        test("should parse a switch statement") {
            expect(stmt("switch (code) { case 0: ok(); case 1: case 2: warn(); default: fail(); }")).toBe("(switch code (case (0) (block (call ok))) (case (1) (block)) (case (2) (block (call warn))) (default (block (call fail))))");
        }

        test("should parse switch patterns and guards") {
            expect(expr("switch (code) { case 400..=499: 1; case n if n >= 500: 2; default: 0; }")).toBe("(switch-expr code (case ((..= 400 499)) 1) (case ((bind n)) (if (>= n 500)) 2) (default 0))");
            expect(expr("switch (r) { case Role.Admin: 1; case .Member, .Guest: 2; }")).toBe("(switch-expr r (case ((. Role Admin)) 1) (case (.Member .Guest) 2))");
            expect(stmt("switch (e) { case Event.key({ code, shift }): f(); case .resize(*r): g(); }")).toBe("(switch e (case ((tag (. Event key) (pstruct (code) (shift)))) (block (call f))) (case ((tag .resize (bind *r))) (block (call g))))");
            expect(expr("switch (p) { case { x: 0, y: 0 }: 1; case { x, y } if x == y: 2; default: 3; }")).toBe("(switch-expr p (case ((pstruct (x 0) (y 0))) 1) (case ((pstruct (x) (y))) (if (== x y)) 2) (default 3))");
            expect(expr("switch (m) { case \"GET\": 1; case -1: 2; default: 3; }")).toBe("(switch-expr m (case (\"GET\") 1) (case ((neg 1)) 2) (default 3))");
        }
    }

    describe("errors and recovery") {
        test("should report a missing semicolon") {
            expect(errorsOf("const x = 1\nconst y = 2;")).toInclude("expected `;` after the declaration");
        }

        test("should report a parameter without a type") {
            expect(errorsOf("function f(a) {}")).toInclude("parameter `a` needs a type");
            expect(errorsOf("function f(a) {}")).toInclude("a: i32");
        }

        test("should report a chained comparison") {
            expect(errorsOf("function f() { x = a < b < c; }")).toInclude("cannot be chained");
            expect(errorsOf("function f() { x = a < b < c; }")).toInclude("&&");
        }

        test("should report a default import") {
            expect(errorsOf("import fs from \"std/fs\";")).toInclude("no default imports");
            expect(errorsOf("import fs from \"std/fs\";")).toInclude("import * as fs");
        }

        test("should report a statement at the top level") {
            expect(errorsOf("print(1);")).toInclude("expected a declaration");
            expect(errorsOf("print(1);")).toInclude("inside a function");
        }

        test("should report `function` on a method") {
            expect(errorsOf("struct P { function f() {} }")).toInclude("methods are written without `function`");
            expect(errorsOf("struct P { function f() {} }")).toInclude("TypeScript class");
            expect(errorsOf("interface I { function f(); }")).toInclude("methods are written without `function`");
        }

        test("should report a function inside a function") {
            expect(errorsOf("function f() { function g() {} }")).toInclude("can't be declared inside a function");
            expect(errorsOf("function f() { function g() {} }")).toInclude("arrow");
        }

        test("should report `=>` after a case") {
            expect(errorsOf("function f() { switch (x) { case 1 => a(); } }")).toInclude("use `:`");
        }

        test("should report a block that is never closed") {
            expect(errorsOf("function f() { if (x) {")).toInclude("never closed");
        }

        test("should recover inside a statement and report each mistake once") {
            let p: Parsed = undefined;
            parse(&p, "function f() { let = 1; x = ; y = 2; }");
            defer release(&p);
            expect(p.diags.errorCount).toBe(2);
        }

        test("should recover at the next declaration") {
            let p: Parsed = undefined;
            parse(&p, "function broken( { }\nfunction ok(): i32 { return 1; }");
            defer release(&p);
            expect(p.ok).toBeFalse();
            const file = node(&p.ast, p.ast.root);
            let found = false;
            for (const i of file.a..file.b) {
                const d = node(&p.ast, extraAt(&p.ast, i));
                if (d.kind == NodeKind.Function && d.token != NoToken && equal(tokenText(&p.ast, d.token), "ok")) found = true;
            }
            expect(found).toBeTrue();
        }

        test("should stop at deep nesting instead of overflowing the stack") {
            let source: u8[640] = undefined;
            const start = "function f() { x = ";
            for (const c, i of start) source[i] = c;
            for (const i of 0..600) source[start.len + i] = '(';
            const end = "1;}";
            for (const c, i of end) source[start.len + 600 + i] = c;
            expect(errorsOf(source[0..start.len + 600 + end.len])).toInclude("nested too deeply");
        }
    }
}

describe("hxParseModule") {
    test("should parse each file of a program up to its own end of file") {
        let p: Parsed = undefined;
        p.diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
        hxSourceFromString(&p.src, "a.hx", "const a = 1;", 12);
        void addText(&p.src, "b.hx", "const b = 2; const c = 3;");
        p.tokens = HxTokens { kinds: null, starts: null, lens: null, len: 0, cap: 0, docs: null, docsLen: 0, docsCap: 0 };
        unsafe {
            void hxLexAppend(&p.src, files(&p.src)[0].start, files(&p.src)[0].end, &p.tokens, &p.diags);
            void hxLexAppend(&p.src, files(&p.src)[1].start, files(&p.src)[1].end, &p.tokens, &p.diags);
        }
        hxAstInit(&p.ast, &p.src, &p.tokens);
        defer release(&p);
        let ok = true;
        const first = hxParseModule(&p.ast, 0, &p.diags, &ok);
        const second = hxParseModule(&p.ast, 6, &p.diags, &ok);

        expect(ok).toBeTrue();
        expect(printed(&p.ast, first)).toBe("(file (const a _ 1))");
        expect(printed(&p.ast, second)).toBe("(file (const b _ 2) (const c _ 3))");
    }

    test("should clear the flag after an error and leave it alone otherwise") {
        let p: Parsed = undefined;
        parse(&p, "const a = ;");
        defer release(&p);
        let ok = true;
        void hxParseModule(&p.ast, 0, &p.diags, &ok);

        expect(ok).toBeFalse();
    }
}
