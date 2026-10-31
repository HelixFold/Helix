/**
 * Imports
 */

import { HxSymbolKind, HxValueKind, HxMatcher, HxPrintKind, HxMemberKind } from "@structs/sema.struct";

/**
 * The symbol flag of a variable that may be assigned, a `let` local or a global that is not a constant.
 *
 * @remarks
 * A mutable local that is never reassigned draws the error that it should be declared with `const`.
 *
 * @example
 * ```hx
 * (symbolOf(c, sym).flags & (HxSymMutable as u16)) != 0; // true for let count = 0
 * ```
 *
 * @see HxSymMutated
 * @since 1.0.0
 */

export const HxSymMutable: u32 = 0x01;

/**
 * The symbol flag of a symbol that the program refers to.
 *
 * @remarks
 * A local or a parameter without it is reported as unused when its scope ends.
 *
 * @example
 * ```hx
 * (symbolOf(c, sym).flags & (HxSymUsed as u16)) != 0; // false for an unused local
 * ```
 *
 * @since 1.0.0
 */

export const HxSymUsed: u32 = 0x02;

/**
 * The symbol flag of a variable that is assigned, incremented, or changed through a pointer after it is declared.
 *
 * @remarks
 * Taking a mutable pointer to the variable, or binding a mutable pointer to it in a `switch`, also sets it.
 *
 * @example
 * ```hx
 * (symbolOf(c, sym).flags & (HxSymMutated as u16)) != 0; // true after count += 1
 * ```
 *
 * @see HxSymMutable
 * @since 1.0.0
 */

export const HxSymMutated: u32 = 0x04;

/**
 * The symbol flag of a global whose value or type is being resolved right now.
 *
 * @remarks
 * Meeting the flag again while resolving reports a global that depends on itself.
 *
 * @example
 * ```hx
 * // const a: i32 = b;   const b: i32 = a;
 * // resolving b while a is resolving reports that a depends on itself
 * ```
 *
 * @see HxSymResolved
 * @since 1.0.0
 */

export const HxSymResolving: u32 = 0x08;

/**
 * The symbol flag of a global, a type, or an import whose type is known.
 *
 * @example
 * ```hx
 * (symbolOf(c, sym).flags & (HxSymResolved as u16)) != 0; // true once the global is resolved
 * ```
 *
 * @see HxSymResolving
 * @since 1.0.0
 */

export const HxSymResolved: u32 = 0x10;

/**
 * The symbol flag of an `extern` function or global, which C defines or which uses the C calling convention.
 *
 * @remarks
 * The type of such a function as a value uses the C calling convention,
 * and an `extern "C"` function with a body counts as reachable for `@compileError`.
 *
 * @example
 * ```hx
 * (symbolOf(c, sym).flags & (HxSymExtern as u16)) != 0; // true for extern "C" function free(...)
 * ```
 *
 * @since 1.0.0
 */

export const HxSymExtern: u32 = 0x20;

/**
 * The symbol flag of the `main` function that the program starts at.
 *
 * @example
 * ```hx
 * (symbolOf(c, semaOf(c).entry).flags & (HxSymEntry as u16)) != 0; // true
 * ```
 *
 * @since 1.0.0
 */

export const HxSymEntry: u32 = 0x40;

/**
 * The symbol flag of a variable whose address the program takes with `&`.
 *
 * @remarks
 * Code generation gives such a constant its own storage even when its value is known while compiling.
 *
 * @example
 * ```hx
 * (symbolOf(c, sym).flags & (HxSymAddressed as u16)) != 0; // true after &count
 * ```
 *
 * @since 1.0.0
 */

export const HxSymAddressed: u32 = 0x80;

/**
 * The symbol flag of a template, a generic function or type, or a method of one.
 *
 * @remarks
 * A template is not checked by itself.
 * Each use with concrete type arguments or `comptime` values makes an instance, which is checked instead.
 *
 * @example
 * ```hx
 * (symbolOf(c, sym).flags & (HxSymGeneric as u16)) != 0; // true for function max<T>(...)
 * ```
 *
 * @see HxSymTemplateMethod
 * @since 1.0.0
 */

export const HxSymGeneric: u32 = 0x100;

/**
 * The symbol flag of an arrow function, which is checked where it is written.
 *
 * @example
 * ```hx
 * (symbolOf(c, sym).flags & (HxSymArrow as u16)) != 0; // true for (a: i32): i32 => a + 1
 * ```
 *
 * @since 1.0.0
 */

export const HxSymArrow: u32 = 0x200;

/**
 * The symbol flag of a function whose body is being checked right now.
 *
 * @remarks
 * A function that calls itself through `comptime` while its body is still being checked is an error.
 *
 * @example
 * ```hx
 * // function f(): i32 { return comptime f(); }
 * // error: `f` runs at compile time while it's still being checked
 * ```
 *
 * @see HxSymChecked
 * @since 1.0.0
 */

export const HxSymChecking: u32 = 0x400;

/**
 * The symbol flag of a function whose body has been checked.
 *
 * @example
 * ```hx
 * (symbolOf(c, sym).flags & (HxSymChecked as u16)) != 0; // true after the bodies pass
 * ```
 *
 * @see HxSymFailed
 * @since 1.0.0
 */

export const HxSymChecked: u32 = 0x800;

/**
 * The symbol flag of a function whose body reported an error when it was checked.
 *
 * @remarks
 * The compile-time interpreter refuses to run such a function.
 *
 * @example
 * ```hx
 * (symbolOf(c, sym).flags & (HxSymFailed as u16)) != 0; // true when the body had an error
 * ```
 *
 * @since 1.0.0
 */

export const HxSymFailed: u32 = 0x1000;

/**
 * The symbol flag of a method with its own type or `comptime` parameters, which gets an instance for each call.
 *
 * @remarks
 * Such a method cannot fill a slot of an interface or be the `next` method of a `for-of` loop.
 *
 * @example
 * ```hx
 * // struct List { function map<U>(this: *List, f: (x: i32) => U): U[] { ... } }
 * (symbolOf(c, map).flags & (HxSymTemplateMethod as u16)) != 0; // true
 * ```
 *
 * @see HxSymGeneric
 * @since 1.0.0
 */

export const HxSymTemplateMethod: u32 = 0x2000;

/**
 * The node info flag of an optional variable read where a `!= null` check proved it holds a value.
 *
 * @example
 * ```hx
 * // if (x != null) use(x);
 * (infoOf(c, read).flags & HxInfoNarrowed) != 0; // true, the read gives the payload
 * ```
 *
 * @since 1.0.0
 */

export const HxInfoNarrowed: u32 = 0x01;

/**
 * The node info flag of a call to a method, whose receiver is passed as the first argument.
 *
 * @example
 * ```hx
 * // list.push(1)
 * (infoOf(c, call).flags & HxInfoMethod) != 0; // true
 * ```
 *
 * @see HxInfoReceiverAddr
 * @since 1.0.0
 */

export const HxInfoMethod: u32 = 0x02;

/**
 * The node info flag of a method call or a `for-of` loop that passes the address of its receiver.
 *
 * @remarks
 * The method takes `this: *T` while the receiver is a value, so the call takes the value's address.
 *
 * @example
 * ```hx
 * // list.push(1) where push takes this: *List
 * (infoOf(c, call).flags & HxInfoReceiverAddr) != 0; // true
 * ```
 *
 * @since 1.0.0
 */

export const HxInfoReceiverAddr: u32 = 0x04;

/**
 * The node info flag of a union variant without a payload, used as a value or as a pattern.
 *
 * @remarks
 * The info's `aux` holds the index of the variant.
 *
 * @example
 * ```hx
 * // const s = Shape.Empty;
 * (infoOf(c, node).flags & HxInfoUnionInit) != 0; // true
 * ```
 *
 * @since 1.0.0
 */

export const HxInfoUnionInit: u32 = 0x08;

/**
 * The node info flag of a field access that reads a struct field.
 *
 * @remarks
 * The info's `aux` holds the index of the field.
 *
 * @example
 * ```hx
 * // point.x
 * (infoOf(c, access).flags & HxInfoField) != 0; // true
 * ```
 *
 * @see HxInfoDeref
 * @since 1.0.0
 */

export const HxInfoField: u32 = 0x10;

/**
 * The node info flag of a field access, a method call, or a `for-of` loop that goes through a pointer first.
 *
 * @example
 * ```hx
 * // p.x where p is a *Point
 * (infoOf(c, access).flags & HxInfoDeref) != 0; // true
 * ```
 *
 * @see HxInfoField
 * @since 1.0.0
 */

export const HxInfoDeref: u32 = 0x20;

/**
 * The node info flag of a call to `print`, `println`, `eprint`, or `eprintln`.
 *
 * @remarks
 * The info's `aux` holds the {@link HxPrintKind}.
 *
 * @example
 * ```hx
 * // println(`total: ${n}`)
 * (infoOf(c, call).flags & HxInfoPrint) != 0; // true
 * ```
 *
 * @since 1.0.0
 */

export const HxInfoPrint: u32 = 0x40;

/**
 * The node info flag of `ns.name`, where `ns` is a module imported with `import * as ns`.
 *
 * @example
 * ```hx
 * // import * as math from "./math";   math.pi
 * (infoOf(c, access).flags & HxInfoModuleRef) != 0; // true
 * ```
 *
 * @since 1.0.0
 */

export const HxInfoModuleRef: u32 = 0x80;

/**
 * The node info flag of a `for-of` loop over a `dyn` value, which calls `next` through the interface.
 *
 * @remarks
 * The info's `aux` holds the slot of `next` in the interface.
 *
 * @example
 * ```hx
 * // for (const x of items) where items is a dyn Iterator
 * (infoOf(c, loop).flags & HxInfoDyn) != 0; // true
 * ```
 *
 * @since 1.0.0
 */

export const HxInfoDyn: u32 = 0x100;

/**
 * The node info flag of a call through a function value, such as a variable or a field.
 *
 * @example
 * ```hx
 * // const f = add;   f(1, 2)
 * (infoOf(c, call).flags & HxInfoIndirect) != 0; // true
 * ```
 *
 * @since 1.0.0
 */

export const HxInfoIndirect: u32 = 0x200;

/**
 * The node info flag of a call to `writeTo` on a `Format`, which formats the template into a writer.
 *
 * @example
 * ```hx
 * // message.writeTo(out)
 * (infoOf(c, call).flags & HxInfoFormatWrite) != 0; // true
 * ```
 *
 * @since 1.0.0
 */

export const HxInfoFormatWrite: u32 = 0x400;

/**
 * The node info flag of a `for-of` loop over an iterator, which calls its `next` method until it returns `null`.
 *
 * @remarks
 * The info's `aux` holds the symbol of the `next` method, or its slot for a `dyn` value.
 *
 * @example
 * ```hx
 * // for (const x of it) where it has next(this: *Self): ?T
 * (infoOf(c, loop).flags & HxInfoIterator) != 0; // true
 * ```
 *
 * @since 1.0.0
 */

export const HxInfoIterator: u32 = 0x800;

/**
 * The node info flag of a matcher call on `expect(...)`, such as `expect(x).toBe(1)`.
 *
 * @remarks
 * The info's `aux` holds the matcher and the bits {@link HxExpectNot} and {@link HxExpectRequire}.
 *
 * @example
 * ```hx
 * (infoOf(c, call).flags & HxInfoExpect) != 0; // true for expect(x).toBe(1)
 * ```
 *
 * @since 1.0.0
 */

export const HxInfoExpect: u32 = 0x1000;

/**
 * The mask of the matcher in the `aux` of an `expect` call.
 *
 * @example
 * ```hx
 * (infoOf(c, call).aux & HxExpectMatcher) == HxMatchToBe; // true for expect(x).toBe(1)
 * ```
 *
 * @see HxMatcher
 * @since 1.0.0
 */

export const HxExpectMatcher: u32 = 0xFF;

/**
 * The bit in the `aux` of an `expect` call that negates the matcher, as `.not` does.
 *
 * @example
 * ```hx
 * (infoOf(c, call).aux & HxExpectNot) != 0; // true for expect(x).not.toBe(1)
 * ```
 *
 * @since 1.0.0
 */

export const HxExpectNot: u32 = 0x100;

/**
 * The bit in the `aux` of an `expect` call that makes a failure stop the test, as `require` does.
 *
 * @example
 * ```hx
 * (infoOf(c, call).aux & HxExpectRequire) != 0; // true for require(x).toBe(1)
 * ```
 *
 * @since 1.0.0
 */

export const HxExpectRequire: u32 = 0x200;

/**
 * The state of an aggregate whose members are being resolved right now.
 *
 * @remarks
 * Meeting a struct or a union in this state while resolving a member means that it contains itself by value.
 *
 * @example
 * ```hx
 * // struct Node { next: Node }
 * // error: `Node` contains itself, so it would be infinitely large
 * ```
 *
 * @see HxAggResolved
 * @since 1.0.0
 */

export const HxAggResolving: u32 = 0x01;

/**
 * The state of an aggregate whose members are known.
 *
 * @remarks
 * An aggregate starts in state 0 until something needs its members.
 *
 * @example
 * ```hx
 * hxsAggregateOf(c, point).state == HxAggResolved as u8; // true after the signatures pass
 * ```
 *
 * @since 1.0.0
 */

export const HxAggResolved: u32 = 0x02;

/**
 * The scope entry flag of a name that the module exports.
 *
 * @remarks
 * A re-export written as `export ... from` also sets it.
 *
 * @example
 * ```hx
 * (entry.flags & (HxScopeExported as u8)) != 0; // true for export function main()
 * ```
 *
 * @since 1.0.0
 */

export const HxScopeExported: u32 = 0x01;

/**
 * The scope entry flag of a name that an `import` brought into the module.
 *
 * @example
 * ```hx
 * (entry.flags & (HxScopeImported as u8)) != 0; // true for import { max } from "./math"
 * ```
 *
 * @since 1.0.0
 */

export const HxScopeImported: u32 = 0x02;

/**
 * The scope entry flag of a name that the module looked up at least once.
 *
 * @remarks
 * An imported name without it is reported as an unused import.
 *
 * @example
 * ```hx
 * (entry.flags & (HxScopeUsed as u8)) != 0; // false for an unused import
 * ```
 *
 * @since 1.0.0
 */

export const HxScopeUsed: u32 = 0x04;

/**
 * The deepest nesting of loops that one function can have.
 *
 * @remarks
 * A loop nested deeper than this is reported as nested too deeply.
 *
 * @example
 * ```hx
 * MaxLoops; // 64
 * ```
 *
 * @since 1.0.0
 */

export const MaxLoops: u32 = 64;

/**
 * The symbol kind of a local variable, a pattern binding, or a caught error.
 *
 * @example
 * ```hx
 * // const total = 0;   inside a function
 * HxSymLocal; // 0
 * ```
 *
 * @since 1.0.0
 */

export const HxSymLocal: HxSymbolKind = 0;

/**
 * The symbol kind of a function parameter.
 *
 * @example
 * ```hx
 * // function f(n: i32)
 * HxSymParam; // 1
 * ```
 *
 * @since 1.0.0
 */

export const HxSymParam: HxSymbolKind = 1;

/**
 * The symbol kind of a global constant or variable, or a constant declared inside a type.
 *
 * @example
 * ```hx
 * // const limit = 10;   at the top level
 * HxSymGlobal; // 2
 * ```
 *
 * @since 1.0.0
 */

export const HxSymGlobal: HxSymbolKind = 2;

/**
 * The symbol kind of a function, a method, an arrow function, or a generic instance of one.
 *
 * @example
 * ```hx
 * HxSymFunction; // 3
 * ```
 *
 * @since 1.0.0
 */

export const HxSymFunction: HxSymbolKind = 3;

/**
 * The symbol kind of a struct, enum, union, error set, interface, or type alias.
 *
 * @example
 * ```hx
 * HxSymType; // 4
 * ```
 *
 * @since 1.0.0
 */

export const HxSymType: HxSymbolKind = 4;

/**
 * The symbol kind of a module namespace, such as `ns` in `import * as ns`.
 *
 * @remarks
 * Its `targetModule` names the module that it stands for.
 *
 * @example
 * ```hx
 * HxSymModule; // 5
 * ```
 *
 * @since 1.0.0
 */

export const HxSymModule: HxSymbolKind = 5;

/**
 * The kind of the empty value that index 0 of the value table holds.
 *
 * @example
 * ```hx
 * HxValueNone; // 0
 * ```
 *
 * @since 1.0.0
 */

export const HxValueNone: HxValueKind = 0;

/**
 * The kind of an integer value, which also stands for an enum value.
 *
 * @example
 * ```hx
 * valueAt(c, hxsIntValue(c, 7)).kind; // HxValueInt as u8
 * ```
 *
 * @since 1.0.0
 */

export const HxValueInt: HxValueKind = 1;

/**
 * The kind of a float value.
 *
 * @example
 * ```hx
 * valueAt(c, hxsFloatValue(c, 0.5)).kind; // HxValueFloat as u8
 * ```
 *
 * @since 1.0.0
 */

export const HxValueFloat: HxValueKind = 2;

/**
 * The kind of a boolean value.
 *
 * @example
 * ```hx
 * valueAt(c, hxsBoolValue(c, true)).kind; // HxValueBool as u8
 * ```
 *
 * @since 1.0.0
 */

export const HxValueBool: HxValueKind = 3;

/**
 * The kind of a string value, such as a string literal.
 *
 * @example
 * ```hx
 * valueAt(c, infoOf(c, literal).value).kind; // HxValueString as u8 for "hi"
 * ```
 *
 * @since 1.0.0
 */

export const HxValueString: HxValueKind = 4;

/**
 * The kind of the value of `undefined`.
 *
 * @example
 * ```hx
 * HxValueUndefined; // 5
 * ```
 *
 * @since 1.0.0
 */

export const HxValueUndefined: HxValueKind = 5;

/**
 * The kind of the value of `null`.
 *
 * @example
 * ```hx
 * HxValueNull; // 6
 * ```
 *
 * @since 1.0.0
 */

export const HxValueNull: HxValueKind = 6;

/**
 * The kind of an error value, whose integer holds the error code.
 *
 * @remarks
 * A `void | E` result that succeeded is an error value with code 0.
 *
 * @example
 * ```hx
 * valueAt(c, hxsErrorValue(c, 2)).integer; // 2
 * ```
 *
 * @since 1.0.0
 */

export const HxValueError: HxValueKind = 7;

/**
 * The kind of a function used as a value, whose integer holds the function's symbol.
 *
 * @example
 * ```hx
 * valueAt(c, infoOf(c, ref).value).integer; // the symbol of add for const f = add;
 * ```
 *
 * @since 1.0.0
 */

export const HxValueFunction: HxValueKind = 8;

/**
 * The kind of an array, a struct, or a constant slice known while compiling.
 *
 * @remarks
 * Its elements are value indexes, stored from `elems` on in {@link HxSema.valueElems}.
 *
 * @example
 * ```hx
 * valueAt(c, index).count; // 3 for [1, 2, 3]
 * ```
 *
 * @since 1.0.0
 */

export const HxValueAggregate: HxValueKind = 9;

/**
 * The matcher `toBe`, which compares with `==`.
 *
 * @example
 * ```hx
 * // expect(x).toBe(1)
 * HxMatchToBe; // 0
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchToBe: HxMatcher = 0;

/**
 * The matcher `toEqual`, which compares contents.
 *
 * @example
 * ```hx
 * // expect(a).toEqual(b)
 * HxMatchToEqual; // 1
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchToEqual: HxMatcher = 1;

/**
 * The matcher `toBeNull`.
 *
 * @example
 * ```hx
 * // expect(x).toBeNull()
 * HxMatchToBeNull; // 2
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchToBeNull: HxMatcher = 2;

/**
 * The matcher `toBeDefined`, which passes for a value that is not `null`.
 *
 * @example
 * ```hx
 * // expect(x).toBeDefined()
 * HxMatchToBeDefined; // 3
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchToBeDefined: HxMatcher = 3;

/**
 * The matcher `toBeTrue`.
 *
 * @example
 * ```hx
 * // expect(ok).toBeTrue()
 * HxMatchToBeTrue; // 4
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchToBeTrue: HxMatcher = 4;

/**
 * The matcher `toBeFalse`.
 *
 * @example
 * ```hx
 * // expect(ok).toBeFalse()
 * HxMatchToBeFalse; // 5
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchToBeFalse: HxMatcher = 5;

/**
 * The matcher `toBeGreaterThan`.
 *
 * @example
 * ```hx
 * // expect(n).toBeGreaterThan(0)
 * HxMatchGreater; // 6
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchGreater: HxMatcher = 6;

/**
 * The matcher `toBeGreaterThanOrEqual`.
 *
 * @example
 * ```hx
 * // expect(n).toBeGreaterThanOrEqual(0)
 * HxMatchGreaterEqual; // 7
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchGreaterEqual: HxMatcher = 7;

/**
 * The matcher `toBeLessThan`.
 *
 * @example
 * ```hx
 * // expect(n).toBeLessThan(9)
 * HxMatchLess; // 8
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchLess: HxMatcher = 8;

/**
 * The matcher `toBeLessThanOrEqual`.
 *
 * @example
 * ```hx
 * // expect(n).toBeLessThanOrEqual(9)
 * HxMatchLessEqual; // 9
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchLessEqual: HxMatcher = 9;

/**
 * The matcher `toBeCloseTo`, for floats.
 *
 * @example
 * ```hx
 * // expect(x).toBeCloseTo(0.3)
 * HxMatchCloseTo; // 10
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchCloseTo: HxMatcher = 10;

/**
 * The matcher `toHaveLength`.
 *
 * @example
 * ```hx
 * // expect(list).toHaveLength(3)
 * HxMatchLength; // 11
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchLength: HxMatcher = 11;

/**
 * The matcher `toContain`.
 *
 * @example
 * ```hx
 * // expect(list).toContain(2)
 * HxMatchContain; // 12
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchContain: HxMatcher = 12;

/**
 * The matcher `toContainEqual`.
 *
 * @example
 * ```hx
 * // expect(list).toContainEqual(item)
 * HxMatchContainEqual; // 13
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchContainEqual: HxMatcher = 13;

/**
 * The matcher `toStartWith`.
 *
 * @example
 * ```hx
 * // expect(text).toStartWith("a")
 * HxMatchStartWith; // 14
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchStartWith: HxMatcher = 14;

/**
 * The matcher `toEndWith`.
 *
 * @example
 * ```hx
 * // expect(text).toEndWith("z")
 * HxMatchEndWith; // 15
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchEndWith: HxMatcher = 15;

/**
 * The matcher `toInclude`.
 *
 * @example
 * ```hx
 * // expect(text).toInclude("mid")
 * HxMatchInclude; // 16
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchInclude: HxMatcher = 16;

/**
 * The matcher `toMatch`.
 *
 * @example
 * ```hx
 * // expect(text).toMatch(pattern)
 * HxMatchMatch; // 17
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchMatch: HxMatcher = 17;

/**
 * The matcher `toThrow`, which passes for a result that holds an error.
 *
 * @example
 * ```hx
 * // expect(parse("x")).toThrow()
 * HxMatchThrow; // 18
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchThrow: HxMatcher = 18;

/**
 * The matcher `toSucceed`, which passes for a result that holds a value.
 *
 * @example
 * ```hx
 * // expect(parse("1")).toSucceed()
 * HxMatchSucceed; // 19
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchSucceed: HxMatcher = 19;

/**
 * The number of matchers.
 *
 * @example
 * ```hx
 * HxMatchCount; // 20
 * ```
 *
 * @since 1.0.0
 */

export const HxMatchCount: HxMatcher = 20;

/**
 * The print kind of `print`, which writes to standard output.
 *
 * @example
 * ```hx
 * HxPrint; // 0
 * ```
 *
 * @since 1.0.0
 */

export const HxPrint: HxPrintKind = 0;

/**
 * The print kind of `println`, which writes a line to standard output.
 *
 * @example
 * ```hx
 * HxPrintln; // 1
 * ```
 *
 * @since 1.0.0
 */

export const HxPrintln: HxPrintKind = 1;

/**
 * The print kind of `eprint`, which writes to standard error.
 *
 * @example
 * ```hx
 * HxEprint; // 2
 * ```
 *
 * @since 1.0.0
 */

export const HxEprint: HxPrintKind = 2;

/**
 * The print kind of `eprintln`, which writes a line to standard error.
 *
 * @example
 * ```hx
 * HxEprintln; // 3
 * ```
 *
 * @since 1.0.0
 */

export const HxEprintln: HxPrintKind = 3;

/**
 * The member kind of a struct field or a union variant.
 *
 * @example
 * ```hx
 * // struct Point { x: i32 }
 * HxMemberField; // 0
 * ```
 *
 * @since 1.0.0
 */

export const HxMemberField: HxMemberKind = 0;

/**
 * The member kind of an enum member.
 *
 * @example
 * ```hx
 * // enum Color { Red }
 * HxMemberEnumValue; // 1
 * ```
 *
 * @since 1.0.0
 */

export const HxMemberEnumValue: HxMemberKind = 1;

/**
 * The member kind of an error in an error set.
 *
 * @example
 * ```hx
 * // error IoError { NotFound }
 * HxMemberError; // 2
 * ```
 *
 * @since 1.0.0
 */

export const HxMemberError: HxMemberKind = 2;

/**
 * The member kind of a method.
 *
 * @example
 * ```hx
 * HxMemberMethod; // 3
 * ```
 *
 * @since 1.0.0
 */

export const HxMemberMethod: HxMemberKind = 3;

/**
 * The member kind of a constant declared inside a type.
 *
 * @example
 * ```hx
 * // struct Limits { const max = 10; }
 * HxMemberConst; // 4
 * ```
 *
 * @since 1.0.0
 */

export const HxMemberConst: HxMemberKind = 4;

/**
 * The member kind of a method signature in an interface.
 *
 * @example
 * ```hx
 * // interface Writer { function write(this: *Self, b: readonly u8[]): void; }
 * HxMemberSignature; // 5
 * ```
 *
 * @since 1.0.0
 */

export const HxMemberSignature: HxMemberKind = 5;
