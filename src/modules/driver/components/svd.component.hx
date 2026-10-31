/**
 * Imports
 */

import { Builder } from "std/fmt";
import { ArrayList } from "std/list";
import { cAllocator } from "std/heap";
import { equal, startsWith, indexOf } from "std/text";
import * as os from "@modules/driver/components/os.component";
import { hxFatalMessage } from "@components/memory.component";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { keyword } from "@modules/lexer/components/token.component";
import { Strings } from "@modules/driver/components/structs/os-component.struct";
import { allocCString, add, strings } from "@modules/driver/components/os.component";
import { XNode, Field, Reg, Periph, PType, Irq } from "@modules/driver/components/structs/svd-component.struct";

/**
 * Stops the compiler with an out of memory error.
 *
 * @remarks
 * Every list and builder in this file grows on the C heap, and each failed append ends here.
 *
 * @since 1.0.0
 */

function outOfMemory(): noreturn {
    hxFatalMessage("out of memory");
}

/**
 * The nodes of the document that {@link parseXml} read last.
 *
 * @remarks
 * Node 0 is the document itself, and its children are the top-level elements.
 *
 * @since 1.0.0
 */

let xml: ArrayList<XNode> = undefined;

/**
 * Adds an element without text or children to the document.
 *
 * @param name - The tag name
 * @param attrs - The raw attribute text of the start tag
 * @returns The index of the new node
 *
 * @remarks
 * The name and the attributes are views of the XML text, so the text must outlive the document.
 * {@link parseXml} fills in the text of an element once it reaches the closing tag.
 *
 * @since 1.0.0
 */

function newNode(name: string, attrs: string): u32 {
    xml.append(XNode { name, attrs, text: "", children: ArrayList<u32>.init(cAllocator()) }) catch outOfMemory();
    return (xml.items.len - 1) as u32;
}

/**
 * Checks whether a byte is XML white space.
 *
 * @param c - The byte to check
 * @returns `true` for a space, a tab, a carriage return, or a line feed
 *
 * @remarks
 * These are the four bytes that XML treats as white space, so a form feed or a non-breaking space does not count.
 *
 * @since 1.0.0
 */

function isSpace(c: u8): bool {
    return c == ' ' || c == '\n' || c == '\t' || c == '\r';
}

/**
 * Parses a text into the node list of this file.
 *
 * @param text - The XML text
 * @param error - Where the reason goes when the text is not well-formed
 * @returns `true` when every element is closed, otherwise `false` with `error` set
 *
 * @remarks
 * Node 0 holds the document, so the document element is its first child.
 * A closing tag only ends the innermost open element and does not check its name.
 * A markup construct that never ends, such as a comment without `-->`, stops the reading early,
 * and any element still open then makes the text fail.
 *
 * @since 1.0.0
 */

function parseXml(text: string, error: *string): bool {
    xml = ArrayList<XNode>.init(cAllocator());
    void newNode("", "");
    let stack = ArrayList<u32>.init(cAllocator());
    let contentStart = ArrayList<usize>.init(cAllocator());
    stack.append(0) catch outOfMemory();
    contentStart.append(0) catch outOfMemory();
    let i: usize = 0;
    while (i < text.len) {
        if (text[i] != '<') {
            i++;
            continue;
        }
        const rest = text[i..];
        if (startsWith(rest, "<!--")) {
            const end = indexOf(rest, "-->");
            if (end == null) break;
            i += end + 3;
        } else if (startsWith(rest, "<![CDATA[")) {
            const end = indexOf(rest, "]]>");
            if (end == null) break;
            i += end + 3;
        } else if (startsWith(rest, "<?") || startsWith(rest, "<!")) {
            const end = indexOf(rest, ">");
            if (end == null) break;
            i += end + 1;
        } else if (startsWith(rest, "</")) {
            const end = indexOf(rest, ">");
            if (end == null) break;
            if (stack.items.len <= 1) {
                *error = allocCString(`a closing tag without an opening one at byte ${i}`);
                return false;
            }
            const open = stack.items[stack.items.len - 1];
            xml.items[open].text = text[contentStart.items[contentStart.items.len - 1]..i];
            stack.items = stack.items[0..stack.items.len - 1];
            contentStart.items = contentStart.items[0..contentStart.items.len - 1];
            i += end + 1;
        } else {
            const end = indexOf(rest, ">");
            if (end == null) break;
            const tag = rest[1..end];
            const selfClosing = tag.len > 0 && tag[tag.len - 1] == '/';
            const body = selfClosing ? tag[0..tag.len - 1] : tag;
            let n: usize = 0;
            while (n < body.len && !isSpace(body[n])) n++;
            const node = newNode(body[0..n], body[n..]);
            const parent = stack.items[stack.items.len - 1];
            xml.items[parent].children.append(node) catch outOfMemory();
            i += end + 1;
            if (!selfClosing) {
                stack.append(node) catch outOfMemory();
                contentStart.append(i) catch outOfMemory();
            }
        }
    }
    if (stack.items.len != 1) {
        *error = allocCString(`<${xml.items[stack.items[stack.items.len - 1]].name}> is never closed`);
        return false;
    }
    return true;
}

/**
 * Removes the white space at both ends of a text.
 *
 * @param text - The text to trim
 * @returns The text without leading or trailing white space
 *
 * @remarks
 * The result is a view of the text, not a copy, and white space inside the text stays.
 *
 * @since 1.0.0
 */

function trim(text: string): string {
    let a: usize = 0;
    let b = text.len;
    while (a < b && isSpace(text[a])) a++;
    while (b > a && isSpace(text[b - 1])) b--;
    return text[a..b];
}

/**
 * Decodes the text of an element or an attribute for use in the output.
 *
 * @param raw - The raw text
 * @returns The text, trimmed, with each run of white space made one space and the five XML entities decoded
 *
 * @remarks
 * Only `&amp;`, `&lt;`, `&gt;`, `&quot;`, and `&apos;` are decoded.
 * Any other `&` stays as it is.
 *
 * @since 1.0.0
 */

function plain(raw: string): string {
    const text = trim(raw);
    let b = Builder.init(cAllocator());
    let space = false;
    let i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (isSpace(c)) {
            space = true;
            i++;
            continue;
        }
        if (space) b.write(" ") catch outOfMemory();
        space = false;
        const entities: string[5] = ["&amp;", "&lt;", "&gt;", "&quot;", "&apos;"];
        const chars: string[5] = ["&", "<", ">", "\"", "'"];
        let replaced = false;
        if (c == '&') {
            for (const e, k of entities) {
                if (startsWith(text[i..], e)) {
                    b.write(chars[k]) catch outOfMemory();
                    i += e.len;
                    replaced = true;
                    break;
                }
            }
        }
        if (replaced) continue;
        b.write(text[i..i + 1]) catch outOfMemory();
        i++;
    }
    return allocCString(`${b.text()}`);
}

/**
 * Finds the first child element with a name.
 *
 * @param node - The index of the parent
 * @param name - The tag name to find
 * @returns The index of the child, or 0 when the parent has no such child
 *
 * @remarks
 * Node 0 is the document itself, which is never a child, so 0 safely means that nothing was found.
 * Passing 0 as the parent searches the top-level elements.
 *
 * @since 1.0.0
 */

function child(node: u32, name: string): u32 {
    for (const c of xml.items[node].children.items) {
        if (equal(xml.items[c].name, name)) return c;
    }
    return 0;
}

/**
 * Reads the decoded text of the first child element with a name.
 *
 * @param node - The index of the parent
 * @param name - The tag name to find
 * @returns The text of the child, or an empty string when the parent has no such child
 *
 * @remarks
 * The text goes through {@link plain}, so it comes back trimmed and with its entities decoded.
 * A missing child and an empty one both give an empty string.
 *
 * @since 1.0.0
 */

function childText(node: u32, name: string): string {
    const c = child(node, name);
    return c == 0 ? "" : plain(xml.items[c].text);
}

/**
 * Reads the decoded value of an attribute.
 *
 * @param node - The index of the element
 * @param name - The attribute name
 * @returns The value, or an empty string when the element does not have the attribute
 *
 * @remarks
 * Only double-quoted values are found.
 *
 * @since 1.0.0
 */

function attribute(node: u32, name: string): string {
    const attrs = xml.items[node].attrs;
    const key = allocCString(`${name}="`);
    const at = indexOf(attrs, key);
    if (at == null) return "";
    const start = at + key.len;
    let end = start;
    while (end < attrs.len && attrs[end] != '"') end++;
    return plain(attrs[start..end]);
}

/**
 * Reads a number as an SVD file writes it.
 *
 * @param text - The text to read, such as `0x4002_0000`, `1024`, or the SVD binary form `#0101`
 * @returns The value, or `null` when the text is not a number
 *
 * @remarks
 * White space around the number is ignored, and `_` may separate digits.
 *
 * @since 1.0.0
 */

function number(text: string): ?u64 {
    const t = trim(text);
    if (t.len == 0) return null;
    let base: u64 = 10;
    let digits = t;
    if (startsWith(t, "0x") || startsWith(t, "0X")) {
        base = 16;
        digits = t[2..];
    } else if (t[0] == '#') {
        base = 2;
        digits = t[1..];
    }
    if (digits.len == 0) return null;
    let n: u64 = 0;
    for (const c of digits) {
        let d: u64 = 99;
        if (c >= '0' && c <= '9') d = (c - '0') as u64;
        else if (c >= 'a' && c <= 'f') d = (c - 'a') as u64 + 10;
        else if (c >= 'A' && c <= 'F') d = (c - 'A') as u64 + 10;
        else if (c == '_') continue;
        if (d >= base) return null;
        n = n * base + d;
    }
    return n;
}

/**
 * Reads a number, with a value to use when the text is not one.
 *
 * @param text - The text to read
 * @param fallback - The value for a missing or unreadable number
 * @returns The number, or `fallback`
 *
 * @remarks
 * SVD leaves many values to defaults, such as a `dimIncrement` or a `size` that a register inherits,
 * and this function supplies those defaults.
 *
 * @since 1.0.0
 */

function numberOr(text: string, fallback: u64): u64 {
    return number(text) ?? fallback;
}

/**
 * Every top-level name that the output declares, which keeps the names apart.
 *
 * @since 1.0.0
 */

let used: Strings = undefined;

/**
 * Checks whether the output already declares a top-level name.
 *
 * @param name - The name to check
 * @returns `true` when the name is taken
 *
 * @remarks
 * It is a linear search over every name taken so far, which stays small for one device.
 *
 * @since 1.0.0
 */

function isUsed(name: string): bool {
    for (const u of used.items) {
        if (equal(u, name)) return true;
    }
    return false;
}

/**
 * Makes a name a Helix identifier.
 *
 * @param name - The SVD name
 * @returns The name with every byte other than a letter, a digit, or `_` made `_`
 *
 * @remarks
 * A name that starts with a digit gets a `_` before it, and a keyword gets a `_` after it.
 * An empty name becomes `_`.
 *
 * @since 1.0.0
 */

function identifier(name: string): string {
    let b = Builder.init(cAllocator());
    for (const c, i of name) {
        const ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
        if (i == 0 && c >= '0' && c <= '9') b.write("_") catch outOfMemory();
        b.write(ok ? name[i..i + 1] : "_") catch outOfMemory();
    }
    const out = allocCString(`${b.text()}`);
    if (out.len == 0) return "_";
    return keyword(out) != TokenKind.Ident ? allocCString(`${out}_`) : out;
}

/**
 * Makes a name a type name in Pascal case.
 *
 * @param name - The SVD name, such as `OTG_FS_GLOBAL`
 * @returns The type name, such as `OtgFsGlobal`
 *
 * @remarks
 * Each byte other than a letter or a digit ends a word and is dropped.
 * The first letter of a word becomes upper case, and the other letters become lower case.
 * A result that is empty or starts with a digit gets a `P` before it.
 *
 * @since 1.0.0
 */

function pascal(name: string): string {
    let b = Builder.init(cAllocator());
    let upper = true;
    for (const c, i of name) {
        const letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        const digit = c >= '0' && c <= '9';
        if (!letter && !digit) {
            upper = true;
            continue;
        }
        if (letter && upper) b.write(allocCString(`${name[i..i + 1]}`)) catch outOfMemory();
        else if (c >= 'A' && c <= 'Z') {
            const lower: u8[1] = [c + 32];
            b.write(&lower) catch outOfMemory();
        } else {
            b.write(name[i..i + 1]) catch outOfMemory();
        }
        if (letter && upper) {
            // the first letter keeps its case, made upper
            const last = b.bytes.items.len - 1;
            if (b.bytes.items[last] >= 'a' && b.bytes.items[last] <= 'z') b.bytes.items[last] = b.bytes.items[last] - 32;
        }
        upper = false;
    }
    const out = allocCString(`${b.text()}`);
    if (out.len == 0 || (out[0] >= '0' && out[0] <= '9')) return allocCString(`P${out}`);
    return out;
}

/**
 * Takes a top-level name, with a number after it when it is already taken.
 *
 * @param name - The name that the output wants
 * @returns The name, or the first free one of `name2`, `name3`, and so on, which is then taken
 *
 * @remarks
 * The type of each peripheral and the enum of each register go through it,
 * so two peripherals with the same type name still get separate declarations.
 *
 * @since 1.0.0
 */

function unique(name: string): string {
    let candidate = name;
    let n: u32 = 2;
    while (isUsed(candidate)) {
        candidate = allocCString(`${name}${n}`);
        n++;
    }
    add(&used, candidate);
    return candidate;
}

/**
 * Gives the names of the copies that a `dim` element makes.
 *
 * @param node - The index of the element with `dim`
 * @param count - The value of its `dim`
 * @returns The `dimIndex` names, such as `0-7` as eight numbers or `A,B,C` as three letters, else `0` to `count - 1`
 *
 * @remarks
 * A range such as `0-7` must have a number on both sides, and anything else is read as a comma list.
 * Each name in a comma list is trimmed.
 *
 * @since 1.0.0
 */

function dimNames(node: u32, count: u64): Strings {
    let out = strings();
    const index = childText(node, "dimIndex");
    if (index.len > 0) {
        if (const dash = indexOf(index, "-")) {
            const from = number(index[0..dash]);
            const to = number(index[dash + 1..]);
            if (from != null && to != null) {
                for (const k of from..to + 1) add(&out, allocCString(`${k}`));
                return out;
            }
        }
        let start: usize = 0;
        for (const c, i of index) {
            if (c != ',' && i + 1 < index.len) continue;
            add(&out, trim(index[start..c == ',' ? i : i + 1]));
            start = i + 1;
        }
        return out;
    }
    for (const k of 0..count) add(&out, allocCString(`${k}`));
    return out;
}

/**
 * Puts an index into the name of an array element.
 *
 * @param name - The SVD name, with `[%s]` or `%s` where the index goes
 * @param index - The index name
 * @returns The name with the first `[%s]`, or else the first `%s`, replaced by the index
 *
 * @remarks
 * A name without a placeholder comes back unchanged.
 *
 * @since 1.0.0
 */

function substitute(name: string, index: string): string {
    if (const at = indexOf(name, "[%s]")) return allocCString(`${name[0..at]}${index}${name[at + 4..]}`);
    if (const at = indexOf(name, "%s")) return allocCString(`${name[0..at]}${index}${name[at + 2..]}`);
    return name;
}

/**
 * Reads the bits of one field and adds the field to a list.
 *
 * @param node - The index of the `<field>` element
 * @param out - The list that gets the field
 * @param name - The name of the field
 *
 * @remarks
 * The bits come from `bitOffset` and `bitWidth`, from `lsb` and `msb`, or from a `bitRange` of `[msb:lsb]`.
 * A field with a width of 0, or one that reaches past bit 63, is left out.
 *
 * @since 1.0.0
 */

function readField(node: u32, out: *ArrayList<Field>, name: string): void {
    let lsb: u64 = 0;
    let width: u64 = 0;
    const range = childText(node, "bitRange");
    if (childText(node, "bitOffset").len > 0) {
        lsb = numberOr(childText(node, "bitOffset"), 0);
        width = numberOr(childText(node, "bitWidth"), 1);
    } else if (childText(node, "lsb").len > 0) {
        lsb = numberOr(childText(node, "lsb"), 0);
        width = numberOr(childText(node, "msb"), lsb) - lsb + 1;
    } else if (range.len > 2) {
        if (const colon = indexOf(range, ":")) {
            const msb = numberOr(range[1..colon], 0);
            lsb = numberOr(range[colon + 1..range.len - 1], 0);
            width = msb - lsb + 1;
        }
    }
    if (width == 0 || lsb + width > 64) return;
    out.append(Field { name, description: childText(node, "description"), lsb: lsb as u32, width: width as u32 }) catch outOfMemory();
}

/**
 * Reads the fields of a register.
 *
 * @param reg - The index of the `<register>` element
 * @returns The fields, with each field array spelled out into one field per element
 *
 * @remarks
 * Each copy of a field array moves up by `dimIncrement` bits, which defaults to 1.
 *
 * @since 1.0.0
 */

function readFields(reg: u32): ArrayList<Field> {
    let out = ArrayList<Field>.init(cAllocator());
    const fields = child(reg, "fields");
    if (fields == 0) return out;
    for (const f of xml.items[fields].children.items) {
        if (!equal(xml.items[f].name, "field")) continue;
        const name = childText(f, "name");
        const dim = number(childText(f, "dim"));
        if (dim == null) {
            readField(f, &out, name);
            continue;
        }
        const step = numberOr(childText(f, "dimIncrement"), 1);
        const names = dimNames(f, dim);
        for (const index, k of names.items) {
            let one = ArrayList<Field>.init(cAllocator());
            readField(f, &one, substitute(name, index));
            for (const field of one.items) {
                out.append(Field { name: field.name, description: field.description, lsb: field.lsb + (k as u32) * (step as u32), width: field.width }) catch outOfMemory();
            }
        }
    }
    return out;
}

/**
 * Reads the registers under a `<registers>` or `<cluster>` element.
 *
 * @param node - The index of the element
 * @param offset - The offset of the element from the base address of the peripheral
 * @param prefix - The text that goes before each register name, such as the name of a cluster and `_`
 * @param size - The register size in bits for a register that does not give one
 * @param out - The list that gets the registers
 *
 * @remarks
 * Register arrays and cluster arrays are spelled out, with `dimIncrement` bytes between copies, which defaults to 4.
 * A cluster is read again with its own offset and its name as a prefix.
 *
 * @since 1.0.0
 */

function readRegisters(node: u32, offset: u64, prefix: string, size: u32, out: *ArrayList<Reg>): void {
    for (const r of xml.items[node].children.items) {
        const kind = xml.items[r].name;
        if (!equal(kind, "register") && !equal(kind, "cluster")) continue;
        const name = childText(r, "name");
        const at = offset + numberOr(childText(r, "addressOffset"), 0);
        const ownSize = numberOr(childText(r, "size"), size as u64) as u32;
        const dim = number(childText(r, "dim"));
        let names = strings();
        let step: u64 = 0;
        if (const count = dim) {
            names = dimNames(r, count);
            step = numberOr(childText(r, "dimIncrement"), 4);
        } else {
            add(&names, "");
        }
        for (const index, k of names.items) {
            const named = dim == null ? name : substitute(name, index);
            const here = at + (k as u64) * step;
            if (equal(kind, "cluster")) {
                readRegisters(r, here, allocCString(`${prefix}${named}_`), ownSize, out);
                continue;
            }
            out.append(Reg {
                name: allocCString(`${prefix}${named}`), description: childText(r, "description"), offset: here, size: ownSize,
                fields: readFields(r), derivedFrom: attribute(r, "derivedFrom"),
            }) catch outOfMemory();
        }
    }
}

/**
 * The output that {@link translateSvd} builds.
 *
 * @since 1.0.0
 */

let writer: Builder = undefined;

/**
 * Appends a text to the output.
 *
 * @param text - The text to append
 *
 * @remarks
 * A failed append stops the compiler through {@link outOfMemory}, so the writers never handle an error.
 *
 * @since 1.0.0
 */

function put(text: Format): void {
    writer.append(text) catch outOfMemory();
}

/**
 * Writes a description as a one-line doc comment.
 *
 * @param indent - The text that goes before the comment
 * @param description - The description, where an empty one writes nothing
 *
 * @remarks
 * A star and a slash inside the description get a space between them, so they cannot end the comment early.
 *
 * @since 1.0.0
 */

function doc(indent: string, description: string): void {
    if (description.len == 0) return;
    let text = description;
    while (indexOf(text, "*/") != null) {   // can't end the comment early
        const at = indexOf(text, "*/") ?? 0;
        text = allocCString(`${text[0..at]}* /${text[at + 2..]}`);
    }
    put(`${indent}/** ${text} */\n`);
}

/**
 * Writes a number in hexadecimal with `_` between groups of four digits.
 *
 * @param n - The number
 * @returns The text, with at least four digits, such as `0x0200` or `0x4002_0000`
 *
 * @remarks
 * The digits are upper case, and the groups count from the right, so `0x1_0000` has a short first group.
 *
 * @since 1.0.0
 */

function hex(n: u64): string {
    const digits = "0123456789ABCDEF";
    let b = Builder.init(cAllocator());
    let count: u32 = 0;
    let v = n;
    let reversed: u8[24] = undefined;
    while (true) {
        if (count > 0 && count % 4 == 0) {
            reversed[count + count / 4 - 1] = '_';
        }
        reversed[count + count / 4] = digits[(v % 16) as usize];
        count++;
        v /= 16;
        if (v == 0 && count >= 4) break;
    }
    const len = count + (count - 1) / 4;
    b.write("0x") catch outOfMemory();
    let i = len;
    while (i > 0) {
        i--;
        const one: u8[1] = [reversed[i]];
        b.write(&one) catch outOfMemory();
    }
    return allocCString(`${b.text()}`);
}

/**
 * Gives the std/mmio type of a register of a size.
 *
 * @param size - The size of the register in bits
 * @returns `Register16` for 16 bits, `Register8` for 8 bits, and `Register` for any other size
 *
 * @remarks
 * Any size other than 8 or 16 bits, a missing one included, maps to the plain `Register`.
 *
 * @since 1.0.0
 */

function registerType(size: u32): string {
    return size == 16 ? "Register16" : size == 8 ? "Register8" : "Register";
}

/**
 * Writes the field enum of a register.
 *
 * @param enumName - The name of the enum
 * @param reg - The register
 *
 * @remarks
 * Each member holds the lowest bit of its field in bits 0-7 and the width in bits 8-15,
 * so a member such as `.GPIOAEN` checks against its register and folds to a constant mask.
 * When two fields cover the same bits, as alternate functions do, the first one stands and the other becomes a comment.
 * A member name that is already taken gets `_` and its lowest bit after it.
 * A register without fields gets one `VALUE` member that covers the whole register.
 *
 * @since 1.0.0
 */

function writeFieldEnum(enumName: string, reg: readonly *Reg): void {
    doc("", reg.description);
    put(`export enum ${enumName}: u32 {\n`);
    let names = strings();
    let values = ArrayList<u32>.init(cAllocator());
    for (const f of reg.fields.items) {
        const value = f.lsb | (f.width << 8);
        let member = identifier(f.name);
        let clash = false;
        for (const v of values.items) clash = clash || v == value;
        if (clash) {   // two names for the same bits (an alternate function): the first one stands
            put(`    // ${member} is the same bits as another field\n`);
            continue;
        }
        let taken = false;
        for (const n of names.items) taken = taken || equal(n, member);
        if (taken) member = allocCString(`${member}_${f.lsb}`);
        add(&names, member);
        values.append(value) catch outOfMemory();
        doc("    ", f.description);
        put(`    ${member} = ${hex(value as u64)},${f.width > 1 ? allocCString(`   // bits ${f.lsb}-${f.lsb + f.width - 1}`) : allocCString(`   // bit ${f.lsb}`)}\n`);
    }
    if (names.items.len == 0) put(`    VALUE = ${hex((reg.size << 8) as u64)},   // the whole register\n`);
    put("}\n\n");
}

/**
 * Checks whether two register lists have the same layout.
 *
 * @param a - The first list
 * @param b - The second list
 * @returns `true` when the registers match in name, offset, size, and number of fields, in the same order
 *
 * @remarks
 * Peripherals that do not say `derivedFrom` still share a type when their registers pass this check.
 *
 * @since 1.0.0
 */

function sameRegisters(a: readonly *ArrayList<Reg>, b: readonly *ArrayList<Reg>): bool {
    if (a.items.len != b.items.len) return false;
    for (const r, i of a.items) {
        const o = b.items[i];
        if (!equal(r.name, o.name) || r.offset != o.offset || r.size != o.size || r.fields.items.len != o.fields.items.len) return false;
    }
    return true;
}

/**
 * Copies the fields of derived registers and makes the register names unique within the peripheral.
 *
 * @param regs - The registers of one peripheral
 *
 * @remarks
 * A register with `derivedFrom` and no fields of its own takes the fields of the register that it names.
 * Each name becomes a Helix identifier, and a name already used gets `_` and the offset after it.
 *
 * @since 1.0.0
 */

function settle(regs: *ArrayList<Reg>): void {
    for (const r, i of regs.items) {
        if (r.derivedFrom.len == 0 || r.fields.items.len > 0) continue;
        for (const o of regs.items) {
            if (equal(o.name, r.derivedFrom)) regs.items[i].fields = o.fields;
        }
    }
    for (const r, i of regs.items) {
        let name = identifier(r.name);
        for (const o of regs.items[0..i]) {
            if (equal(identifier(o.name), name)) name = allocCString(`${name}_${hex(r.offset)}`);
        }
        regs.items[i].name = name;
    }
}

/**
 * Gives the `cpu` value for helix.jsonc from the SVD name of the core.
 *
 * @param svdName - The `<name>` of the `<cpu>` element, such as `CM4`
 * @returns The Helix name, such as `cortex-m4`, or an empty string for a core that it does not know
 *
 * @remarks
 * The banner of the output only suggests a `"chip"` entry when the core is known,
 * since an unknown core has no Helix target to name.
 *
 * @since 1.0.0
 */

function cpuName(svdName: string): string {
    if (equal(svdName, "CM0")) return "cortex-m0";
    if (equal(svdName, "CM0PLUS") || equal(svdName, "CM0+")) return "cortex-m0plus";
    if (equal(svdName, "CM3")) return "cortex-m3";
    if (equal(svdName, "CM4")) return "cortex-m4";
    if (equal(svdName, "CM7")) return "cortex-m7";
    if (equal(svdName, "CM33")) return "cortex-m33";
    return "";
}

/**
 * Translates the CMSIS-SVD file of a microcontroller into a Helix module.
 *
 * @param text - The SVD text
 * @param source - The file name that the header comment of the module names
 * @param error - Where the reason goes when the text cannot be read
 * @returns The module, or `null` with `error` set when the text is not XML or not an SVD file
 *
 * @remarks
 * Chip vendors such as ST, Nordic, Raspberry Pi, Espressif, and NXP publish an SVD file for each chip.
 * The module declares the registers and interrupts of the chip for use through std/mmio:
 *
 * - **Registers** - each register has an enum of its fields, so `RCC.AHB1ENR.set(.GPIOAEN)` checks
 *   `.GPIOAEN` against that register and folds it to a constant mask.
 * - **Peripherals** - peripherals with the same registers, such as GPIOA to GPIOI, share one struct type,
 *   and each one is an `export const` at its base address.
 * - **Interrupts** - an `Interrupt` enum by number and an `enableInterrupt` function,
 *   with the handler of interrupt n written as `export extern "C" function IRQ<n>_Handler(): void`.
 *
 * Register arrays, field arrays, and clusters are spelled out.
 * The header comment shows a usage example and, for a known Cortex-M core, the `chip` entry for helix.jsonc.
 * SVD files do not give the memory sizes, so the entry leaves them to the datasheet.
 *
 * @example
 * ```hx
 * let error = "";
 * translateSvd(text, "STM32F411.svd", &error); // "// Generated by `helix translate-svd STM32F411.svd` ..."
 * translateSvd("<chip></chip>", "x.svd", &error); // null, with error "not an SVD file: no <device>"
 * ```
 *
 * @see cmdTranslateSvd
 * @since 1.0.0
 */

export function translateSvd(text: string, source: string, error: *string): ?string {
    if (!parseXml(text, error)) return null;
    const device = child(0, "device");
    if (device == 0) {
        *error = "not an SVD file: no <device>";
        return null;
    }
    used = strings();
    const chipName = childText(device, "name");
    const defaultSize = numberOr(childText(device, "size"), 32) as u32;
    let types = ArrayList<PType>.init(cAllocator());
    let periphs = ArrayList<Periph>.init(cAllocator());
    let irqs = ArrayList<Irq>.init(cAllocator());
    const list = child(device, "peripherals");
    if (list == 0) {
        *error = "the SVD file has no <peripherals>";
        return null;
    }

    for (const p of xml.items[list].children.items) {
        if (!equal(xml.items[p].name, "peripheral")) continue;
        const name = childText(p, "name");
        const derived = attribute(p, "derivedFrom");
        let description = childText(p, "description");
        for (const irqNode of xml.items[p].children.items) {
            if (!equal(xml.items[irqNode].name, "interrupt")) continue;
            const value = number(childText(irqNode, "value"));
            if (value == null) continue;
            const irqName = identifier(childText(irqNode, "name"));
            let seen = false;
            for (const q of irqs.items) seen = seen || q.value == value || equal(q.name, irqName);
            if (!seen) irqs.append(Irq { name: irqName, description: childText(irqNode, "description"), value: value }) catch outOfMemory();
        }
        // a derived peripheral without registers of its own shares its base's type
        let typeIndex: usize = 0xFFFF_FFFF;
        if (derived.len > 0 && child(p, "registers") == 0) {
            for (const q of periphs.items) {
                if (equal(q.name, derived)) {
                    typeIndex = q.typeOf;
                    if (description.len == 0) description = q.description;
                }
            }
        }
        if (typeIndex == 0xFFFF_FFFF) {
            let regs = ArrayList<Reg>.init(cAllocator());
            const size = numberOr(childText(p, "size"), defaultSize as u64) as u32;
            const registersNode = child(p, "registers");
            if (registersNode != 0) readRegisters(registersNode, 0, "", size, &regs);
            settle(&regs);
            for (const t, k of types.items) {
                if (sameRegisters(&t.regs, &regs)) typeIndex = k;
            }
            if (typeIndex == 0xFFFF_FFFF) {
                const group = childText(p, "groupName");
                types.append(PType { name: pascal(group.len > 0 ? group : name), description, regs, enums: strings() }) catch outOfMemory();
                typeIndex = types.items.len - 1;
            }
        }
        periphs.append(Periph {
            name: identifier(name), description, base: numberOr(childText(p, "baseAddress"), 0), node: p, typeOf: typeIndex,
        }) catch outOfMemory();
    }

    // names: instances first (they're the SVD's), then types and enums around them
    for (const p of periphs.items) add(&used, p.name);
    add(&used, "Interrupt");
    add(&used, "enableInterrupt");
    for (const t, k of types.items) {
        types.items[k].name = unique(t.name);
        for (const r of t.regs.items) add(&types.items[k].enums, unique(allocCString(`${types.items[k].name}${pascal(r.name)}`)));
    }

    writer = Builder.init(cAllocator());
    const cpu = cpuName(childText(child(device, "cpu"), "name"));
    put(`// Generated by \`helix translate-svd ${source}\`: the ${chipName} (${childText(device, "description")}).\n`);
    // the usage example: this chip's first register with a field, and its first interrupt
    put("//\n");
    let shown = false;
    for (const p of periphs.items) {
        if (shown) break;
        for (const r of types.items[p.typeOf].regs.items) {
            if (shown || r.fields.items.len == 0) continue;
            const f = r.fields.items[0];
            put(`//   ${p.name}.${r.name}.read();  ${p.name}.${r.name}.${f.width == 1 ? "set" : "get"}(.${identifier(f.name)});  ${p.name}.${r.name}.modify(.${identifier(f.name)}, 1);\n`);
            shown = true;
        }
    }
    let first: ?Irq = null;
    for (const q of irqs.items) {
        if (const f = first) {
            if (q.value < f.value) first = q;
        } else {
            first = q;
        }
    }
    if (const q = first) put(`//   enableInterrupt(Interrupt.${q.name});   // then \`export extern "C" function IRQ${q.value}_Handler(): void { ... }\`\n`);
    if (cpu.len > 0) {
        put("//\n");
        put(`// helix.jsonc: "chip": { "cpu": "${cpu}", "fpu": ..., "flash": { "origin": ..., "size": ... }, "ram": { ... } }\n`);
        put("// (the datasheet gives the memory, and whether the FPU is there)\n");
    }
    put("\n");
    let sizes: bool[3] = [false, false, false];
    for (const t of types.items) {
        for (const r of t.regs.items) sizes[r.size == 16 ? 1 : r.size == 8 ? 2 : 0] = true;
    }
    let imports = strings();
    if (sizes[0]) add(&imports, "Register");
    if (sizes[1]) add(&imports, "Register16");
    if (sizes[2]) add(&imports, "Register8");
    add(&imports, "nvicEnable");
    put("import { ");
    for (const name, k of imports.items) put(`${k > 0 ? ", " : ""}${name}`);
    put(" } from \"std/mmio\";\n\n");

    for (const t, k of types.items) {
        let instances = strings();
        for (const p of periphs.items) {
            if (p.typeOf == k) add(&instances, p.name);
        }
        put("/* ---- ");
        for (const name, j of instances.items) put(`${j > 0 ? ", " : ""}${name}`);
        put(` ---- */\n\n`);
        for (const r, j of t.regs.items) writeFieldEnum(t.enums.items[j], &r);
        doc("", t.description);
        put(`export struct ${t.name} {\n`);
        for (const r, j of t.regs.items) {
            doc("    ", r.description);
            put(`    ${r.name}: ${registerType(r.size)}<${t.enums.items[j]}>,   // +${hex(r.offset)}\n`);
        }
        put("}\n\n");
        for (const p of periphs.items) {
            if (p.typeOf != k) continue;
            doc("", p.description);
            put(`export const ${p.name}: ${t.name} = ${t.name} {\n`);
            for (const r, j of t.regs.items) {
                put(`    ${r.name}: ${registerType(r.size)}<${t.enums.items[j]}> { address: ${hex(p.base + r.offset)} },\n`);
            }
            put("};\n\n");
        }
    }

    // interrupts, by number
    let order = ArrayList<Irq>.init(cAllocator());
    for (const q of irqs.items) order.append(q) catch outOfMemory();
    for (const i of 0..order.items.len) {   // few dozen: insertion sort
        let j = i;
        while (j > 0 && order.items[j - 1].value > order.items[j].value) {
            const tmp = order.items[j];
            order.items[j] = order.items[j - 1];
            order.items[j - 1] = tmp;
            j--;
        }
    }
    put("/* ---- interrupts ---- */\n\n");
    put("/** The interrupts, by number. Interrupt n's handler is `IRQ<n>_Handler`, given with each. */\n");
    put("export enum Interrupt: u32 {\n");
    for (const q of order.items) {
        doc("    ", q.description);
        put(`    ${q.name} = ${q.value},   // IRQ${q.value}_Handler\n`);
    }
    if (order.items.len == 0) put("    NONE = 0xFFFF,\n");
    put("}\n\n");
    put("/** Lets an interrupt reach its handler (the NVIC's set-enable register). */\n");
    put("export function enableInterrupt(irq: Interrupt): void {\n");
    put("    nvicEnable(irq as u32);\n");
    put("}\n");
    return allocCString(`${writer.text()}`);
}

/**
 * Runs `helix translate-svd <chip.svd> [-o chip.hx]`.
 *
 * @param args - The arguments after `translate-svd`
 * @returns The exit status, 0 on success and 1 after an error
 *
 * @remarks
 * It takes one SVD file and an optional `-o` path, reads the file, and passes it to {@link translateSvd}.
 * The module goes to the `-o` file, or to standard output without one.
 * A missing input, an unexpected argument, a file that cannot be read or written,
 * and an SVD file that does not translate each print an error and give 1.
 *
 * @example
 * ```hx
 * const args: string[3] = ["STM32F411.svd", "-o", "src/chip.hx"];
 * cmdTranslateSvd(&args); // 0, with src/chip.hx written
 * ```
 *
 * @see translateSvd
 * @since 1.0.0
 */

export function cmdTranslateSvd(args: readonly string[]): u8 {
    let input: ?string = null;
    let output: ?string = null;
    let i: usize = 0;
    while (i < args.len) {
        if (equal(args[i], "-o") && i + 1 < args.len) {
            i++;
            output = args[i];
        } else if (input == null && !startsWith(args[i], "-")) {
            input = args[i];
        } else {
            eprintln(`error: unexpected argument '${args[i]}'`);
            return 1;
        }
        i++;
    }
    if (input == null) {
        eprintln("error: `helix translate-svd` takes an SVD file: `helix translate-svd STM32F411.svd -o src/chip.hx`");
        eprintln("  = hint: chip vendors publish them; the cmsis-svd-data project collects them");
        return 1;
    }
    const path = input ?? "";
    const text = os.readText(path);
    if (text == null) {
        eprintln(`error: cannot read '${path}': ${os.strerror(os.errno())}`);
        return 1;
    }
    let error = "";
    const module = translateSvd(text, os.baseName(path), &error);
    if (module == null) {
        eprintln(`error: ${path}: ${error}`);
        return 1;
    }
    if (const file = output) {
        if (!os.writeText(file, module)) {
            eprintln(`error: cannot write '${file}': ${os.strerror(os.errno())}`);
            return 1;
        }
    } else {
        print(module);
    }
    return 0;
}
