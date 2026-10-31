/**
 * Imports
 */

import { HxAst } from "@models/structs/ast-model.struct";
import { HxTypes } from "@models/structs/types-model.struct";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxInterner } from "@services/structs/intern-service.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";

/**
 * The kind of a symbol, one of the `HxSym` kind constants.
 *
 * @remarks
 * {@link HxSymbol} stores it in one byte.
 *
 * @example
 * ```hx
 * symbolOf(c, sym).kind == HxSymLocal as u8; // true for a local
 * ```
 *
 * @since 1.0.0
 */

export type HxSymbolKind = u32;

/**
 * One entry of the symbol table: a name that the program declares.
 *
 * @remarks
 * Symbols live in {@link HxSema.symbols} and are numbered from 1, since index 0 is the reserved empty symbol.
 * The checker added this struct when it was written in C, so the struct keeps its C layout.
 *
 * @example
 * ```hx
 * const s = symbolOf(c, infoOf(c, decl).symbol);
 * tokenText(c, s.token); // 'limit' for const limit = 10;
 * ```
 *
 * @see HxSema
 * @see HxSymbolKind
 *
 * @since 1.0.0
 */

export extern "C" struct HxSymbol {
    /**
     * The {@link HxSymbolKind} of the symbol.
     *
     * @example
     * ```hx
     * s.kind; // HxSymFunction as u8
     * ```
     *
     * @since 1.0.0
     */

    kind: u8,

    /**
     * The `HxSym` flag bits of the symbol, such as {@link HxSymUsed}.
     *
     * @example
     * ```hx
     * (s.flags & (HxSymUsed as u16)) != 0; // true once it is used
     * ```
     *
     * @since 1.0.0
     */

    flags: u16,

    /**
     * The interned name of the symbol.
     *
     * @example
     * ```hx
     * s.name == hxsTokName(c, s.token); // true
     * ```
     *
     * @since 1.0.0
     */

    name: u32,

    /**
     * The token that declares the symbol.
     *
     * @example
     * ```hx
     * tokenText(c, s.token); // 'count'
     * ```
     *
     * @since 1.0.0
     */

    token: u32,

    /**
     * The node that declares the symbol, or 0 for a module namespace.
     *
     * @example
     * ```hx
     * nodeOf(c, s.decl).kind; // NodeKind.Function
     * ```
     *
     * @since 1.0.0
     */

    decl: u32,

    /**
     * The type of the symbol, or 0 while it is unknown or after an error.
     *
     * @example
     * ```hx
     * s.type; // types(c).i32 for const n: i32 = 1;
     * ```
     *
     * @since 1.0.0
     */

    type: u32,

    /**
     * The index of the compile-time value of a constant, or 0.
     *
     * @remarks
     * A constant whose value is known while compiling is read from its value instead of from memory.
     * A `comptime` parameter of an instance holds the value that the call bound it to.
     *
     * @example
     * ```hx
     * valueAt(c, s.value).integer; // 10 for const limit = 10;
     * ```
     *
     * @since 1.0.0
     */

    value: u32,

    /**
     * The type that declares the symbol, or 0.
     *
     * @remarks
     * It is set for methods, for the constants that a type declares, and for method instances.
     *
     * @example
     * ```hx
     * s.owner; // the id of Point for the method Point.len
     * ```
     *
     * @since 1.0.0
     */

    owner: u32,

    /**
     * The generic instance that the symbol belongs to, or 0.
     *
     * @remarks
     * A function instance holds its own number, and an arrow function written inside an instance holds that instance.
     *
     * @example
     * ```hx
     * s.instance; // the instance of max<i32> for that function
     * ```
     *
     * @since 1.0.0
     */

    instance: u32,

    /**
     * The module that declares the symbol, where 0 is the root.
     *
     * @example
     * ```hx
     * s.module; // 0 for a symbol of the root file
     * ```
     *
     * @since 1.0.0
     */

    module: u32,

    /**
     * The module that a module namespace stands for.
     *
     * @example
     * ```hx
     * s.targetModule; // the index of math for import * as math
     * ```
     *
     * @since 1.0.0
     */

    targetModule: u32,
}

/**
 * The kind of a compile-time value, one of the `HxValue` kind constants.
 *
 * @remarks
 * {@link HxValue} stores it in one byte.
 *
 * @example
 * ```hx
 * valueAt(c, index).kind == HxValueInt as u8; // true for the value of 42
 * ```
 *
 * @since 1.0.0
 */

export type HxValueKind = u32;

/**
 * The 128-bit signed integer, named as the C checker named it.
 *
 * @remarks
 * It is the type of {@link HxValue.integer} and {@link HxMember.value}.
 *
 * @example
 * ```hx
 * const v: HxI128 = -1;
 * ```
 *
 * @since 1.0.0
 */

export type HxI128 = i128;

/**
 * A value that the checker knows while compiling.
 *
 * @remarks
 * Values live in {@link HxSema.values}, and index 0 is the empty value that stands for no value.
 * The {@link HxValueKind} decides which fields hold the value.
 * The checker added this struct when it was written in C, so the struct keeps its C layout.
 *
 * @example
 * ```hx
 * const v = valueAt(c, infoOf(c, node).value);
 * v.integer; // 42 for 6 * 7
 * ```
 *
 * @see HxValueKind
 * @since 1.0.0
 */

export extern "C" struct HxValue {
    /**
     * The {@link HxValueKind} of the value.
     *
     * @example
     * ```hx
     * v.kind; // HxValueBool as u8
     * ```
     *
     * @since 1.0.0
     */

    kind: u8,

    /**
     * The value of a boolean.
     *
     * @example
     * ```hx
     * v.boolean; // true
     * ```
     *
     * @since 1.0.0
     */

    boolean: bool,

    /**
     * The value of an integer or an enum, the code of an error, or the symbol of a function.
     *
     * @example
     * ```hx
     * v.integer; // 42
     * ```
     *
     * @since 1.0.0
     */

    integer: HxI128,

    /**
     * The value of a float.
     *
     * @example
     * ```hx
     * v.floating; // 0.5
     * ```
     *
     * @since 1.0.0
     */

    floating: f64,

    /**
     * The bytes of a string, or `null`.
     *
     * @remarks
     * The bytes are NUL-terminated, which lets them pass as a C string.
     *
     * @example
     * ```hx
     * v.bytes; // "hi" for the literal "hi"
     * ```
     *
     * @since 1.0.0
     */

    bytes: ?readonly u8[*],

    /**
     * The length of a string in bytes, the NUL terminator not included.
     *
     * @example
     * ```hx
     * v.len; // 2 for "hi"
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The index of the first element of an aggregate in {@link HxSema.valueElems}.
     *
     * @example
     * ```hx
     * semaOf(c).valueElems.items![v.elems]; // the value index of the first element
     * ```
     *
     * @since 1.0.0
     */

    elems: u32,

    /**
     * The number of elements of an aggregate.
     *
     * @example
     * ```hx
     * v.count; // 3 for [1, 2, 3]
     * ```
     *
     * @since 1.0.0
     */

    count: u32,
}

/**
 * What the checker found out about one node of the syntax tree.
 *
 * @remarks
 * The checker keeps one per node in {@link HxSema.info}, and code generation reads them
 * instead of deriving a type again.
 * A generic instance keeps its own infos for the nodes of its declaration.
 * The checker added this struct when it was written in C, so the struct keeps its C layout.
 *
 * @example
 * ```hx
 * const info = infoOf(c, node);
 * info.type;  // the type of the expression
 * info.value; // its value index, or 0
 * ```
 *
 * @see infoOf
 * @see HxInstance
 *
 * @since 1.0.0
 */

export extern "C" struct HxNodeInfo {
    /**
     * The type of the node, or 0 when it has none or after an error.
     *
     * @example
     * ```hx
     * info.type; // types(c).boolType for a < b
     * ```
     *
     * @since 1.0.0
     */

    type: u32,

    /**
     * The type that the value of the node converts to where it is used, or 0.
     *
     * @remarks
     * Code generation converts the value from `type` to this type.
     *
     * @example
     * ```hx
     * // const x: ?i32 = 5;
     * info.coerce; // the id of ?i32 on the literal 5
     * ```
     *
     * @since 1.0.0
     */

    coerce: u32,

    /**
     * The symbol that the node declares or refers to, or 0.
     *
     * @example
     * ```hx
     * symbolOf(c, info.symbol).kind; // HxSymLocal as u8 for a read of a local
     * ```
     *
     * @since 1.0.0
     */

    symbol: u32,

    /**
     * The index of the compile-time value of the node, or 0 when it is only known at run time.
     *
     * @example
     * ```hx
     * valueAt(c, info.value).integer; // 42 for 6 * 7
     * ```
     *
     * @since 1.0.0
     */

    value: u32,

    /**
     * The `HxInfo` flag bits of the node, such as {@link HxInfoMethod}.
     *
     * @example
     * ```hx
     * (info.flags & HxInfoMethod) != 0; // true for list.push(1)
     * ```
     *
     * @since 1.0.0
     */

    flags: u32,

    /**
     * A number whose meaning depends on the flags and the node.
     *
     * @remarks
     * It holds the index of a field, a union variant, an enum member, or a method,
     * the {@link HxPrintKind} of a print call, the matcher of an `expect` call,
     * or the symbol or slot of the `next` method of a `for-of` loop.
     *
     * @example
     * ```hx
     * info.aux; // 1 for p.y, the index of the field y
     * ```
     *
     * @since 1.0.0
     */

    aux: u32,
}

/**
 * A matcher that `expect(x).<matcher>(...)` knows, one of the `HxMatch` constants.
 *
 * @remarks
 * The `aux` of an `expect` call holds one, together with the bits {@link HxExpectNot} and {@link HxExpectRequire}.
 *
 * @example
 * ```hx
 * (infoOf(c, call).aux & HxExpectMatcher) == HxMatchToEqual; // true for expect(a).toEqual(b)
 * ```
 *
 * @see HxExpectMatcher
 * @since 1.0.0
 */

export type HxMatcher = u32;

/**
 * The kind of a print call, one of the `HxPrint` and `HxEprint` constants.
 *
 * @remarks
 * The `aux` of a call with {@link HxInfoPrint} holds it.
 *
 * @example
 * ```hx
 * infoOf(c, call).aux == HxPrintln; // true for println("hi")
 * ```
 *
 * @since 1.0.0
 */

export type HxPrintKind = u32;

/**
 * The growable array of symbols.
 *
 * @remarks
 * The checker pushes a blank symbol first, so id 0 never names a real symbol and serves as the null id.
 * The array grows through `hxVecGrowImpl`, which doubles the room and starts at eight entries.
 *
 * @example
 * ```hx
 * semaOf(c).symbols.len; // the number of symbols, the empty one included
 * ```
 *
 * @see HxSymbol
 * @since 1.0.0
 */

export extern "C" struct HxSymbolVec {
    /**
     * The symbols, or `null` before the first one is added.
     *
     * @remarks
     * Adding an entry can move the array, so a pointer into it does not stay valid.
     *
     * @example
     * ```hx
     * symbols.items![0]; // the reserved empty symbol
     * ```
     *
     * @since 1.0.0
     */

    items: ?*HxSymbol,

    /**
     * The number of symbols.
     *
     * @example
     * ```hx
     * symbols.len; // 3 after three entries
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The number of symbols that the array has room for.
     *
     * @example
     * ```hx
     * symbols.cap; // 8 after the first entry, doubling from there
     * ```
     *
     * @since 1.0.0
     */

    cap: u32,
}

/**
 * The growable array of compile-time values.
 *
 * @remarks
 * The checker pushes an empty value first, so value id 0 means that a symbol has no compile-time value.
 * The array grows through `hxVecGrowImpl`, which doubles the room and starts at eight entries.
 *
 * @example
 * ```hx
 * semaOf(c).values.len; // the number of values
 * ```
 *
 * @see HxValue
 * @since 1.0.0
 */

export extern "C" struct HxValueVec {
    /**
     * The values, or `null` before the first one is added.
     *
     * @remarks
     * Adding an entry can move the array, so a pointer into it does not stay valid.
     *
     * @example
     * ```hx
     * values.items![0]; // the empty value
     * ```
     *
     * @since 1.0.0
     */

    items: ?*HxValue,

    /**
     * The number of values.
     *
     * @example
     * ```hx
     * values.len; // 3 after three entries
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The number of values that the array has room for.
     *
     * @example
     * ```hx
     * values.cap; // 8 after the first entry, doubling from there
     * ```
     *
     * @since 1.0.0
     */

    cap: u32,
}

/**
 * The kind of a member of an aggregate, one of the `HxMember` kind constants.
 *
 * @remarks
 * {@link HxMember} stores it in one byte.
 *
 * @example
 * ```hx
 * memberAt(c, index).kind == HxMemberField as u8; // true for a struct field
 * ```
 *
 * @since 1.0.0
 */

export type HxMemberKind = u32;

/**
 * One member of a struct, enum, union, error set, or interface.
 *
 * @remarks
 * The members of all aggregates live in {@link HxSema.members}, one run per aggregate in declaration order.
 * The checker added this struct when it was written in C, so the struct keeps its C layout.
 *
 * @example
 * ```hx
 * const m = memberAt(c, hxsAggregateOf(c, point).membersStart);
 * tokenText(c, m.token); // 'x'
 * ```
 *
 * @see HxAggregate
 * @see HxMemberKind
 *
 * @since 1.0.0
 */

export extern "C" struct HxMember {
    /**
     * The {@link HxMemberKind} of the member.
     *
     * @example
     * ```hx
     * m.kind; // HxMemberField as u8
     * ```
     *
     * @since 1.0.0
     */

    kind: u8,

    /**
     * The interned name of the member.
     *
     * @example
     * ```hx
     * m.name == hxsTokName(c, m.token); // true
     * ```
     *
     * @since 1.0.0
     */

    name: u32,

    /**
     * The token that names the member.
     *
     * @example
     * ```hx
     * tokenText(c, m.token); // 'x'
     * ```
     *
     * @since 1.0.0
     */

    token: u32,

    /**
     * The type of the member, or 0.
     *
     * @remarks
     * A field holds its type, a union variant its payload type or 0 without a payload,
     * an enum member or an error its own aggregate type, and a signature its function type.
     *
     * @example
     * ```hx
     * m.type; // types(c).i32 for x: i32
     * ```
     *
     * @since 1.0.0
     */

    type: u32,

    /**
     * The expression node of the default value of a field, or 0.
     *
     * @remarks
     * A struct literal that leaves the field out evaluates it again at that literal.
     *
     * @example
     * ```hx
     * // struct Options { verbose: bool = false }
     * nodeOf(c, m.defaultValue).kind; // NodeKind.False
     * ```
     *
     * @since 1.0.0
     */

    defaultValue: u32,

    /**
     * The value of an enum member, or the code of an error.
     *
     * @example
     * ```hx
     * m.value; // 2 for the third member of an enum
     * ```
     *
     * @since 1.0.0
     */

    value: HxI128,

    /**
     * The position of the member among the fields, variants, enum members, errors, or signatures.
     *
     * @remarks
     * For a signature it is the slot in the vtable of the interface.
     *
     * @example
     * ```hx
     * m.index; // 1 for y in struct Point { x: i32, y: i32 }
     * ```
     *
     * @since 1.0.0
     */

    index: u32,

    /**
     * The function symbol of a method, or the global symbol of a constant.
     *
     * @example
     * ```hx
     * symbolOf(c, m.symbol).kind; // HxSymFunction as u8 for a method
     * ```
     *
     * @since 1.0.0
     */

    symbol: u32,

    /**
     * The function node that declares a signature of an interface, or 0.
     *
     * @example
     * ```hx
     * nodeOf(c, m.decl).kind; // NodeKind.Function for a signature
     * ```
     *
     * @since 1.0.0
     */

    decl: u32,
}

/**
 * A struct, enum, union, error set, or interface, with its type and its members.
 *
 * @remarks
 * Aggregates live in {@link HxSema.aggregates}, and a nominal type stores the index of its aggregate plus one.
 * Its members are resolved the first time something needs them.
 * The checker added this struct when it was written in C, so the struct keeps its C layout.
 *
 * @example
 * ```hx
 * const agg = hxsAggregateOf(c, point);
 * agg.fieldCount; // 2 for struct Point { x: i32, y: i32 }
 * ```
 *
 * @see HxMember
 * @see hxsAggregateOf
 *
 * @since 1.0.0
 */

export extern "C" struct HxAggregate {
    /**
     * The nominal type of the aggregate.
     *
     * @example
     * ```hx
     * agg.type; // the id of Point
     * ```
     *
     * @since 1.0.0
     */

    type: u32,

    /**
     * The node that declares the aggregate.
     *
     * @example
     * ```hx
     * nodeOf(c, agg.decl).kind; // NodeKind.Struct
     * ```
     *
     * @since 1.0.0
     */

    decl: u32,

    /**
     * The index of the first member in {@link HxSema.members}.
     *
     * @example
     * ```hx
     * memberAt(c, agg.membersStart).name; // the name of the first member
     * ```
     *
     * @since 1.0.0
     */

    membersStart: u32,

    /**
     * The number of members, methods and constants included.
     *
     * @example
     * ```hx
     * agg.membersCount; // 3 for two fields and one method
     * ```
     *
     * @since 1.0.0
     */

    membersCount: u32,

    /**
     * The number of fields, variants, enum members, errors, or signatures, which leaves out methods and constants.
     *
     * @example
     * ```hx
     * agg.fieldCount; // 2 for two fields and one method
     * ```
     *
     * @since 1.0.0
     */

    fieldCount: u32,

    /**
     * The state of the members: 0 before they are resolved, then {@link HxAggResolving} and {@link HxAggResolved}.
     *
     * @example
     * ```hx
     * agg.state == HxAggResolved as u8; // true once the members are known
     * ```
     *
     * @since 1.0.0
     */

    state: u8,

    /**
     * The generic instance that made the aggregate, or 0 for a declaration that is not generic.
     *
     * @example
     * ```hx
     * agg.instance; // the instance of List<u8> for that struct
     * ```
     *
     * @since 1.0.0
     */

    instance: u32,

    /**
     * The module that declares the aggregate, where its member types are looked up.
     *
     * @example
     * ```hx
     * agg.module; // 0 for the root file
     * ```
     *
     * @since 1.0.0
     */

    module: u32,
}

/**
 * One instantiation of a generic function or struct, such as `max<i32>` or `ArrayList<u8>`.
 *
 * @remarks
 * The instances share the syntax of their declaration,
 * and each has its own node infos for the node range of the declaration,
 * so each instantiation can give the same nodes different types.
 * Instances are numbered from 1, and 0 means no instance.
 * The checker added this struct when it was written in C, so the struct keeps its C layout.
 *
 * @example
 * ```hx
 * // const n = max<i32>(1, 2);
 * instance.argsCount; // 1, the type argument i32
 * ```
 *
 * @see infoAt
 * @see HxSema.instances
 *
 * @since 1.0.0
 */

export extern "C" struct HxInstance {
    /**
     * The generic declaration.
     *
     * @example
     * ```hx
     * nodeOf(c, instance.decl).kind; // NodeKind.Function
     * ```
     *
     * @since 1.0.0
     */

    decl: u32,

    /**
     * The first node of the declaration, the start of the range with its own node infos.
     *
     * @example
     * ```hx
     * instance.lo; // the first node of max
     * ```
     *
     * @since 1.0.0
     */

    lo: u32,

    /**
     * The last node of the range with its own node infos, which is the declaration itself.
     *
     * @example
     * ```hx
     * instance.hi == instance.decl; // true
     * ```
     *
     * @since 1.0.0
     */

    hi: u32,

    /**
     * The node infos of the instance, one per node from `lo` to `hi`.
     *
     * @example
     * ```hx
     * infoAt(semaOf(c), index, node).type; // reads this array for a node in the range
     * ```
     *
     * @since 1.0.0
     */

    info: ?*HxNodeInfo,

    /**
     * The index of the first argument in {@link HxSema.instanceArgs} and {@link HxSema.instanceNames}.
     *
     * @example
     * ```hx
     * semaOf(c).instanceArgs.items![instance.argsStart]; // types(c).i32 for max<i32>
     * ```
     *
     * @since 1.0.0
     */

    argsStart: u32,

    /**
     * The number of arguments, types and `comptime` values together.
     *
     * @example
     * ```hx
     * instance.argsCount; // 1 for max<i32>
     * ```
     *
     * @since 1.0.0
     */

    argsCount: u32,

    /**
     * The number of arguments that are types, which come before the `comptime` values.
     *
     * @remarks
     * The arguments after them are value indexes, which bind the `comptime` parameters.
     *
     * @example
     * ```hx
     * instance.typeCount; // 1 for max<i32>
     * ```
     *
     * @since 1.0.0
     */

    typeCount: u32,

    /**
     * The function symbol of a function instance, or 0.
     *
     * @example
     * ```hx
     * symbolOf(c, instance.symbol).instance; // the number of this instance
     * ```
     *
     * @since 1.0.0
     */

    symbol: u32,

    /**
     * The struct type of a struct instance, or 0.
     *
     * @example
     * ```hx
     * instance.type; // the id of List<u8>
     * ```
     *
     * @since 1.0.0
     */

    type: u32,

    /**
     * The node that first needed the instance, which errors inside it point back to.
     *
     * @example
     * ```hx
     * instance.site; // the call max<i32>(1, 2)
     * ```
     *
     * @since 1.0.0
     */

    site: u32,
}

/**
 * The growable array of generic instances.
 *
 * @remarks
 * `hxsFindInstance` finds an existing instance by its declaration and arguments,
 * so the array holds one entry per distinct instantiation rather than one per call.
 *
 * @example
 * ```hx
 * semaOf(c).instances.len; // the number of instances
 * ```
 *
 * @see HxInstance
 * @since 1.0.0
 */

export extern "C" struct HxInstanceVec {
    /**
     * The instances, or `null` before the first one is added.
     *
     * @remarks
     * Adding an entry can move the array, so a pointer into it does not stay valid.
     *
     * @example
     * ```hx
     * instances.items![0]; // the instance numbered 1
     * ```
     *
     * @since 1.0.0
     */

    items: ?*HxInstance,

    /**
     * The number of instances.
     *
     * @example
     * ```hx
     * instances.len; // 3 after three entries
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The number of instances that the array has room for.
     *
     * @example
     * ```hx
     * instances.cap; // 8 after the first entry, doubling from there
     * ```
     *
     * @since 1.0.0
     */

    cap: u32,
}

/**
 * A type that implements an interface, found the first time the program needs it.
 *
 * @remarks
 * {@link HxSema.implMethods} holds one function symbol per method of the interface from `methodsStart` on,
 * in the order of the interface, which is the order of the vtable.
 * The checker added this struct when it was written in C, so the struct keeps its C layout.
 *
 * @example
 * ```hx
 * // const w: dyn Writer = &file;
 * impl.methodsStart; // where the methods of File for Writer start
 * ```
 *
 * @see HxSema.implMethods
 * @since 1.0.0
 */

export extern "C" struct HxImpl {
    /**
     * The type that implements the interface.
     *
     * @example
     * ```hx
     * impl.type; // the id of File
     * ```
     *
     * @since 1.0.0
     */

    type: u32,

    /**
     * The interface.
     *
     * @example
     * ```hx
     * impl.iface; // the id of Writer
     * ```
     *
     * @since 1.0.0
     */

    iface: u32,

    /**
     * The index of the first method in {@link HxSema.implMethods}.
     *
     * @example
     * ```hx
     * semaOf(c).implMethods.items![impl.methodsStart]; // the symbol of File.write
     * ```
     *
     * @since 1.0.0
     */

    methodsStart: u32,
}

/**
 * The growable array of implementations.
 *
 * @remarks
 * The checker grows the array through `hxVecGrowImpl` each time it registers an `impl` block.
 * The methods of an implementation live in a separate array, which `methodsStart` indexes.
 *
 * @example
 * ```hx
 * semaOf(c).impls.len; // the number of implementations
 * ```
 *
 * @see HxImpl
 * @since 1.0.0
 */

export extern "C" struct HxImplVec {
    /**
     * The implementations, or `null` before the first one is added.
     *
     * @remarks
     * Adding an entry can move the array, so a pointer into it does not stay valid.
     *
     * @example
     * ```hx
     * impls.items![0]; // the first implementation found
     * ```
     *
     * @since 1.0.0
     */

    items: ?*HxImpl,

    /**
     * The number of implementations.
     *
     * @example
     * ```hx
     * impls.len; // 3 after three entries
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The number of implementations that the array has room for.
     *
     * @example
     * ```hx
     * impls.cap; // 8 after the first entry, doubling from there
     * ```
     *
     * @since 1.0.0
     */

    cap: u32,
}

/**
 * One file of the program.
 *
 * @remarks
 * Its top-level names form the scope of the module.
 * The checker added this struct when it was written in C, so the struct keeps its C layout.
 *
 * @example
 * ```hx
 * cString(program.modules![0].name!); // 'main'
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxModule {
    /**
     * The root node of the file.
     *
     * @example
     * ```hx
     * nodeOf(c, module.root).kind; // NodeKind.File
     * ```
     *
     * @since 1.0.0
     */

    root: u32,

    /**
     * The readable, unique prefix for the symbols of the module, NUL-terminated.
     *
     * @example
     * ```hx
     * cString(module.name!); // 'std.text'
     * ```
     *
     * @since 1.0.0
     */

    name: ?readonly u8[*],
}

/**
 * The files of a program, as the driver loaded them.
 *
 * @remarks
 * The module at index 0 is the root, the file that has `main`.
 * The checker added this struct when it was written in C, so the struct keeps its C layout.
 *
 * @example
 * ```hx
 * hxSemaCheck(&sema, &ast, &program, &diags);
 * program.count; // 3 for main.hx and two imports
 * ```
 *
 * @see HxModule
 * @since 1.0.0
 */

export extern "C" struct HxProgram {
    /**
     * The modules, the root first.
     *
     * @example
     * ```hx
     * program.modules![0].name; // the root module
     * ```
     *
     * @since 1.0.0
     */

    modules: ?*HxModule,

    /**
     * The number of modules.
     *
     * @example
     * ```hx
     * program.count; // 3
     * ```
     *
     * @since 1.0.0
     */

    count: u32,

    /**
     * The module that each `import` node loads, indexed by node and stored plus one, or `null`.
     *
     * @remarks
     * An entry of 0 means that the driver did not find the file and has already reported it.
     *
     * @example
     * ```hx
     * program.importTargets![node]; // 2 when the import loads module 1
     * ```
     *
     * @since 1.0.0
     */

    importTargets: ?u32[*],

    /**
     * Whether the program is a test build, which checks the `describe` and `test` blocks.
     *
     * @example
     * ```hx
     * program.test; // true for helix test
     * ```
     *
     * @since 1.0.0
     */

    test: bool,

    /**
     * The index of the testing module plus one, or 0 when there is none.
     *
     * @example
     * ```hx
     * program.testingModule - 1; // the module that declares TestError, beginTest, and endTest
     * ```
     *
     * @since 1.0.0
     */

    testingModule: u32,

    /**
     * The size of a pointer on the target, 8 or 4, or 0 for the default of 8.
     *
     * @example
     * ```hx
     * program.pointerBytes; // 4 for a 32-bit target
     * ```
     *
     * @since 1.0.0
     */

    pointerBytes: u32,
}

/**
 * A name in the scope of a module, declared there or imported.
 *
 * @remarks
 * The entries form an open-addressing hash table in {@link HxSema.scopes}.
 * The checker added this struct when it was written in C, so the struct keeps its C layout.
 *
 * @example
 * ```hx
 * const entry = hxsScopeFind(semaOf(c), 0, name)!;
 * entry.symbol; // the symbol of the name in the root module
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxScopeEntry {
    /**
     * The module plus one in the high 32 bits and the interned name in the low 32 bits, or 0 for an empty slot.
     *
     * @example
     * ```hx
     * entry.key >> 32; // 1 for a name of the root module
     * ```
     *
     * @since 1.0.0
     */

    key: u64,

    /**
     * The symbol that the name stands for.
     *
     * @example
     * ```hx
     * symbolOf(c, entry.symbol).kind; // HxSymFunction as u8
     * ```
     *
     * @since 1.0.0
     */

    symbol: u32,

    /**
     * The token that declares or imports the name.
     *
     * @example
     * ```hx
     * tokenText(c, entry.token); // 'max'
     * ```
     *
     * @since 1.0.0
     */

    token: u32,

    /**
     * The `HxScope` flag bits of the entry, such as {@link HxScopeExported}.
     *
     * @example
     * ```hx
     * (entry.flags & (HxScopeUsed as u8)) != 0; // true once the name is looked up
     * ```
     *
     * @since 1.0.0
     */

    flags: u8,
}

/**
 * The growable array of aggregate members.
 *
 * @remarks
 * The members of every aggregate share this one array,
 * and an aggregate refers to its own members by a start index and a count.
 *
 * @example
 * ```hx
 * semaOf(c).members.len; // the number of members
 * ```
 *
 * @see HxMember
 * @since 1.0.0
 */

export extern "C" struct HxMemberVec {
    /**
     * The members, or `null` before the first one is added.
     *
     * @remarks
     * Adding an entry can move the array, so a pointer into it does not stay valid.
     *
     * @example
     * ```hx
     * members.items![0]; // the first member of the first resolved aggregate
     * ```
     *
     * @since 1.0.0
     */

    items: ?*HxMember,

    /**
     * The number of members.
     *
     * @example
     * ```hx
     * members.len; // 3 after three entries
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The number of members that the array has room for.
     *
     * @example
     * ```hx
     * members.cap; // 8 after the first entry, doubling from there
     * ```
     *
     * @since 1.0.0
     */

    cap: u32,
}

/**
 * The growable array of aggregates.
 *
 * @remarks
 * The checker grows the array through `hxVecGrowImpl`, which doubles the room and starts at eight entries.
 * The array owns no members itself, since those live in {@link HxMemberVec}.
 *
 * @example
 * ```hx
 * semaOf(c).aggregates.len; // the number of aggregates
 * ```
 *
 * @see HxAggregate
 * @since 1.0.0
 */

export extern "C" struct HxAggregateVec {
    /**
     * The aggregates, or `null` before the first one is added.
     *
     * @remarks
     * Adding an entry can move the array, so a pointer into it does not stay valid.
     *
     * @example
     * ```hx
     * aggregates.items![0]; // the aggregate of the first declared type
     * ```
     *
     * @since 1.0.0
     */

    items: ?*HxAggregate,

    /**
     * The number of aggregates.
     *
     * @example
     * ```hx
     * aggregates.len; // 3 after three entries
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The number of aggregates that the array has room for.
     *
     * @example
     * ```hx
     * aggregates.cap; // 8 after the first entry, doubling from there
     * ```
     *
     * @since 1.0.0
     */

    cap: u32,
}

/**
 * The growable array of interned names.
 *
 * @remarks
 * It has the same layout as {@link HxU32Vec}, so the checker pushes to it through `pushU32` with a pointer cast.
 * The checker pushes name 0 first, so error code 0 stays free to mean no error.
 *
 * @example
 * ```hx
 * semaOf(c).errorNames.len; // the number of error codes, 0 included
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxNameVec {
    /**
     * The names, or `null` before the first one is added.
     *
     * @remarks
     * Adding an entry can move the array, so a pointer into it does not stay valid.
     *
     * @example
     * ```hx
     * names.items![0]; // 0, the reserved entry
     * ```
     *
     * @since 1.0.0
     */

    items: ?u32[*],

    /**
     * The number of names.
     *
     * @example
     * ```hx
     * names.len; // 3 after three entries
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The number of names that the array has room for.
     *
     * @example
     * ```hx
     * names.cap; // 8 after the first entry, doubling from there
     * ```
     *
     * @since 1.0.0
     */

    cap: u32,
}

/**
 * The result of checking a program, which code generation and the IDE read.
 *
 * @remarks
 * It holds the node infos, the symbol table, the compile-time values, the types, and the aggregates.
 * The checker's state and the tables it holds keep the C layout that they had when the checker was C,
 * where translate-c first generated them from the C headers.
 * The layout file checks the sizes that the code relies on.
 *
 * @example
 * ```hx
 * let sema: HxSema = undefined;
 * hxSemaCheck(&sema, &ast, null, &diags);
 * sema.functions.len; // the number of function bodies
 * ```
 *
 * @see hxSemaCheck
 * @see hxSemaFree
 *
 * @since 1.0.0
 */

export extern "C" struct HxSema {
    /**
     * The syntax tree of the program.
     *
     * @example
     * ```hx
     * sema.ast!.nodesLen; // the number of nodes
     * ```
     *
     * @since 1.0.0
     */

    ast: ?*HxAst,

    /**
     * The source that the tree points into.
     *
     * @example
     * ```hx
     * sema.src; // the source of every file
     * ```
     *
     * @since 1.0.0
     */

    src: ?readonly *HxSource,

    /**
     * The list that receives the diagnostics.
     *
     * @example
     * ```hx
     * sema.diags!.errorCount; // 0 for a program without errors
     * ```
     *
     * @since 1.0.0
     */

    diags: ?*HxDiagList,

    /**
     * The arena that holds the bytes of compile-time strings.
     *
     * @example
     * ```hx
     * sema.arena; // freed by hxSemaFree
     * ```
     *
     * @since 1.0.0
     */

    arena: HxArena,

    /**
     * The interned type table.
     *
     * @example
     * ```hx
     * sema.types.i32; // the id of i32
     * ```
     *
     * @since 1.0.0
     */

    types: HxTypes,

    /**
     * The interner of names, which turns equal texts into equal ids.
     *
     * @example
     * ```hx
     * hxIntern(&sema.names, "main", 4); // the name id of main
     * ```
     *
     * @since 1.0.0
     */

    names: HxInterner,

    /**
     * The node infos, one per node of the tree, outside any generic instance.
     *
     * @example
     * ```hx
     * infoAt(&sema, 0, node).type; // reads this array
     * ```
     *
     * @since 1.0.0
     */

    info: ?*HxNodeInfo,

    /**
     * The symbol table, where index 0 is the reserved empty symbol.
     *
     * @example
     * ```hx
     * sema.symbols.len; // the number of symbols, the empty one included
     * ```
     *
     * @since 1.0.0
     */

    symbols: HxSymbolVec,

    /**
     * The compile-time values, where index 0 is the empty value.
     *
     * @example
     * ```hx
     * sema.values.len; // the number of values
     * ```
     *
     * @since 1.0.0
     */

    values: HxValueVec,

    /**
     * The value indexes of the elements of aggregate values.
     *
     * @example
     * ```hx
     * sema.valueElems.items![v.elems]; // the first element of v
     * ```
     *
     * @since 1.0.0
     */

    valueElems: HxU32Vec,

    /**
     * The symbols of the functions with a body, which code generation emits.
     *
     * @example
     * ```hx
     * sema.functions.len; // 2 for main and one helper
     * ```
     *
     * @since 1.0.0
     */

    functions: HxU32Vec,

    /**
     * The symbols of the functions without a body, which C defines.
     *
     * @example
     * ```hx
     * sema.externs.len; // 1 for free
     * ```
     *
     * @since 1.0.0
     */

    externs: HxU32Vec,

    /**
     * The symbols of the globals that need storage.
     *
     * @remarks
     * These are the `extern` globals, the mutable globals, and the constant arrays and structs.
     * Other constants are read from their compile-time value instead.
     *
     * @example
     * ```hx
     * sema.globals.len; // 1 for let counter = 0;
     * ```
     *
     * @since 1.0.0
     */

    globals: HxU32Vec,

    /**
     * The aggregates of every struct, enum, union, error set, and interface.
     *
     * @example
     * ```hx
     * sema.aggregates.len; // the number of declared and instantiated types
     * ```
     *
     * @since 1.0.0
     */

    aggregates: HxAggregateVec,

    /**
     * The members of every aggregate, one run per aggregate.
     *
     * @example
     * ```hx
     * sema.members.len; // the number of members
     * ```
     *
     * @since 1.0.0
     */

    members: HxMemberVec,

    /**
     * The interned names of the errors, indexed by error code.
     *
     * @remarks
     * Errors are numbered by name across the program, so `NotFound` has the same code in every set.
     * Entry 0 is reserved, since code 0 means no error.
     *
     * @example
     * ```hx
     * sema.errorNames.items![1]; // the name of the first error that the program declared
     * ```
     *
     * @since 1.0.0
     */

    errorNames: HxNameVec,

    /**
     * The generic instances, numbered from 1.
     *
     * @example
     * ```hx
     * sema.instances.len; // the number of instances
     * ```
     *
     * @since 1.0.0
     */

    instances: HxInstanceVec,

    /**
     * The arguments of every instance, types first and then `comptime` values.
     *
     * @example
     * ```hx
     * sema.instanceArgs.items![instance.argsStart]; // the first argument
     * ```
     *
     * @since 1.0.0
     */

    instanceArgs: HxTypeIdVec,

    /**
     * The parameter tokens that the arguments of every instance bind, in step with the arguments.
     *
     * @example
     * ```hx
     * sema.instanceNames.items![instance.argsStart]; // the token of T
     * ```
     *
     * @since 1.0.0
     */

    instanceNames: HxU32Vec,

    /**
     * The implementations of interfaces found so far.
     *
     * @example
     * ```hx
     * sema.impls.len; // 1 after the first dyn Writer
     * ```
     *
     * @since 1.0.0
     */

    impls: HxImplVec,

    /**
     * The method symbols of every implementation, one run per implementation in vtable order.
     *
     * @example
     * ```hx
     * sema.implMethods.items![impl.methodsStart]; // the first method
     * ```
     *
     * @since 1.0.0
     */

    implMethods: HxU32Vec,

    /**
     * The symbol of `main`, or 0 for a library.
     *
     * @example
     * ```hx
     * sema.entry; // the symbol of main
     * ```
     *
     * @since 1.0.0
     */

    entry: u32,

    /**
     * The startup function that builds the `Init` argument of `main(init: Init)`, or 0.
     *
     * @remarks
     * The `Init` carries the arguments, allocators, and streams that the operating system provides.
     *
     * @example
     * ```hx
     * sema.entryInit; // 0 when main takes no parameters
     * ```
     *
     * @since 1.0.0
     */

    entryInit: u32,

    /**
     * The type `void | Error` of a test body in a test build, or 0.
     *
     * @example
     * ```hx
     * sema.testResult; // 0 outside a test build
     * ```
     *
     * @since 1.0.0
     */

    testResult: u32,

    /**
     * The symbol of the `beginTest` function of the testing module, or 0.
     *
     * @example
     * ```hx
     * sema.testBegin; // called before each test
     * ```
     *
     * @since 1.0.0
     */

    testBegin: u32,

    /**
     * The symbol of the `endTest` function of the testing module, or 0.
     *
     * @example
     * ```hx
     * sema.testEnd; // called after each test
     * ```
     *
     * @since 1.0.0
     */

    testEnd: u32,

    /**
     * The error code of `TestError.RequireFailed`, which a failed `require` throws, or 0.
     *
     * @example
     * ```hx
     * sema.requireCode; // nonzero in a test build
     * ```
     *
     * @since 1.0.0
     */

    requireCode: u32,

    /**
     * The files of the program, or `null` for a single-file check.
     *
     * @example
     * ```hx
     * sema.program; // null for one file
     * ```
     *
     * @since 1.0.0
     */

    program: ?readonly *HxProgram,

    /**
     * The hash table of the scope entries of every module, or `null` before the first one.
     *
     * @example
     * ```hx
     * hxsScopeFind(&sema, 0, name); // searches this table
     * ```
     *
     * @since 1.0.0
     */

    scopes: ?*HxScopeEntry,

    /**
     * The number of slots in the scope table, a power of two that starts at 1024.
     *
     * @example
     * ```hx
     * sema.scopesCap; // 1024
     * ```
     *
     * @since 1.0.0
     */

    scopesCap: u32,

    /**
     * The number of entries in the scope table, which grows to keep at most half of the slots in use.
     *
     * @example
     * ```hx
     * sema.scopesCount; // the number of top-level names and imports
     * ```
     *
     * @since 1.0.0
     */

    scopesCount: u32,
}

/**
 * What the compile-time interpreter needs from the checker.
 *
 * @remarks
 * The interpreter calls back through it to have a function body checked before it runs the function.
 *
 * @example
 * ```hx
 * let host = hxsEvalHost(c);
 * host.sema; // the checker state
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxEvalHost {
    /**
     * The checker state.
     *
     * @example
     * ```hx
     * host.sema!.values.len; // the number of values
     * ```
     *
     * @since 1.0.0
     */

    sema: ?*HxSema,

    /**
     * The C callback that checks the body of a function before it runs at compile time.
     *
     * @remarks
     * It returns `false` for a function whose body failed or that calls itself through `comptime`.
     *
     * @example
     * ```hx
     * host.ensureBody!(host.user, sym); // false when the body cannot run
     * ```
     *
     * @since 1.0.0
     */

    ensureBody: ?extern "C" (a0: ?u8[*], a1: u32) => bool,

    /**
     * The checker context that the callback receives.
     *
     * @example
     * ```hx
     * host.user; // the context as bytes
     * ```
     *
     * @since 1.0.0
     */

    user: ?u8[*],
}

/**
 * A loop that encloses the code being checked.
 *
 * @remarks
 * `break` and `continue` find their loop among these, by label when they have one.
 *
 * @example
 * ```hx
 * c.loops[c.loopCount - 1].node; // the innermost loop
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct Loop {
    /**
     * The loop node.
     *
     * @example
     * ```hx
     * nodeOf(c, loop.node).kind; // NodeKind.While
     * ```
     *
     * @since 1.0.0
     */

    node: u32,

    /**
     * The token of the label of the loop, or `NoToken` without one.
     *
     * @example
     * ```hx
     * tokenText(c, loop.label); // 'outer'
     * ```
     *
     * @since 1.0.0
     */

    label: u32,

    /**
     * Whether a `break` targets the loop.
     *
     * @example
     * ```hx
     * loop.hasBreak; // true when a break ends the loop, so code after it can run
     * ```
     *
     * @since 1.0.0
     */

    hasBreak: bool,
}

/**
 * A generic parameter bound to a concrete type while an instance is being checked.
 *
 * @remarks
 * The checker looks a name up from the innermost binding outward,
 * so an inner generic parameter shadows an outer one with the same name.
 *
 * @example
 * ```hx
 * // T = i32 inside max<i32>
 * param.type; // types(c).i32
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct TypeParam {
    /**
     * The interned name of the parameter.
     *
     * @example
     * ```hx
     * param.name; // the name id of T
     * ```
     *
     * @since 1.0.0
     */

    name: u32,

    /**
     * The type that the parameter is bound to.
     *
     * @example
     * ```hx
     * param.type; // types(c).i32
     * ```
     *
     * @since 1.0.0
     */

    type: u32,
}

/**
 * The growable array of bound type parameters.
 *
 * @remarks
 * The checker uses the array as a stack.
 * It saves the length before it checks an instance, pushes the bindings, and restores the length afterwards.
 *
 * @example
 * ```hx
 * c.typeParams.len; // 1 inside max<i32>
 * ```
 *
 * @see TypeParam
 * @since 1.0.0
 */

export extern "C" struct TypeParamVec {
    /**
     * The bound type parameters, or `null` before the first one is added.
     *
     * @remarks
     * Adding an entry can move the array, so a pointer into it does not stay valid.
     *
     * @example
     * ```hx
     * c.typeParams.items![0]; // T bound to i32
     * ```
     *
     * @since 1.0.0
     */

    items: ?*TypeParam,

    /**
     * The number of bound type parameters.
     *
     * @example
     * ```hx
     * c.typeParams.len; // 3 after three entries
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The number of bound type parameters that the array has room for.
     *
     * @example
     * ```hx
     * c.typeParams.cap; // 8 after the first entry, doubling from there
     * ```
     *
     * @since 1.0.0
     */

    cap: u32,
}

/**
 * The growable array of pending `@compileError` and `@compileLog` calls.
 *
 * @remarks
 * `hxsReportPending` reports only the calls inside functions that the program reaches,
 * then frees the array and resets it to empty.
 *
 * @example
 * ```hx
 * c.pending.len; // the number of calls that wait for the end of the check
 * ```
 *
 * @see Pending
 * @since 1.0.0
 */

export extern "C" struct CtxPending {
    /**
     * The pending calls, or `null` before the first one is added.
     *
     * @remarks
     * Adding an entry can move the array, so a pointer into it does not stay valid.
     *
     * @example
     * ```hx
     * c.pending.items![0]; // the first @compileError
     * ```
     *
     * @since 1.0.0
     */

    items: ?*Pending,

    /**
     * The number of pending calls.
     *
     * @example
     * ```hx
     * c.pending.len; // 3 after three entries
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The number of pending calls that the array has room for.
     *
     * @example
     * ```hx
     * c.pending.cap; // 8 after the first entry, doubling from there
     * ```
     *
     * @since 1.0.0
     */

    cap: u32,
}

/**
 * The checker context: the state of the check that every checking function receives.
 *
 * @remarks
 * {@link hxSemaCheck} makes one context and hands it to every pass.
 * The fields from `returnType` on describe the function being checked,
 * and the checker saves them in a {@link FnState} around checking another function.
 *
 * @example
 * ```hx
 * nodeOf(c, node).kind; // every accessor takes the context first
 * ```
 *
 * @see FnState
 * @see hxSemaCheck
 *
 * @since 1.0.0
 */

export extern "C" struct Ctx {
    /**
     * The checker state that the context fills.
     *
     * @example
     * ```hx
     * c.sema!.symbols.len; // the number of symbols
     * ```
     *
     * @since 1.0.0
     */

    sema: ?*HxSema,

    /**
     * The syntax tree.
     *
     * @example
     * ```hx
     * c.ast!.nodesLen; // the number of nodes
     * ```
     *
     * @since 1.0.0
     */

    ast: ?*HxAst,

    /**
     * The tokens of the tree.
     *
     * @example
     * ```hx
     * c.tokens!.len; // the number of tokens
     * ```
     *
     * @since 1.0.0
     */

    tokens: ?readonly *HxTokens,

    /**
     * The source text that the tokens point into.
     *
     * @example
     * ```hx
     * tokenText(c, token); // reads this text
     * ```
     *
     * @since 1.0.0
     */

    text: ?readonly u8[*],

    /**
     * The type table of the checker state.
     *
     * @example
     * ```hx
     * c.types!.i32; // the id of i32
     * ```
     *
     * @since 1.0.0
     */

    types: ?*HxTypes,

    /**
     * The return type of the function being checked, or 0 outside a function.
     *
     * @example
     * ```hx
     * c.returnType; // types(c).i32 inside function f(): i32
     * ```
     *
     * @since 1.0.0
     */

    returnType: u32,

    /**
     * The symbol of the function being checked, or 0 outside a function.
     *
     * @example
     * ```hx
     * symbolOf(c, c.functionSymbol).token; // the name of the function
     * ```
     *
     * @since 1.0.0
     */

    functionSymbol: u32,

    /**
     * The symbols of the locals in scope, the innermost last.
     *
     * @example
     * ```hx
     * c.scope.len; // 2 inside function f(a: i32, b: i32)
     * ```
     *
     * @since 1.0.0
     */

    scope: HxU32Vec,

    /**
     * The length of the scope where each open block started.
     *
     * @remarks
     * Leaving a block drops its locals and reports the ones that are unused or never reassigned.
     *
     * @example
     * ```hx
     * c.scopeMarks.len; // the number of open blocks
     * ```
     *
     * @since 1.0.0
     */

    scopeMarks: HxU32Vec,

    /**
     * The enclosing loops, the innermost last.
     *
     * @remarks
     * At most {@link MaxLoops} loops nest.
     *
     * @example
     * ```hx
     * c.loops[c.loopCount - 1]; // the innermost loop
     * ```
     *
     * @since 1.0.0
     */

    loops: Loop[64],

    /**
     * The number of enclosing loops.
     *
     * @example
     * ```hx
     * c.loopCount; // 0 outside any loop
     * ```
     *
     * @since 1.0.0
     */

    loopCount: u32,

    /**
     * The loop count where the innermost `defer` or `errdefer` started.
     *
     * @remarks
     * A `break` or a `continue` inside the defer cannot target a loop below it.
     *
     * @example
     * ```hx
     * c.deferFloor; // 0xFFFFFFFF outside any defer
     * ```
     *
     * @since 1.0.0
     */

    deferFloor: u32,

    /**
     * Whether the code being checked is inside a `defer` or an `errdefer`.
     *
     * @example
     * ```hx
     * c.inDefer; // false
     * ```
     *
     * @since 1.0.0
     */

    inDefer: bool,

    /**
     * The number of enclosing `unsafe` blocks.
     *
     * @example
     * ```hx
     * c.unsafeDepth; // 0 where raw pointers cannot be indexed
     * ```
     *
     * @since 1.0.0
     */

    unsafeDepth: u32,

    /**
     * The number of enclosing `comptime` expressions.
     *
     * @example
     * ```hx
     * c.comptimeDepth; // 1 inside comptime f()
     * ```
     *
     * @since 1.0.0
     */

    comptimeDepth: u32,

    /**
     * Whether name lookups skip the locals.
     *
     * @remarks
     * Resolving a global, or the member types and default values of an aggregate, never sees a function's locals.
     *
     * @example
     * ```hx
     * c.globalsOnly; // true while a global is resolved
     * ```
     *
     * @since 1.0.0
     */

    globalsOnly: bool,

    /**
     * Whether a `switch` pattern bound a mutable pointer to the subject being checked.
     *
     * @remarks
     * The subject's variable then counts as mutated, since the code may change it through the pointer.
     *
     * @example
     * ```hx
     * c.pointerBinding; // true for case .Some(*v) on a mutable subject
     * ```
     *
     * @since 1.0.0
     */

    pointerBinding: bool,

    /**
     * The generic instance being checked, or 0.
     *
     * @example
     * ```hx
     * infoOf(c, node); // reads the infos of this instance
     * ```
     *
     * @since 1.0.0
     */

    instance: u32,

    /**
     * The length of the scope where the function being checked starts.
     *
     * @remarks
     * Name lookups stop there, so an arrow function and an instance do not see the locals around them.
     *
     * @example
     * ```hx
     * c.scopeBase; // the locals below it belong to an enclosing function
     * ```
     *
     * @since 1.0.0
     */

    scopeBase: u32,

    /**
     * The type parameters of the instance being checked, bound to its type arguments.
     *
     * @example
     * ```hx
     * c.typeParams.len; // 1 inside max<i32>
     * ```
     *
     * @since 1.0.0
     */

    typeParams: TypeParamVec,

    /**
     * The module whose code is being checked, where names are looked up.
     *
     * @example
     * ```hx
     * c.module; // 0 for the root file
     * ```
     *
     * @since 1.0.0
     */

    module: u32,

    /**
     * The error set of the return type of the function being checked, or 0 when it cannot fail.
     *
     * @example
     * ```hx
     * c.errorSet; // the id of IoError inside function f(): void | IoError
     * ```
     *
     * @since 1.0.0
     */

    errorSet: u32,

    /**
     * The symbols of the optional variables that a `!= null` check proved to hold a value here.
     *
     * @remarks
     * A read of such a variable gives the payload instead of the optional.
     *
     * @example
     * ```hx
     * // if (x != null) { ... }
     * c.narrowed.len; // 1 inside the then branch
     * ```
     *
     * @since 1.0.0
     */

    narrowed: HxU32Vec,

    /**
     * The node that the last conversion started at, where an interface mismatch is reported.
     *
     * @example
     * ```hx
     * c.coerceSite; // the node passed to hxsCoerce
     * ```
     *
     * @since 1.0.0
     */

    coerceSite: u32,

    /**
     * Whether the code being checked is the body of a test.
     *
     * @example
     * ```hx
     * c.inTest; // true inside test("...") { ... }
     * ```
     *
     * @since 1.0.0
     */

    inTest: bool,

    /**
     * Whether the code being checked is the initializer of a global constant.
     *
     * @remarks
     * A constant array there is evaluated together with the rest of the initializer.
     *
     * @example
     * ```hx
     * c.constInit; // true inside const table = [1, 2, 3];
     * ```
     *
     * @since 1.0.0
     */

    constInit: bool,

    /**
     * The number of enclosing branches that a condition known while compiling rules out.
     *
     * @remarks
     * An `@compileError` or an `@compileLog` in such a branch does not fire.
     *
     * @example
     * ```hx
     * // if (false) { @compileError("never"); }
     * c.deadDepth; // 1 inside the then branch
     * ```
     *
     * @since 1.0.0
     */

    deadDepth: u32,

    /**
     * The `@compileError` and `@compileLog` calls that wait for the end of the check.
     *
     * @remarks
     * They fire only in functions that the program reaches.
     *
     * @example
     * ```hx
     * c.pending.len; // 1 after one @compileError
     * ```
     *
     * @since 1.0.0
     */

    pending: CtxPending,

    /**
     * The locals declared `= undefined` that have no value yet.
     *
     * @example
     * ```hx
     * c.unset.len; // 1 after let x: i32 = undefined;
     * ```
     *
     * @see declareUnset
     * @since 1.0.0
     */

    unset: HxU32Vec,

    /**
     * The reads of those locals in the statement being checked, which are reported when it ends.
     *
     * @example
     * ```hx
     * c.unsetReads.len; // 1 inside const y = x;
     * ```
     *
     * @see flushReads
     * @since 1.0.0
     */

    unsetReads: HxU32Vec,

    /**
     * The locals that the statement being checked gives a value, once it ends.
     *
     * @example
     * ```hx
     * c.unsetWrites.len; // 1 inside x = 1;
     * ```
     *
     * @see noteWrite
     * @since 1.0.0
     */

    unsetWrites: HxU32Vec,
}

/**
 * An `@compileError` or an `@compileLog` that fires only if its function is used.
 *
 * @remarks
 * The checker reports it at the end, after it finds the functions that the program reaches.
 *
 * @example
 * ```hx
 * // function never(): void { @compileError("not here"); }
 * pending.functionSymbol; // the symbol of never
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct Pending {
    /**
     * The function that contains the call, or 0 outside a function, where it always fires.
     *
     * @example
     * ```hx
     * pending.functionSymbol; // 0 for a call in a global initializer
     * ```
     *
     * @since 1.0.0
     */

    functionSymbol: u32,

    /**
     * The call node, where the message is reported.
     *
     * @example
     * ```hx
     * nodeOf(c, pending.node).kind; // NodeKind.BuiltinCall
     * ```
     *
     * @since 1.0.0
     */

    node: u32,

    /**
     * The message, NUL-terminated and owned by the pending entry.
     *
     * @example
     * ```hx
     * cString(pending.message!); // 'not here'
     * ```
     *
     * @since 1.0.0
     */

    message: ?u8[*],

    /**
     * Whether the call is an `@compileLog`, whose error starts with `compile log:` and stops the build.
     *
     * @example
     * ```hx
     * pending.log; // true for @compileLog
     * ```
     *
     * @since 1.0.0
     */

    log: bool,
}

/**
 * Everything that describes the function being checked, saved around checking another one.
 *
 * @remarks
 * Each field mirrors the field of {@link Ctx} with the same name.
 * The vectors keep only their length, since checking the other function only adds entries.
 *
 * @example
 * ```hx
 * let saved: FnState = undefined;
 * hxsSaveState(c, &saved);
 * // check another function
 * hxsRestoreState(c, &saved);
 * ```
 *
 * @see Ctx
 * @since 1.0.0
 */

export extern "C" struct FnState {
    /**
     * The saved return type.
     *
     * @example
     * ```hx
     * saved.returnType; // types(c).i32
     * ```
     *
     * @since 1.0.0
     */

    returnType: u32,

    /**
     * The saved error set.
     *
     * @example
     * ```hx
     * saved.errorSet; // 0 for a function that cannot fail
     * ```
     *
     * @since 1.0.0
     */

    errorSet: u32,

    /**
     * The saved function symbol.
     *
     * @example
     * ```hx
     * saved.functionSymbol; // the symbol of the outer function
     * ```
     *
     * @since 1.0.0
     */

    functionSymbol: u32,

    /**
     * The saved number of enclosing loops.
     *
     * @example
     * ```hx
     * saved.loopCount; // 1
     * ```
     *
     * @since 1.0.0
     */

    loopCount: u32,

    /**
     * The saved loop count of the innermost `defer`.
     *
     * @example
     * ```hx
     * saved.deferFloor; // 0xFFFFFFFF
     * ```
     *
     * @since 1.0.0
     */

    deferFloor: u32,

    /**
     * The saved number of enclosing `unsafe` blocks.
     *
     * @example
     * ```hx
     * saved.unsafeDepth; // 0
     * ```
     *
     * @since 1.0.0
     */

    unsafeDepth: u32,

    /**
     * The saved number of enclosing `comptime` expressions.
     *
     * @example
     * ```hx
     * saved.comptimeDepth; // 0
     * ```
     *
     * @since 1.0.0
     */

    comptimeDepth: u32,

    /**
     * The saved length of the narrowed variables.
     *
     * @example
     * ```hx
     * saved.narrowedLen; // 1
     * ```
     *
     * @since 1.0.0
     */

    narrowedLen: u32,

    /**
     * The saved start of the function's locals.
     *
     * @example
     * ```hx
     * saved.scopeBase; // 0
     * ```
     *
     * @since 1.0.0
     */

    scopeBase: u32,

    /**
     * The saved number of bound type parameters.
     *
     * @example
     * ```hx
     * saved.typeParamsLen; // 0
     * ```
     *
     * @since 1.0.0
     */

    typeParamsLen: u32,

    /**
     * The saved generic instance.
     *
     * @example
     * ```hx
     * saved.instance; // 0
     * ```
     *
     * @since 1.0.0
     */

    instance: u32,

    /**
     * The saved module.
     *
     * @example
     * ```hx
     * saved.module; // 0
     * ```
     *
     * @since 1.0.0
     */

    module: u32,

    /**
     * The saved state of being inside a `defer`.
     *
     * @example
     * ```hx
     * saved.inDefer; // false
     * ```
     *
     * @since 1.0.0
     */

    inDefer: bool,

    /**
     * The saved state of lookups that skip the locals.
     *
     * @example
     * ```hx
     * saved.globalsOnly; // false
     * ```
     *
     * @since 1.0.0
     */

    globalsOnly: bool,

    /**
     * The saved state of a pointer binding in a `switch`.
     *
     * @example
     * ```hx
     * saved.pointerBinding; // false
     * ```
     *
     * @since 1.0.0
     */

    pointerBinding: bool,

    /**
     * The saved state of being inside a test.
     *
     * @example
     * ```hx
     * saved.inTest; // false
     * ```
     *
     * @since 1.0.0
     */

    inTest: bool,

    /**
     * The saved number of ruled-out branches.
     *
     * @example
     * ```hx
     * saved.deadDepth; // 0
     * ```
     *
     * @since 1.0.0
     */

    deadDepth: u32,

    /**
     * The saved enclosing loops.
     *
     * @example
     * ```hx
     * saved.loops[0].node; // the outermost loop
     * ```
     *
     * @since 1.0.0
     */

    loops: Loop[64],
}

/**
 * The variants of a `switch` subject that its cases cover, for the check that the cases are exhaustive.
 *
 * @remarks
 * A case with a guard covers nothing, since its guard may fail.
 *
 * @example
 * ```hx
 * // switch (flag) { case true: ... }
 * coverage.count; // 2, and one of the two flags is set
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct Coverage {
    /**
     * One flag per variant, set when a case without a guard covers it, or `null`.
     *
     * @example
     * ```hx
     * coverage.covered![0]; // true once the first variant has a case
     * ```
     *
     * @since 1.0.0
     */

    covered: ?bool[*],

    /**
     * The number of variants, 2 for a `bool` and the field count of an enum or a union.
     *
     * @example
     * ```hx
     * coverage.count; // 3 for enum Color { Red, Green, Blue }
     * ```
     *
     * @since 1.0.0
     */

    count: u32,

    /**
     * Whether a `default` or an irrefutable pattern without a guard covers every value.
     *
     * @example
     * ```hx
     * coverage.catchAll; // true after default: { ... }
     * ```
     *
     * @since 1.0.0
     */

    catchAll: bool,
}

/**
 * The walk that finds the functions that the program reaches, for reporting `@compileError` and `@compileLog`.
 *
 * @remarks
 * The walk starts at `main`, the tests, functions that C can call, implementations of interfaces,
 * and the code outside function bodies, then follows every call and function value.
 *
 * @example
 * ```hx
 * hxsReach(&r, semaOf(c).entry); // starts the walk at main
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct Reach {
    /**
     * The checker state.
     *
     * @example
     * ```hx
     * r.sema!.symbols.len; // the number of symbols
     * ```
     *
     * @since 1.0.0
     */

    sema: ?*HxSema,

    /**
     * One flag per symbol, set once the walk reaches the function.
     *
     * @example
     * ```hx
     * r.reached![sym]; // true for main
     * ```
     *
     * @since 1.0.0
     */

    reached: ?bool[*],

    /**
     * The reached functions whose bodies the walk has not visited yet.
     *
     * @example
     * ```hx
     * r.work.len; // 0 when the walk is done
     * ```
     *
     * @since 1.0.0
     */

    work: HxU32Vec,
}

/**
 * The growable array of 32-bit numbers, such as symbols or node indexes.
 *
 * @remarks
 * `pushU32` grows the array through `hxVecGrowImpl`, which doubles the room and starts at eight entries.
 * Arrays with the same layout, such as {@link HxNameVec}, reuse it through a pointer cast.
 *
 * @example
 * ```hx
 * pushU32(&c.scope, sym);
 * u32At(&c.scope, 0); // sym
 * ```
 *
 * @see pushU32
 * @see u32At
 *
 * @since 1.0.0
 */

export extern "C" struct HxU32Vec {
    /**
     * The numbers, or `null` before the first one is added.
     *
     * @remarks
     * Adding an entry can move the array, so a pointer into it does not stay valid.
     *
     * @example
     * ```hx
     * vec.items![0]; // the first number pushed
     * ```
     *
     * @since 1.0.0
     */

    items: ?u32[*],

    /**
     * The number of numbers.
     *
     * @example
     * ```hx
     * vec.len; // 3 after three entries
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The number of numbers that the array has room for.
     *
     * @example
     * ```hx
     * vec.cap; // 8 after the first entry, doubling from there
     * ```
     *
     * @since 1.0.0
     */

    cap: u32,
}

/**
 * The growable array of type ids, with the same layout as {@link HxU32Vec}.
 *
 * @remarks
 * The shared layout lets the checker push to it with the same helpers as {@link HxU32Vec}.
 * It holds the type arguments of every generic instance, which `argsStart` on an instance indexes.
 *
 * @example
 * ```hx
 * semaOf(c).instanceArgs.len; // the number of instance arguments
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxTypeIdVec {
    /**
     * The type ids, or `null` before the first one is added.
     *
     * @remarks
     * Adding an entry can move the array, so a pointer into it does not stay valid.
     *
     * @example
     * ```hx
     * vec.items![0]; // the first type id pushed
     * ```
     *
     * @since 1.0.0
     */

    items: ?u32[*],

    /**
     * The number of type ids.
     *
     * @example
     * ```hx
     * vec.len; // 3 after three entries
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The number of type ids that the array has room for.
     *
     * @example
     * ```hx
     * vec.cap; // 8 after the first entry, doubling from there
     * ```
     *
     * @since 1.0.0
     */

    cap: u32,
}
