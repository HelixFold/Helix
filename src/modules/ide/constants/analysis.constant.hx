/**
 * Imports
 */

import { HxMember } from "@structs/sema.struct";
import { NoToken } from "@constants/ast.constant";
import { Target } from "@modules/ide/components/structs/analysis-component.struct";

/**
 * The member of a target that is not a member.
 *
 * @example
 * ```hx
 * NoMember.token; // NoToken
 * ```
 *
 * @since 1.0.0
 */

export const NoMember = HxMember { kind: 0, name: 0, token: NoToken, type: 0, defaultValue: 0, value: 0, index: 0, symbol: 0, decl: 0 };

/**
 * The target of a name that refers to nothing.
 *
 * @example
 * ```hx
 * resolve(c, t); // Nowhere for a token that no node names
 * ```
 *
 * @since 1.0.0
 */

export const Nowhere = Target { token: NoToken, symbol: 0, isMember: false, member: NoMember };

/**
 * The token types of the semantic tokens legend, as a JSON array.
 *
 * @remarks
 * `initialize` announces it, and the type of a token is its index in this array.
 *
 * @example
 * ```hx
 * TokenTypes; // '["namespace","type","struct",...,"macro"]'
 * ```
 *
 * @since 1.0.0
 */

export const TokenTypes = "[\"namespace\",\"type\",\"struct\",\"enum\",\"interface\",\"typeParameter\",\"parameter\",\"variable\",\"property\",\"enumMember\",\"function\",\"method\",\"keyword\",\"comment\",\"string\",\"number\",\"operator\",\"macro\"]";

/**
 * The token modifiers of the semantic tokens legend, as a JSON array.
 *
 * @remarks
 * `initialize` announces it, and the modifiers of a token are a bit set over this array.
 *
 * @example
 * ```hx
 * TokenModifiers; // '["declaration","readonly","defaultLibrary","documentation"]'
 * ```
 *
 * @since 1.0.0
 */

export const TokenModifiers = "[\"declaration\",\"readonly\",\"defaultLibrary\",\"documentation\"]";

/**
 * The token type of a module namespace.
 *
 * @example
 * ```hx
 * TNamespace; // 0
 * ```
 *
 * @since 1.0.0
 */

export const TNamespace: u8 = 0;

/**
 * The token type of a type that is not a struct, enum, or interface.
 *
 * @example
 * ```hx
 * TType; // 1
 * ```
 *
 * @since 1.0.0
 */

export const TType: u8 = 1;

/**
 * The token type of a struct or a union.
 *
 * @example
 * ```hx
 * TStruct; // 2
 * ```
 *
 * @since 1.0.0
 */

export const TStruct: u8 = 2;

/**
 * The token type of an enum or an error set.
 *
 * @example
 * ```hx
 * TEnum; // 3
 * ```
 *
 * @since 1.0.0
 */

export const TEnum: u8 = 3;

/**
 * The token type of an interface.
 *
 * @example
 * ```hx
 * TInterface; // 4
 * ```
 *
 * @since 1.0.0
 */

export const TInterface: u8 = 4;

/**
 * The token type of a generic parameter.
 *
 * @example
 * ```hx
 * TTypeParameter; // 5
 * ```
 *
 * @since 1.0.0
 */

export const TTypeParameter: u8 = 5;

/**
 * The token type of a function parameter.
 *
 * @example
 * ```hx
 * TParameter; // 6
 * ```
 *
 * @since 1.0.0
 */

export const TParameter: u8 = 6;

/**
 * The token type of a constant or a variable.
 *
 * @example
 * ```hx
 * TVariable; // 7
 * ```
 *
 * @since 1.0.0
 */

export const TVariable: u8 = 7;

/**
 * The token type of a field.
 *
 * @example
 * ```hx
 * TProperty; // 8
 * ```
 *
 * @since 1.0.0
 */

export const TProperty: u8 = 8;

/**
 * The token type of an enum member, an error member, or a union variant.
 *
 * @example
 * ```hx
 * TEnumMember; // 9
 * ```
 *
 * @since 1.0.0
 */

export const TEnumMember: u8 = 9;

/**
 * The token type of a function.
 *
 * @example
 * ```hx
 * TFunction; // 10
 * ```
 *
 * @since 1.0.0
 */

export const TFunction: u8 = 10;

/**
 * The token type of a method.
 *
 * @example
 * ```hx
 * TMethod; // 11
 * ```
 *
 * @since 1.0.0
 */

export const TMethod: u8 = 11;

/**
 * The token type of a keyword, and of `this` and `Self`.
 *
 * @example
 * ```hx
 * TKeyword; // 12
 * ```
 *
 * @since 1.0.0
 */

export const TKeyword: u8 = 12;

/**
 * The token type of a comment.
 *
 * @example
 * ```hx
 * TComment; // 13
 * ```
 *
 * @since 1.0.0
 */

export const TComment: u8 = 13;

/**
 * The token type of a string, a character, or a piece of a template.
 *
 * @example
 * ```hx
 * TString; // 14
 * ```
 *
 * @since 1.0.0
 */

export const TString: u8 = 14;

/**
 * The token type of a number.
 *
 * @example
 * ```hx
 * TNumber; // 15
 * ```
 *
 * @since 1.0.0
 */

export const TNumber: u8 = 15;

/**
 * The token type of a builtin such as `@ptrCast`.
 *
 * @remarks
 * Index 16, `operator`, is in the legend but no token gets it.
 *
 * @example
 * ```hx
 * TMacro; // 17
 * ```
 *
 * @since 1.0.0
 */

export const TMacro: u8 = 17;

/**
 * The token type of a token that the server leaves uncolored.
 *
 * @example
 * ```hx
 * TNone; // 0xFF
 * ```
 *
 * @since 1.0.0
 */

export const TNone: u8 = 0xFF;

/**
 * The modifier bit of the name in a declaration.
 *
 * @example
 * ```hx
 * MDeclaration; // 1
 * ```
 *
 * @since 1.0.0
 */

export const MDeclaration: u8 = 1;

/**
 * The modifier bit of a constant.
 *
 * @example
 * ```hx
 * MReadonly; // 2
 * ```
 *
 * @since 1.0.0
 */

export const MReadonly: u8 = 2;

/**
 * The modifier bit of a built-in type such as `i32`.
 *
 * @example
 * ```hx
 * MDefaultLibrary; // 4
 * ```
 *
 * @since 1.0.0
 */

export const MDefaultLibrary: u8 = 4;

/**
 * The modifier bit of a doc comment.
 *
 * @example
 * ```hx
 * MDocumentation; // 8
 * ```
 *
 * @since 1.0.0
 */

export const MDocumentation: u8 = 8;

/**
 * The LSP symbol kind of a describe in the outline.
 *
 * @example
 * ```hx
 * SNamespace; // 3
 * ```
 *
 * @since 1.0.0
 */

export const SNamespace: u32 = 3;

/**
 * The LSP symbol kind of a method, and of a test in the outline.
 *
 * @example
 * ```hx
 * SMethod; // 6
 * ```
 *
 * @since 1.0.0
 */

export const SMethod: u32 = 6;

/**
 * The LSP symbol kind of a field.
 *
 * @example
 * ```hx
 * SField; // 8
 * ```
 *
 * @since 1.0.0
 */

export const SField: u32 = 8;

/**
 * The LSP symbol kind of an enum or an error set.
 *
 * @example
 * ```hx
 * SEnum; // 10
 * ```
 *
 * @since 1.0.0
 */

export const SEnum: u32 = 10;

/**
 * The LSP symbol kind of an interface.
 *
 * @example
 * ```hx
 * SInterface; // 11
 * ```
 *
 * @since 1.0.0
 */

export const SInterface: u32 = 11;

/**
 * The LSP symbol kind of a function.
 *
 * @example
 * ```hx
 * SFunction; // 12
 * ```
 *
 * @since 1.0.0
 */

export const SFunction: u32 = 12;

/**
 * The LSP symbol kind of a `let`.
 *
 * @example
 * ```hx
 * SVariable; // 13
 * ```
 *
 * @since 1.0.0
 */

export const SVariable: u32 = 13;

/**
 * The LSP symbol kind of a `const`.
 *
 * @example
 * ```hx
 * SConstant; // 14
 * ```
 *
 * @since 1.0.0
 */

export const SConstant: u32 = 14;

/**
 * The LSP symbol kind of an enum member, an error member, or a union variant.
 *
 * @example
 * ```hx
 * SEnumMember; // 22
 * ```
 *
 * @since 1.0.0
 */

export const SEnumMember: u32 = 22;

/**
 * The LSP symbol kind of a struct or a union.
 *
 * @example
 * ```hx
 * SStruct; // 23
 * ```
 *
 * @since 1.0.0
 */

export const SStruct: u32 = 23;

/**
 * The LSP symbol kind of a type alias.
 *
 * @example
 * ```hx
 * STypeParameter; // 26
 * ```
 *
 * @since 1.0.0
 */

export const STypeParameter: u32 = 26;
