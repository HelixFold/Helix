/**
 * The kind of a syntax tree node.
 *
 * @remarks
 * Each value fits in one byte, and the order matches {@link NODE_NAMES}, which holds the printed name of each kind.
 * Members are grouped by role: declarations, type expressions, literals, expressions, patterns, statements,
 * and test items.
 *
 * @example
 * ```ts
 * const kind = NodeKind.FieldAccess;
 * NODE_NAMES[kind]; // '.'
 * ```
 *
 * @since 1.0.0
 */

export enum NodeKind: u8 {
    /**
     * The empty kind that marks the reserved node at index 0.
     *
     * @remarks
     * A child slot that holds 0 points at this node, so 0 means the child is absent.
     *
     * @example
     * ```ts
     * if (ready) start();   // without an else branch, its slot holds 0
     * ```
     *
     * @since 1.0.0
     */

    None,

    /**
     * A placeholder that the parser leaves where it could not read a construct.
     *
     * @example
     * ```ts
     * const x = ;   // the missing value parses as Invalid
     * ```
     *
     * @since 1.0.0
     */

    Invalid,

    /**
     * The root of one parsed source file.
     *
     * @remarks
     * Its children are the top-level declarations in source order.
     *
     * @example
     * ```ts
     * // main.hx parses into a single File node
     * ```
     *
     * @since 1.0.0
     */

    File,

    /**
     * An `import` declaration or an `export ... from` re-export.
     *
     * @example
     * ```ts
     * import { a, b as c } from "./x";
     * import * as ns from "./x";
     * import "./x";
     * ```
     *
     * @since 1.0.0
     */

    Import,

    /**
     * One name inside the braces of an import, with its optional alias.
     *
     * @example
     * ```ts
     * import { a, b as c } from "./x";   // a and b as c
     * ```
     *
     * @since 1.0.0
     */

    ImportSpec,

    /**
     * A `const` declaration.
     *
     * @example
     * ```ts
     * const limit = 10;
     * ```
     *
     * @since 1.0.0
     */

    Const,

    /**
     * A `let` declaration.
     *
     * @example
     * ```ts
     * let count: u32 = 0;
     * ```
     *
     * @since 1.0.0
     */

    Let,

    /**
     * A function declaration, a method included.
     *
     * @remarks
     * An `extern` function and an interface member have no body.
     *
     * @example
     * ```ts
     * function add(a: i32, b: i32): i32 { return a + b; }
     * ```
     *
     * @since 1.0.0
     */

    Function,

    /**
     * One parameter of a function, an arrow function, or a function type.
     *
     * @example
     * ```ts
     * function add(a: i32, b: i32): i32   // a and b
     * ```
     *
     * @since 1.0.0
     */

    Param,

    /**
     * One type parameter of a generic declaration.
     *
     * @example
     * ```ts
     * function max<T>(a: T, b: T): T   // T
     * ```
     *
     * @since 1.0.0
     */

    GenericParam,

    /**
     * A `struct` declaration.
     *
     * @example
     * ```ts
     * struct Point { x: f32, y: f32 }
     * ```
     *
     * @since 1.0.0
     */

    Struct,

    /**
     * One field of a struct or of an anonymous struct type.
     *
     * @example
     * ```ts
     * struct Point { x: f32 = 0, y: f32 }   // x and y
     * ```
     *
     * @since 1.0.0
     */

    FieldDecl,

    /**
     * An `enum` declaration with an optional backing type.
     *
     * @example
     * ```ts
     * enum Role: u8 { Admin, User }
     * ```
     *
     * @since 1.0.0
     */

    Enum,

    /**
     * One member of an enum.
     *
     * @example
     * ```ts
     * enum Role: u8 { Admin, User }   // Admin and User
     * ```
     *
     * @since 1.0.0
     */

    EnumMember,

    /**
     * A tagged `union` declaration.
     *
     * @example
     * ```ts
     * union Shape { circle: f32, square: f32, empty }
     * ```
     *
     * @since 1.0.0
     */

    Union,

    /**
     * One variant of a union, with an optional payload type.
     *
     * @example
     * ```ts
     * union Shape { circle: f32, empty }   // circle and empty
     * ```
     *
     * @since 1.0.0
     */

    UnionVariant,

    /**
     * An `error` declaration that names a set of errors.
     *
     * @example
     * ```ts
     * error DbError { NotFound, Timeout }
     * ```
     *
     * @since 1.0.0
     */

    ErrorSet,

    /**
     * One error inside an error set.
     *
     * @example
     * ```ts
     * error DbError { NotFound, Timeout }   // NotFound and Timeout
     * ```
     *
     * @since 1.0.0
     */

    ErrorMember,

    /**
     * An `interface` declaration, whose members are method signatures.
     *
     * @example
     * ```ts
     * interface Writer { write(this: *Self, bytes: readonly u8[]): usize | IoError; }
     * ```
     *
     * @since 1.0.0
     */

    Interface,

    /**
     * A `type` declaration that gives a name to another type.
     *
     * @example
     * ```ts
     * type Bytes = u8[];
     * ```
     *
     * @since 1.0.0
     */

    TypeAlias,

    /**
     * A `comptime` block, which runs while the program compiles.
     *
     * @remarks
     * {@link NodeKind.ComptimeExpr} is the expression form.
     *
     * @example
     * ```ts
     * comptime { const size = @sizeOf(Point); }
     * ```
     *
     * @since 1.0.0
     */

    ComptimeBlock,

    /**
     * An optional type, written with a leading `?`.
     *
     * @example
     * ```ts
     * let user: ?User = null;
     * ```
     *
     * @since 1.0.0
     */

    TypeOptional,

    /**
     * A single-item pointer type, written with a leading `*`.
     *
     * @example
     * ```ts
     * function reset(p: *Point): void
     * ```
     *
     * @since 1.0.0
     */

    TypePointer,

    /**
     * A `readonly` type, which forbids writes through it.
     *
     * @example
     * ```ts
     * function sum(xs: readonly i32[]): i32
     * ```
     *
     * @since 1.0.0
     */

    TypeReadonly,

    /**
     * A `dyn` type, which holds any value that implements an interface.
     *
     * @example
     * ```ts
     * let out: dyn Writer = file;
     * ```
     *
     * @since 1.0.0
     */

    TypeDyn,

    /**
     * A slice type, written with an empty `[]` suffix.
     *
     * @example
     * ```ts
     * let bytes: u8[] = buffer[0..4];
     * ```
     *
     * @since 1.0.0
     */

    TypeSlice,

    /**
     * A fixed-size array type, written with a length suffix.
     *
     * @remarks
     * A run of sizes reads in C order, so `f32[3][4]` holds 3 rows of 4.
     *
     * @example
     * ```ts
     * let grid: f32[3][4] = undefined;
     * ```
     *
     * @since 1.0.0
     */

    TypeArray,

    /**
     * A pointer to an unknown number of items, written with a `[*]` suffix.
     *
     * @example
     * ```ts
     * extern "C" function strlen(s: readonly u8[*]): usize;
     * ```
     *
     * @since 1.0.0
     */

    TypeManyPointer,

    /**
     * An error union type, which holds either a value or an error.
     *
     * @example
     * ```ts
     * function find(id: u32): *User | DbError
     * ```
     *
     * @since 1.0.0
     */

    TypeErrorUnion,

    /**
     * A function type, written as a parameter list and a return type.
     *
     * @example
     * ```ts
     * let compare: (a: i32, b: i32) => bool = less;
     * ```
     *
     * @since 1.0.0
     */

    TypeFunction,

    /**
     * An anonymous struct type.
     *
     * @example
     * ```ts
     * let pair: struct { a: i32, b: i32 } = undefined;
     * ```
     *
     * @since 1.0.0
     */

    TypeStruct,

    /**
     * An identifier that names a value or a type.
     *
     * @example
     * ```ts
     * count + 1   // count
     * ```
     *
     * @since 1.0.0
     */

    Ident,

    /**
     * An integer literal.
     *
     * @example
     * ```ts
     * 0xFF;
     * ```
     *
     * @since 1.0.0
     */

    Int,

    /**
     * A floating-point literal.
     *
     * @example
     * ```ts
     * 3.14;
     * ```
     *
     * @since 1.0.0
     */

    Float,

    /**
     * A string literal.
     *
     * @example
     * ```ts
     * "hello";
     * ```
     *
     * @since 1.0.0
     */

    String,

    /**
     * A character literal.
     *
     * @example
     * ```ts
     * 'a';
     * ```
     *
     * @since 1.0.0
     */

    Char,

    /**
     * The `true` literal.
     *
     * @example
     * ```ts
     * const ready = true;
     * ```
     *
     * @since 1.0.0
     */

    True,

    /**
     * The `false` literal.
     *
     * @example
     * ```ts
     * const ready = false;
     * ```
     *
     * @since 1.0.0
     */

    False,

    /**
     * The `null` literal, which is the empty value of an optional.
     *
     * @example
     * ```ts
     * let user: ?User = null;
     * ```
     *
     * @since 1.0.0
     */

    Null,

    /**
     * The `undefined` literal, which leaves memory uninitialized.
     *
     * @example
     * ```ts
     * let buffer: u8[64] = undefined;
     * ```
     *
     * @since 1.0.0
     */

    Undefined,

    /**
     * The `unreachable` literal, which marks code that never runs.
     *
     * @example
     * ```ts
     * default: unreachable;
     * ```
     *
     * @since 1.0.0
     */

    Unreachable,

    /**
     * A template literal, with its text and interpolated values as children.
     *
     * @example
     * ```ts
     * `hello ${name}!`
     * ```
     *
     * @since 1.0.0
     */

    Template,

    /**
     * One literal text segment of a template literal.
     *
     * @example
     * ```ts
     * `hello ${name}!`   // hello and !
     * ```
     *
     * @since 1.0.0
     */

    TemplateText,

    /**
     * An enum member written without its type, as a leading `.` and a name.
     *
     * @example
     * ```ts
     * const role: Role = .Admin;
     * ```
     *
     * @since 1.0.0
     */

    EnumLiteral,

    /**
     * A call to a compiler builtin, whose name starts with `@`.
     *
     * @example
     * ```ts
     * @sizeOf(Point);
     * ```
     *
     * @since 1.0.0
     */

    BuiltinCall,

    /**
     * An `import(...)` expression, which yields a module as a value.
     *
     * @example
     * ```ts
     * const math = import("./math");
     * ```
     *
     * @since 1.0.0
     */

    ImportExpr,

    /**
     * A function call.
     *
     * @example
     * ```ts
     * add(1, 2);
     * ```
     *
     * @since 1.0.0
     */

    Call,

    /**
     * An index into an array, a slice, or a pointer.
     *
     * @example
     * ```ts
     * items[i];
     * ```
     *
     * @since 1.0.0
     */

    Index,

    /**
     * A slice of an array, a slice, or a pointer, taken over a range.
     *
     * @remarks
     * Either bound may be left out, and `..=` makes the end inclusive.
     *
     * @example
     * ```ts
     * items[1..3];
     * items[2..];
     * ```
     *
     * @since 1.0.0
     */

    Slice,

    /**
     * A field or member access with `.`.
     *
     * @example
     * ```ts
     * point.x;
     * ```
     *
     * @since 1.0.0
     */

    FieldAccess,

    /**
     * A field access with `?.`, which yields `null` when the base is `null`.
     *
     * @example
     * ```ts
     * user?.name;
     * ```
     *
     * @since 1.0.0
     */

    OptionalField,

    /**
     * A postfix `!` that unwraps an optional.
     *
     * @example
     * ```ts
     * user!;
     * ```
     *
     * @since 1.0.0
     */

    Unwrap,

    /**
     * A generic name with explicit type arguments.
     *
     * @example
     * ```ts
     * max<i64>(a, b);
     * ```
     *
     * @since 1.0.0
     */

    GenericInstance,

    /**
     * A struct literal, with an optional type in front of the braces.
     *
     * @example
     * ```ts
     * Point { x: 1, y: 2 };
     * const p: Point = { x, y };
     * ```
     *
     * @since 1.0.0
     */

    StructLiteral,

    /**
     * One field initializer inside a struct literal.
     *
     * @example
     * ```ts
     * Point { x: 1, y }   // x: 1 and y
     * ```
     *
     * @since 1.0.0
     */

    FieldInit,

    /**
     * An array literal.
     *
     * @example
     * ```ts
     * [1, 2, 3];
     * ```
     *
     * @since 1.0.0
     */

    ArrayLiteral,

    /**
     * A unary `-`.
     *
     * @example
     * ```ts
     * -x;
     * ```
     *
     * @since 1.0.0
     */

    Negate,

    /**
     * A logical `!`.
     *
     * @example
     * ```ts
     * !done;
     * ```
     *
     * @since 1.0.0
     */

    Not,

    /**
     * A bitwise `~`.
     *
     * @example
     * ```ts
     * ~mask;
     * ```
     *
     * @since 1.0.0
     */

    BitNot,

    /**
     * A unary `&`, which takes the address of its operand.
     *
     * @example
     * ```ts
     * &point;
     * ```
     *
     * @since 1.0.0
     */

    AddressOf,

    /**
     * A unary `*`, which reads through a pointer.
     *
     * @example
     * ```ts
     * *ptr;
     * ```
     *
     * @since 1.0.0
     */

    Deref,

    /**
     * A `try` expression, which returns the error of an error union to the caller.
     *
     * @example
     * ```ts
     * const user = try find(id);
     * ```
     *
     * @since 1.0.0
     */

    Try,

    /**
     * A `comptime` expression, which the compiler evaluates while it compiles.
     *
     * @remarks
     * {@link NodeKind.ComptimeBlock} is the block form.
     *
     * @example
     * ```ts
     * const size = comptime fib(10);
     * ```
     *
     * @since 1.0.0
     */

    ComptimeExpr,

    /**
     * A `void` expression, which evaluates its operand and drops the result.
     *
     * @example
     * ```ts
     * void advance(p);
     * ```
     *
     * @since 1.0.0
     */

    Discard,

    /**
     * A binary operation, with its operator held as a {@link BinOp}.
     *
     * @example
     * ```ts
     * a + b;
     * ```
     *
     * @since 1.0.0
     */

    Binary,

    /**
     * An `as` cast.
     *
     * @remarks
     * It binds tighter than any binary operator, so `a * b as u64` reads as `a * (b as u64)`.
     *
     * @example
     * ```ts
     * len as u64;
     * ```
     *
     * @since 1.0.0
     */

    Cast,

    /**
     * A conditional expression with `?` and `:`.
     *
     * @example
     * ```ts
     * ok ? 1 : 0;
     * ```
     *
     * @since 1.0.0
     */

    Ternary,

    /**
     * A `catch` expression, which supplies a fallback when its left side yields an error.
     *
     * @remarks
     * The body may be a block or an expression, and it may capture the error by name.
     *
     * @example
     * ```ts
     * find(id) catch null;
     * find(id) catch (e) { log(e); return; }
     * ```
     *
     * @since 1.0.0
     */

    Catch,

    /**
     * A range of integers that a `for-of` loop walks.
     *
     * @remarks
     * `..` leaves the end out, and `..=` takes it in.
     *
     * @example
     * ```ts
     * for (const i of 0..n) {}
     * ```
     *
     * @since 1.0.0
     */

    Range,

    /**
     * An arrow function expression.
     *
     * @example
     * ```ts
     * const twice = (x: i32): i32 => x * 2;
     * ```
     *
     * @since 1.0.0
     */

    ArrowFunction,

    /**
     * A `switch`, in either its statement or its expression form.
     *
     * @example
     * ```ts
     * switch (role) { case .Admin: grant(); default: deny(); }
     * ```
     *
     * @since 1.0.0
     */

    Switch,

    /**
     * One `case` of a switch, with its patterns, an optional guard, and its body.
     *
     * @example
     * ```ts
     * case .Admin, .Owner: grant();
     * ```
     *
     * @since 1.0.0
     */

    Case,

    /**
     * The `default` case of a switch.
     *
     * @example
     * ```ts
     * default: deny();
     * ```
     *
     * @since 1.0.0
     */

    DefaultCase,

    /**
     * A pattern that binds the matched value to a name.
     *
     * @remarks
     * A leading `*` binds a pointer to the value instead of a copy.
     *
     * @example
     * ```ts
     * case .circle(r): area(r);
     * case .circle(*r): grow(r);
     * ```
     *
     * @since 1.0.0
     */

    PatternBind,

    /**
     * A pattern that matches the fields of a struct.
     *
     * @example
     * ```ts
     * case { x: 0, y }: onAxis(y);
     * ```
     *
     * @since 1.0.0
     */

    PatternStruct,

    /**
     * One field inside a struct pattern, with an optional sub-pattern.
     *
     * @example
     * ```ts
     * case { x: 0, y }: onAxis(y);   // x: 0 and y
     * ```
     *
     * @since 1.0.0
     */

    PatternField,

    /**
     * A pattern that matches a union variant and its payload.
     *
     * @example
     * ```ts
     * case .circle(r): area(r);
     * ```
     *
     * @since 1.0.0
     */

    PatternTag,

    /**
     * A pattern that matches one literal or enum value.
     *
     * @example
     * ```ts
     * case 0: zero();
     * ```
     *
     * @since 1.0.0
     */

    PatternValue,

    /**
     * A pattern that matches a range of values.
     *
     * @remarks
     * `..` leaves the end out, and `..=` takes it in.
     *
     * @example
     * ```ts
     * case 'a'..='z': lower();
     * ```
     *
     * @since 1.0.0
     */

    PatternRange,

    /**
     * A block of statements in braces.
     *
     * @example
     * ```ts
     * { const x = 1; use(x); }
     * ```
     *
     * @since 1.0.0
     */

    Block,

    /**
     * An `unsafe` block, which permits operations that the checker cannot prove safe.
     *
     * @example
     * ```ts
     * unsafe { ptr[i] = 0; }
     * ```
     *
     * @since 1.0.0
     */

    UnsafeBlock,

    /**
     * An expression used as a statement.
     *
     * @example
     * ```ts
     * log(message);
     * ```
     *
     * @since 1.0.0
     */

    ExprStmt,

    /**
     * An assignment, with its operator held as a {@link BinOp}.
     *
     * @remarks
     * A plain `=` carries {@link BinOp.None}, and a compound form such as `+=` carries the operator it applies.
     *
     * @example
     * ```ts
     * x = 1;
     * x += 1;
     * ```
     *
     * @since 1.0.0
     */

    Assign,

    /**
     * A postfix `++` statement.
     *
     * @example
     * ```ts
     * i++;
     * ```
     *
     * @since 1.0.0
     */

    Increment,

    /**
     * A postfix `--` statement.
     *
     * @example
     * ```ts
     * i--;
     * ```
     *
     * @since 1.0.0
     */

    Decrement,

    /**
     * A `return` statement.
     *
     * @example
     * ```ts
     * return a + b;
     * ```
     *
     * @since 1.0.0
     */

    Return,

    /**
     * A `throw` expression, which returns an error to the caller.
     *
     * @example
     * ```ts
     * throw DbError.NotFound;
     * ```
     *
     * @since 1.0.0
     */

    Throw,

    /**
     * A `break` statement, with an optional label.
     *
     * @example
     * ```ts
     * break outer;
     * ```
     *
     * @since 1.0.0
     */

    Break,

    /**
     * A `continue` statement, with an optional label.
     *
     * @example
     * ```ts
     * continue outer;
     * ```
     *
     * @since 1.0.0
     */

    Continue,

    /**
     * An `if` statement, which may capture an optional's value by name.
     *
     * @example
     * ```ts
     * if (const user = find(id)) greet(user); else signUp();
     * ```
     *
     * @since 1.0.0
     */

    If,

    /**
     * A `while` loop, which may capture an optional's value by name.
     *
     * @example
     * ```ts
     * while (const line = next()) print(line);
     * ```
     *
     * @since 1.0.0
     */

    While,

    /**
     * A C-style `for` loop with its initializer, condition, and step.
     *
     * @example
     * ```ts
     * for (let i = 0; i < n; i++) {}
     * ```
     *
     * @since 1.0.0
     */

    For,

    /**
     * A `for-of` loop over a collection or a range, with an optional index name.
     *
     * @example
     * ```ts
     * for (const item, i of items) {}
     * ```
     *
     * @since 1.0.0
     */

    ForOf,

    /**
     * A `defer` statement, which runs when the enclosing scope exits.
     *
     * @example
     * ```ts
     * defer free(buffer);
     * ```
     *
     * @since 1.0.0
     */

    Defer,

    /**
     * An `errdefer` statement, which runs only when the enclosing scope exits with an error.
     *
     * @example
     * ```ts
     * errdefer free(buffer);
     * ```
     *
     * @since 1.0.0
     */

    Errdefer,

    /**
     * A `describe` block that groups tests, hooks, and fixtures.
     *
     * @example
     * ```ts
     * describe("parser") { test("reads a number") {} }
     * ```
     *
     * @since 1.0.0
     */

    Describe,

    /**
     * A `test` with its name, body, and modifiers.
     *
     * @example
     * ```ts
     * test("reads a number") { expect(parse("1")).toBe(1); }
     * test.todo("reads a float");
     * ```
     *
     * @since 1.0.0
     */

    Test,

    /**
     * A setup or teardown hook inside a `describe` block.
     *
     * @remarks
     * The four hooks are `beforeAll`, `afterAll`, `beforeEach`, and `afterEach`.
     *
     * @example
     * ```ts
     * beforeEach { reset(); }
     * ```
     *
     * @since 1.0.0
     */

    Hook,
}

/**
 * The printed name of each {@link NodeKind}, which `helix ast` shows for every node.
 *
 * @remarks
 * The array is indexed by the kind, so its entries must stay in the same order as the enum members.
 * Kinds that carry an operator print it directly, such as `.` for a field access and `++` for an increment.
 *
 * @example
 * ```ts
 * NODE_NAMES[NodeKind.Invalid];   // '<error>'
 * NODE_NAMES[NodeKind.ForOf];     // 'for-of'
 * ```
 *
 * @since 1.0.0
 */

export const NODE_NAMES: string[98] = [
    "none",
    "<error>",
    "file",
    "import",
    "spec",
    "const",
    "let",
    "function",
    "param",
    "generic",
    "struct",
    "field",
    "enum",
    "member",
    "union",
    "variant",
    "error",
    "error-member",
    "interface",
    "type",
    "comptime-block",
    "optional",
    "pointer",
    "readonly",
    "dyn",
    "slice",
    "array",
    "many-pointer",
    "error-union",
    "fn-type",
    "struct-type",
    "ident",
    "int",
    "float",
    "string",
    "char",
    "true",
    "false",
    "null",
    "undefined",
    "unreachable",
    "template",
    "text",
    "enum-literal",
    "builtin",
    "import-expr",
    "call",
    "index",
    "slice-of",
    ".",
    "?.",
    "unwrap",
    "generic-of",
    "struct-literal",
    "init",
    "array-literal",
    "neg",
    "not",
    "bit-not",
    "addr",
    "deref",
    "try",
    "comptime",
    "void",
    "binary",
    "as",
    "?",
    "catch",
    "range",
    "arrow",
    "switch",
    "case",
    "default",
    "bind",
    "pstruct",
    "pfield",
    "tag",
    "value",
    "prange",
    "block",
    "unsafe",
    "expr",
    "assign",
    "++",
    "--",
    "return",
    "throw",
    "break",
    "continue",
    "if",
    "while",
    "for",
    "for-of",
    "defer",
    "errdefer",
    "describe",
    "test",
    "hook",
];

/**
 * The operator of a binary operation or an assignment.
 *
 * @remarks
 * {@link NodeKind.Binary} and {@link NodeKind.Assign} store it in the 16-bit operator slot of their node.
 * The order matches {@link BINOP_SPELLINGS}, which holds the source text of each operator.
 *
 * @example
 * ```ts
 * // x += 1 is an Assign node that carries BinOp.Add
 * BINOP_SPELLINGS[BinOp.Add]; // '+'
 * ```
 *
 * @since 1.0.0
 */

export enum BinOp: u16 {
    /**
     * The plain assignment, which applies no operator.
     *
     * @remarks
     * Only {@link NodeKind.Assign} carries it, which is why its spelling is `=`.
     *
     * @example
     * ```ts
     * x = 1;
     * ```
     *
     * @since 1.0.0
     */

    None,

    /**
     * The `??` operator, which falls back to its right side when the left is `null`.
     *
     * @example
     * ```ts
     * name ?? "guest";
     * ```
     *
     * @since 1.0.0
     */

    Coalesce,

    /**
     * The logical `||` operator.
     *
     * @example
     * ```ts
     * a || b;
     * ```
     *
     * @since 1.0.0
     */

    Or,

    /**
     * The logical `&&` operator.
     *
     * @example
     * ```ts
     * a && b;
     * ```
     *
     * @since 1.0.0
     */

    And,

    /**
     * The `==` comparison.
     *
     * @example
     * ```ts
     * a == b;
     * ```
     *
     * @since 1.0.0
     */

    Eq,

    /**
     * The `!=` comparison.
     *
     * @example
     * ```ts
     * a != b;
     * ```
     *
     * @since 1.0.0
     */

    Ne,

    /**
     * The `<` comparison.
     *
     * @example
     * ```ts
     * a < b;
     * ```
     *
     * @since 1.0.0
     */

    Lt,

    /**
     * The `<=` comparison.
     *
     * @example
     * ```ts
     * a <= b;
     * ```
     *
     * @since 1.0.0
     */

    Le,

    /**
     * The `>` comparison.
     *
     * @example
     * ```ts
     * a > b;
     * ```
     *
     * @since 1.0.0
     */

    Gt,

    /**
     * The `>=` comparison.
     *
     * @example
     * ```ts
     * a >= b;
     * ```
     *
     * @since 1.0.0
     */

    Ge,

    /**
     * The bitwise `|` operator.
     *
     * @example
     * ```ts
     * a | b;
     * ```
     *
     * @since 1.0.0
     */

    BitOr,

    /**
     * The bitwise `^` operator.
     *
     * @example
     * ```ts
     * a ^ b;
     * ```
     *
     * @since 1.0.0
     */

    BitXor,

    /**
     * The bitwise `&` operator.
     *
     * @example
     * ```ts
     * a & b;
     * ```
     *
     * @since 1.0.0
     */

    BitAnd,

    /**
     * The `<<` shift.
     *
     * @example
     * ```ts
     * a << 2;
     * ```
     *
     * @since 1.0.0
     */

    Shl,

    /**
     * The `>>` shift.
     *
     * @example
     * ```ts
     * a >> 2;
     * ```
     *
     * @since 1.0.0
     */

    Shr,

    /**
     * The `+` operator.
     *
     * @example
     * ```ts
     * a + b;
     * ```
     *
     * @since 1.0.0
     */

    Add,

    /**
     * The `-` operator.
     *
     * @example
     * ```ts
     * a - b;
     * ```
     *
     * @since 1.0.0
     */

    Sub,

    /**
     * The wrapping `+%` operator, which wraps around on overflow.
     *
     * @example
     * ```ts
     * 255 as u8 +% 1;   // 0
     * ```
     *
     * @since 1.0.0
     */

    AddWrap,

    /**
     * The wrapping `-%` operator, which wraps around on overflow.
     *
     * @example
     * ```ts
     * 0 as u8 -% 1;   // 255
     * ```
     *
     * @since 1.0.0
     */

    SubWrap,

    /**
     * The saturating `+|` operator, which stops at the largest value on overflow.
     *
     * @example
     * ```ts
     * 250 as u8 +| 10;   // 255
     * ```
     *
     * @since 1.0.0
     */

    AddSat,

    /**
     * The saturating `-|` operator, which stops at the smallest value on overflow.
     *
     * @example
     * ```ts
     * 5 as u8 -| 10;   // 0
     * ```
     *
     * @since 1.0.0
     */

    SubSat,

    /**
     * The `*` operator.
     *
     * @example
     * ```ts
     * a * b;
     * ```
     *
     * @since 1.0.0
     */

    Mul,

    /**
     * The `/` operator.
     *
     * @example
     * ```ts
     * a / b;
     * ```
     *
     * @since 1.0.0
     */

    Div,

    /**
     * The `%` operator.
     *
     * @example
     * ```ts
     * a % b;
     * ```
     *
     * @since 1.0.0
     */

    Mod,

    /**
     * The wrapping `*%` operator, which wraps around on overflow.
     *
     * @example
     * ```ts
     * 16 as u8 *% 16;   // 0
     * ```
     *
     * @since 1.0.0
     */

    MulWrap,

    /**
     * The saturating `*|` operator, which stops at the largest value on overflow.
     *
     * @example
     * ```ts
     * 16 as u8 *| 16;   // 255
     * ```
     *
     * @since 1.0.0
     */

    MulSat,
}

/**
 * The source text of each {@link BinOp}.
 *
 * @remarks
 * The array is indexed by the operator, so its entries must stay in the same order as the enum members.
 * {@link BinOp.None} spells `=`, since only a plain assignment carries it.
 * A compound assignment appends `=` to the spelling of its operator.
 *
 * @example
 * ```ts
 * BINOP_SPELLINGS[BinOp.Coalesce]; // '??'
 * BINOP_SPELLINGS[BinOp.AddSat];   // '+|'
 * ```
 *
 * @since 1.0.0
 */

export const BINOP_SPELLINGS: string[26] = [
    "=",
    "??",
    "||",
    "&&",
    "==",
    "!=",
    "<",
    "<=",
    ">",
    ">=",
    "|",
    "^",
    "&",
    "<<",
    ">>",
    "+",
    "-",
    "+%",
    "-%",
    "+|",
    "-|",
    "*",
    "/",
    "%",
    "*%",
    "*|",
];

/**
 * The flag of a declaration marked with `export`.
 *
 * @remarks
 * An `Import` node carries it for a re-export written as `export ... from`.
 *
 * @example
 * ```ts
 * (node.flags & FLAG_EXPORT) != 0; // true for export const limit = 10;
 * ```
 *
 * @since 1.0.0
 */

export const FLAG_EXPORT: u8 = 0x01;

/**
 * The flag of a declaration marked with `extern`.
 *
 * @example
 * ```ts
 * (node.flags & FLAG_EXTERN) != 0; // true for extern "C" function free(ptr: ?u8[*]): void;
 * ```
 *
 * @since 1.0.0
 */

export const FLAG_EXTERN: u8 = 0x02;

/**
 * The flag of an `Import` node that imports a whole module as a namespace.
 *
 * @example
 * ```ts
 * (node.flags & FLAG_NAMESPACE) != 0; // true for import * as fmt from "std/fmt";
 * ```
 *
 * @since 1.0.0
 */

export const FLAG_NAMESPACE: u8 = 0x04;

/**
 * The flag of a `Function` node whose parameter list ends with `...`.
 *
 * @example
 * ```ts
 * (node.flags & FLAG_VARIADIC) != 0; // true for extern "C" function printf(f: readonly u8[*], ...): i32;
 * ```
 *
 * @since 1.0.0
 */

export const FLAG_VARIADIC: u8 = 0x08;

/**
 * The flag of a `Param` node marked with `comptime`.
 *
 * @example
 * ```ts
 * (node.flags & FLAG_COMPTIME) != 0; // true for the T in function make(comptime T: type): T
 * ```
 *
 * @since 1.0.0
 */

export const FLAG_COMPTIME: u8 = 0x10;

/**
 * The flag of a `Range`, `Slice`, or `PatternRange` node written with `..=`, which takes the end in.
 *
 * @example
 * ```ts
 * (node.flags & FLAG_INCLUSIVE) != 0; // true for 0..=9
 * ```
 *
 * @since 1.0.0
 */

export const FLAG_INCLUSIVE: u8 = 0x20;

/**
 * The flag of a `Switch` node in its expression form.
 *
 * @example
 * ```ts
 * (node.flags & FLAG_EXPR) != 0; // true for const n = switch (x) { default: 0; };
 * ```
 *
 * @since 1.0.0
 */

export const FLAG_EXPR: u8 = 0x40;

/**
 * The flag of a `PatternBind` node written with a leading `*`, which binds a pointer to the value.
 *
 * @example
 * ```ts
 * (node.flags & FLAG_POINTER) != 0; // true for case .circle(*r):
 * ```
 *
 * @since 1.0.0
 */

export const FLAG_POINTER: u8 = 0x80;

/**
 * The token index that marks an absent token.
 *
 * @remarks
 * A node field that holds a token, such as the alias of an import, holds this when the source has none.
 *
 * @example
 * ```ts
 * data.alias_token == NO_TOKEN; // true for import { a } from "./a";
 * ```
 *
 * @since 1.0.0
 */

export const NO_TOKEN: u32 = 0xFFFF_FFFF;

/**
 * The mode of a test or a describe block without a modifier.
 *
 * @remarks
 * A `Test` or `Describe` node keeps its mode in its operator field.
 *
 * @example
 * ```ts
 * test("reads a number") {}
 * ```
 *
 * @since 1.0.0
 */

export const TEST_PLAIN: u16 = 0;

/**
 * The mode of a test or a describe block marked `.skip`, which does not run.
 *
 * @remarks
 * A `Test` or `Describe` node keeps its mode in its operator field.
 *
 * @example
 * ```ts
 * test.skip("reads a float") {}
 * ```
 *
 * @since 1.0.0
 */

export const TEST_SKIP: u16 = 1;

/**
 * The mode of a test or a describe block marked `.only`, which runs alone with the others marked the same way.
 *
 * @remarks
 * A `Test` or `Describe` node keeps its mode in its operator field.
 *
 * @example
 * ```ts
 * describe.only("parser") {}
 * ```
 *
 * @since 1.0.0
 */

export const TEST_ONLY: u16 = 2;

/**
 * The mode of a test marked `.todo`, which has no body yet.
 *
 * @remarks
 * A `Test` or `Describe` node keeps its mode in its operator field.
 *
 * @example
 * ```ts
 * test.todo("reads a float");
 * ```
 *
 * @since 1.0.0
 */

export const TEST_TODO: u16 = 3;

/**
 * The mode of a test marked `.failing`, which passes only when its body fails.
 *
 * @remarks
 * A `Test` or `Describe` node keeps its mode in its operator field.
 *
 * @example
 * ```ts
 * test.failing("rejects a bad number") {}
 * ```
 *
 * @since 1.0.0
 */

export const TEST_FAILING: u16 = 4;

/**
 * The mode of a test marked `.panics`, which passes only when it panics with the given message.
 *
 * @remarks
 * A `Test` or `Describe` node keeps its mode in its operator field.
 *
 * @example
 * ```ts
 * test.panics("stops", "index out of bounds") {}
 * ```
 *
 * @since 1.0.0
 */

export const TEST_PANICS: u16 = 5;

/**
 * The modifier that the AST printer shows for each test mode, indexed by the mode.
 *
 * @example
 * ```ts
 * TEST_MODE_LABELS[TEST_SKIP]; // ' :skip'
 * ```
 *
 * @since 1.0.0
 */

export const TEST_MODE_LABELS: string[6] = ["", " :skip", " :only", " :todo", " :failing", " :panics"];

/**
 * The name of each hook, indexed by the value that a `Hook` node keeps in its operator field.
 *
 * @example
 * ```ts
 * HOOK_NAMES[node.op as usize]; // 'beforeEach' for beforeEach { reset(); }
 * ```
 *
 * @since 1.0.0
 */

export const HOOK_NAMES: string[4] = ["beforeAll", "afterAll", "beforeEach", "afterEach"];
