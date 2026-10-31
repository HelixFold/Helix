/**
 * Imports
 */

import { Builder } from "std/fmt";
import { ArrayList } from "std/list";
import { cAllocator } from "std/heap";
import { Version } from "@constants/version.constant";
import { hxJsonFree } from "@components/json.component";
import * as os from "@modules/driver/components/os.component";
import { equal, startsWith, endsWith, indexOf } from "std/text";
import { HxJson } from "@components/structs/json-component.struct";
import { writeDefinition } from "@modules/ide/components/analysis.component";
import { Pos } from "@modules/ide/components/structs/analysis-component.struct";
import { writeProjectActions } from "@modules/ide/components/actions.component";
import { Strings } from "@modules/driver/components/structs/os-component.struct";
import { TokenTypes, TokenModifiers } from "@modules/ide/constants/analysis.constant";
import { setQuiet, defaultOptions } from "@modules/driver/components/compile.component";
import { outOfMemory, buffer, raw, quoted } from "@modules/ide/components/json.component";
import { parse, member, text, itemAt } from "@modules/driver/components/manifest.component";
import { allocCString, toCString, add, strings } from "@modules/driver/components/os.component";
import { JsonString, JsonNumber, JsonBool, JsonObject, JsonArray } from "@constants/json.constant";
import { Diagnostics, Tokens, Symbols, Lenses, Tests, Files } from "@modules/ide/constants/ide.constant";
import { writeHover, offsetOf, buildIndex, writeSummary } from "@modules/ide/components/analysis.component";
import { applyChip, parseTarget, compileFront, setOverlay } from "@modules/driver/components/compile.component";
import { Sections, AskSummary, AskDefinition, AskHover, None, Debounce } from "@modules/ide/constants/ide.constant";

/**
 * The functions of the host layer in `host.c` that the server reads, writes, forks, and waits with.
 *
 * @since 1.0.0
 */

extern "C" function hx_os_can_fork(): i32;
extern "C" function hx_os_fork(readEnd: *i32, writeEnd: *i32): i64;
extern "C" function hx_os_exit_now(code: i32): noreturn;
extern "C" function hx_os_read(fd: i32, buf: u8[*], len: usize): i64;
extern "C" function hx_os_write(fd: i32, bytes: readonly u8[*], len: usize): i64;
extern "C" function hx_os_close(fd: i32): i32;
extern "C" function hx_os_open_append(path: readonly u8[*]): i32;
extern "C" function hx_os_wait_stdin(timeout: i32): i32;
extern "C" function hx_os_binary_stdio(): void;

/**
 * The bytes read from stdin that no whole message has taken yet.
 *
 * @since 1.0.0
 */

let inbox: ArrayList<u8> = undefined;

/**
 * The file that `HELIX_LSP_LOG` names, opened for appending, or -1 when the variable is not set.
 *
 * @since 1.0.0
 */

let logFd: i32 = -1;

/**
 * Appends one message to the log file, when there is one.
 *
 * @param direction - `->` for a message from the editor, `<-` for one to it
 * @param body - The JSON of the message
 *
 * @remarks
 * Each message takes one line, the direction, a space, and the body.
 * A failed write to the log is ignored, so the log never stops the server.
 *
 * @since 1.0.0
 */

function logLine(direction: string, body: string): void {
    if (logFd < 0) return;
    void writeAll(logFd, allocCString(`${direction} ${body}\n`));
}

/**
 * Writes all of a byte slice to a file descriptor.
 *
 * @param fd - The file descriptor to write to
 * @param bytes - The bytes to write
 * @returns `true` once every byte is written, `false` when a write fails
 *
 * @remarks
 * A single write may take only part of the bytes, so the function loops until the whole slice is out.
 * A write that returns 0 counts as a failure, which keeps a closed pipe from looping forever.
 *
 * @since 1.0.0
 */

function writeAll(fd: i32, bytes: readonly u8[]): bool {
    let done: usize = 0;
    while (done < bytes.len) {
        let n: i64 = 0;
        unsafe {
            n = hx_os_write(fd, &bytes.ptr[done], bytes.len - done);
        }
        if (n <= 0) return false;
        done += n as usize;
    }
    return true;
}

/**
 * Sends one message to the editor with its `Content-Length` header.
 *
 * @param body - The JSON of the message
 *
 * @remarks
 * A failed write means that the editor is gone, so the server exits with status 1.
 *
 * @since 1.0.0
 */

function send(body: string): void {
    logLine("<-", body);
    if (!writeAll(1, allocCString(`Content-Length: ${body.len}\r\n\r\n`)) || !writeAll(1, body)) hx_os_exit_now(1);   // the editor is gone
}

/**
 * Removes bytes from the front of the inbox.
 *
 * @param count - The number of bytes to remove
 *
 * @remarks
 * The rest of the inbox moves down in place, so the buffer keeps its storage and only its length shrinks.
 * The count must not exceed the length of the inbox.
 *
 * @since 1.0.0
 */

function removeFront(count: usize): void {
    const rest = inbox.items.len - count;
    for (const i of 0..rest) inbox.items[i] = inbox.items[count + i];
    inbox.items = inbox.items[0..rest];
}

/**
 * Takes one whole message out of the inbox.
 *
 * @returns The body of the message, or `null` until one has fully arrived
 *
 * @remarks
 * The headers end at the first blank line, and `Content-Length:` among them gives the size of the body.
 * A header block without a length is dropped, and the call then gives `null`.
 *
 * @since 1.0.0
 */

function takeMessage(): ?string {
    const have = inbox.items;
    const found = indexOf(have, "\r\n\r\n");
    if (found == null) return null;
    const headerEnd: usize = found;
    const headers = have[0..headerEnd];
    let length: usize = 0;
    let known = false;
    let start: usize = 0;
    for (const ch, i of headers) {   // `Content-Length: 123`, among other headers
        if (ch != '\n' && i + 1 < headers.len) continue;
        const line = headers[start..ch == '\n' ? i : i + 1];
        start = i + 1;
        const prefix = "Content-Length:";
        if (line.len > prefix.len && equal(line[0..prefix.len], prefix)) {
            known = true;
            for (const d of line[prefix.len..]) {
                if (d >= '0' && d <= '9') length = length * 10 + (d - '0') as usize;
            }
        }
    }
    if (!known) {   // a header block without a length: drop it
        removeFront(headerEnd + 4);
        return null;
    }
    const bodyStart = headerEnd + 4;
    if (have.len < bodyStart + length) return null;
    const body = allocCString(`${have[bodyStart..bodyStart + length]}`);
    removeFront(bodyStart + length);
    logLine("->", body);
    return body;
}

/**
 * Reads what is waiting on stdin into the inbox.
 *
 * @returns `false` at the end of input or on a read error, otherwise `true`
 *
 * @remarks
 * One call reads at most 64 KiB, so a long message takes several calls to arrive.
 * The call blocks until stdin has bytes, so the server first waits with `hx_os_wait_stdin` when it has other work.
 *
 * @since 1.0.0
 */

function readInput(): bool {
    let buf: u8[65536] = undefined;
    const n = hx_os_read(0, &buf, buf.len);
    if (n <= 0) return false;
    for (const b of buf[0..n as usize]) inbox.append(b) catch outOfMemory();
    return true;
}

/**
 * The URIs of the open documents, as the editor names them.
 *
 * @remarks
 * The same index picks a document in every per-document list of this file.
 *
 * @since 1.0.0
 */

let docUris: Strings = undefined;

/**
 * The real paths of the open documents, as the compiler names files.
 *
 * @since 1.0.0
 */

let docPaths: Strings = undefined;

/**
 * The texts of the open documents, as the editor last sent them.
 *
 * @since 1.0.0
 */

let docTexts: Strings = undefined;

/**
 * Per document, the URIs of the other files that its last check reported diagnostics for, one per line.
 *
 * @since 1.0.0
 */

let reportedFor: Strings = undefined;

/**
 * The time of the last change in seconds, or 0 when nothing waits for a refresh.
 *
 * @since 1.0.0
 */

let changedAt: f64 = 0;

/**
 * The summaries of the open documents, {@link Sections} entries per document.
 *
 * @since 1.0.0
 */

let sections: Strings = undefined;

/**
 * Per document, whether the diagnostics of its current summary went out to the editor.
 *
 * @since 1.0.0
 */

let published: ArrayList<bool> = undefined;

/**
 * Turns a `file://` URI into a real path.
 *
 * @param uri - The URI, or a plain path
 * @returns The percent-decoded path, resolved to its real path when the file exists
 *
 * @remarks
 * The editor percent-encodes the path, and the compiler names files by their real path,
 * so this conversion makes both sides agree on one name.
 * A `%` that two hex digits do not follow stays as it is.
 * A path that does not resolve, such as a file not yet saved, comes back decoded but unresolved.
 *
 * @since 1.0.0
 */

function pathOf(uri: string): string {
    const rest = startsWith(uri, "file://") ? uri[7..] : uri;
    let b = buffer();
    let i: usize = 0;
    while (i < rest.len) {
        if (rest[i] == '%' && i + 2 < rest.len && hexDigit(rest[i + 1]) >= 0 && hexDigit(rest[i + 2]) >= 0) {
            const one: u8[1] = [(hexDigit(rest[i + 1]) * 16 + hexDigit(rest[i + 2])) as u8];
            b.write(&one) catch outOfMemory();
            i += 3;
            continue;
        }
        raw(&b, rest[i..i + 1]);
        i++;
    }
    const path = allocCString(`${b.text()}`);
    return os.realPath(path) ?? path;
}

/**
 * Reads one hex digit.
 *
 * @param ch - The character, in either case
 * @returns The value of the digit, or -1 when the character is not one
 *
 * @remarks
 * The function returns -1 rather than an error,
 * so {@link pathOf} can test both digits of an escape before it decodes either.
 *
 * @since 1.0.0
 */

function hexDigit(ch: u8): i32 {
    if (ch >= '0' && ch <= '9') return (ch - '0') as i32;
    if (ch >= 'a' && ch <= 'f') return (ch - 'a') as i32 + 10;
    if (ch >= 'A' && ch <= 'F') return (ch - 'A') as i32 + 10;
    return -1;
}

/**
 * Finds an open document by its URI.
 *
 * @param uri - The URI to look for
 * @returns The index of the document, or `null` when it is not open
 *
 * @remarks
 * The search is linear and compares the URIs as text,
 * so two spellings of the same path count as different documents.
 *
 * @since 1.0.0
 */

function findDoc(uri: string): ?usize {
    for (const u, i of docUris.items) {
        if (equal(u, uri)) return i;
    }
    return null;
}

/**
 * Adds a document with a stale summary.
 *
 * @param uri - The URI of the document
 * @param content - The text of the document
 * @returns The index of the new document
 *
 * @remarks
 * Every per-document list grows by one entry at the same index, with every section of the summary empty.
 * An empty files section makes the document stale, so the next {@link summarize} compiles it.
 *
 * @since 1.0.0
 */

function addDoc(uri: string, content: string): usize {
    add(&docUris, uri);
    add(&docPaths, pathOf(uri));
    add(&docTexts, content);
    add(&reportedFor, "");
    for (const _ of 0..Sections) add(&sections, "");
    published.append(false) catch outOfMemory();
    return docUris.items.len - 1;
}

/**
 * Removes a document by moving the last document into its place.
 *
 * @param i - The index of the document to remove
 *
 * @remarks
 * The order of the remaining documents is not kept, so an index saved before the call may point elsewhere after it.
 *
 * @since 1.0.0
 */

function removeDoc(i: usize): void {
    const last = docUris.items.len - 1;
    docUris.items[i] = docUris.items[last];
    docPaths.items[i] = docPaths.items[last];
    docTexts.items[i] = docTexts.items[last];
    reportedFor.items[i] = reportedFor.items[last];
    for (const k of 0..Sections) sections.items[i * Sections + k] = sections.items[last * Sections + k];
    published.items[i] = published.items[last];
    docUris.items = docUris.items[0..last];
    docPaths.items = docPaths.items[0..last];
    docTexts.items = docTexts.items[0..last];
    reportedFor.items = reportedFor.items[0..last];
    sections.items = sections.items[0..last * Sections];
    published.items = published.items[0..last];
}

/**
 * Reads one section of the summary of a document.
 *
 * @param doc - The index of the document
 * @param which - The section, such as {@link Tokens}
 * @returns The text of the section
 *
 * @remarks
 * The sections of all documents share one flat list, {@link Sections} entries per document.
 * The read does no bounds check.
 *
 * @since 1.0.0
 */

function section(doc: usize, which: usize): string {
    return sections.items[doc * Sections + which];
}

/**
 * Checks whether the summary of a document is current.
 *
 * @param doc - The index of the document
 * @returns `true` while the files section is not empty
 *
 * @remarks
 * A summary is stale exactly when its files section is empty, so clearing that one section marks it stale.
 * {@link summarize} always leaves the section non-empty, even after a failed compile.
 *
 * @since 1.0.0
 */

function fresh(doc: usize): bool {
    return section(doc, Files).len > 0;
}

/**
 * Splits a text into its non-empty lines.
 *
 * @param list - The text, with lines that end in `\n`
 * @returns The lines, without their line breaks
 *
 * @remarks
 * A last line without a trailing `\n` still counts.
 * Empty lines are skipped, so an empty text gives no lines.
 *
 * @since 1.0.0
 */

function lines(list: string): Strings {
    let out = strings();
    let start: usize = 0;
    for (const ch, i of list) {
        if (ch != '\n') continue;
        if (i > start) add(&out, list[start..i]);
        start = i + 1;
    }
    if (start < list.len) add(&out, list[start..]);
    return out;
}

/**
 * Checks whether a text holds a line.
 *
 * @param list - The text, one entry per line
 * @param line - The line to look for
 * @returns `true` when one of the lines equals it exactly
 *
 * @remarks
 * The function splits the whole text each time, which suits the short file lists that it searches.
 *
 * @since 1.0.0
 */

function containsLine(list: string, line: string): bool {
    for (const l of lines(list).items) {
        if (equal(l, line)) return true;
    }
    return false;
}

/**
 * Marks every summary that read a file as stale.
 *
 * @param path - The real path of the file that changed, opened, or was saved
 *
 * @remarks
 * It also restarts the {@link Debounce} wait before the next refresh.
 *
 * @since 1.0.0
 */

function changed(path: string): void {
    for (const doc of 0..docUris.items.len) {
        if (equal(docPaths.items[doc], path) || containsLine(section(doc, Files), path)) {
            sections.items[doc * Sections + Files] = "";
        }
    }
    changedAt = os.secondsNow();
}

/**
 * Answers a question about a document by compiling it in a child process.
 *
 * @param kind - The question, such as {@link AskSummary}
 * @param doc - The index of the document
 * @param pos - The cursor, for a definition or a hover
 * @returns The answer, or `null` when the fork or the compiler failed
 *
 * @remarks
 * A forked child starts with the state of the server, compiles, and writes the answer into a pipe.
 * The global state of the compiler is then fresh every time, and a crash costs one answer, not the server.
 * The child's stdout is stderr, so anything the compiler prints goes to the log of the editor.
 * Where the host cannot fork, or `HELIX_LSP_NO_FORK` is set, {@link askStarted} answers instead.
 *
 * @since 1.0.0
 */

function ask(kind: u32, doc: usize, pos: Pos): ?string {
    if (hx_os_can_fork() == 0 || os.getenvSet("HELIX_LSP_NO_FORK") != null) return askStarted(kind, doc, pos);
    let readEnd: i32 = -1;
    let writeEnd: i32 = -1;
    const child = hx_os_fork(&readEnd, &writeEnd);
    if (child < 0) return null;
    if (child == 0) {   // stdout is now stderr: anything the compiler prints goes to the editor's log
        let b = buffer();
        answer(&b, kind, doc, pos);
        hx_os_exit_now(writeAll(writeEnd, b.text()) ? 0 : 1);
    }
    let got = buffer();
    let buf: u8[65536] = undefined;
    while (true) {
        const n = hx_os_read(readEnd, &buf, buf.len);
        if (n <= 0) break;
        got.write(buf[0..n as usize]) catch outOfMemory();
    }
    void hx_os_close(readEnd);
    if (os.waitFor(child) != 0) {
        eprintln(`helix lsp: the compiler failed on ${docPaths.items[doc]}`);
        return null;
    }
    return allocCString(`${got.text()}`);
}

/**
 * Answers a question about a document by starting `helix lsp --answer <file>` where there is no fork.
 *
 * @param kind - The question, such as {@link AskSummary}
 * @param doc - The index of the document
 * @param pos - The cursor, for a definition or a hover
 * @returns The answer, or `null` when the file could not be written or the child failed
 *
 * @remarks
 * The question and the path and text of every open document go into a question file in the temp folder,
 * as fields that end with NUL.
 * The child's stdout goes into an answer file, and both files are removed afterwards.
 * Windows always takes this path, and `HELIX_LSP_NO_FORK=1` forces it everywhere so that it is tested.
 *
 * @since 1.0.0
 */

function askStarted(kind: u32, doc: usize, pos: Pos): ?string {
    const base = allocCString(`${os.tempDir()}/helix-lsp-${os.pid()}`);
    const question = allocCString(`${base}.question`);
    const reply = allocCString(`${base}.answer`);
    let b = buffer();
    raw(&b, allocCString(`${kind}\x00${doc}\x00${pos.line}\x00${pos.character}\x00${docPaths.items.len}\x00`));
    for (const path, i of docPaths.items) raw(&b, allocCString(`${path}\x00${docTexts.items[i].len}\x00${docTexts.items[i]}`));
    if (!os.writeText(question, b.text())) return null;
    let args = strings();
    add(&args, os.compilerPath() ?? "helix");
    add(&args, "lsp");
    add(&args, "--answer");
    add(&args, question);
    let code: i64 = -1;
    if (const child = os.spawn(args.items, false, reply)) code = os.waitFor(child);
    const got = os.readText(reply);
    os.unlink(question);
    os.unlink(reply);
    if (code != 0 || got == null) {
        eprintln(`helix lsp: the compiler failed on ${docPaths.items[doc]}`);
        return null;
    }
    return got;
}

/**
 * Reads the next field of a question file.
 *
 * @param data - The whole question file
 * @param at - The read position, which moves past the field and its NUL
 * @returns The bytes before the next NUL, or up to the end
 *
 * @remarks
 * A missing NUL ends the field at the end of the data, so a truncated file never reads past the end.
 * The result is a slice of the data, not a copy.
 *
 * @since 1.0.0
 */

function field(data: string, at: *usize): string {
    const start = *at;
    let end = start;
    while (end < data.len && data[end] != 0) end++;
    *at = end < data.len ? end + 1 : end;
    return data[start..end];
}

/**
 * Reads a decimal number without checking its digits.
 *
 * @param digits - The digits
 * @returns The number
 *
 * @remarks
 * The function trusts its input, since the server wrote the question file itself.
 * It uses plain arithmetic, so it suits only short runs of digits that the server wrote.
 *
 * @since 1.0.0
 */

function decimal(digits: string): u32 {
    let n: u32 = 0;
    for (const d of digits) n = n * 10 + (d - '0') as u32;
    return n;
}

/**
 * Answers the question in a file, as the child that {@link askStarted} starts.
 *
 * @param path - The question file
 * @returns 0 after writing the answer to stdout, or 1 when the file cannot be read or the write fails
 *
 * @remarks
 * The file holds the kind, the document, the line, and the character, then the count of documents.
 * Each document follows as its path and its length, with the text right after,
 * so the length, not a NUL, ends the text.
 * The child then answers through {@link answer}, as the forked child does.
 *
 * @since 1.0.0
 */

function answerFile(path: string): u8 {
    const data = os.readText(path);
    if (data == null) return 1;
    const all: string = data;
    let at: usize = 0;
    const kind = decimal(field(all, &at));
    const doc = decimal(field(all, &at)) as usize;
    const line = decimal(field(all, &at));
    const character = decimal(field(all, &at));
    const count = decimal(field(all, &at));
    for (const _ of 0..count) {
        add(&docPaths, field(all, &at));
        const size = decimal(field(all, &at)) as usize;
        add(&docTexts, all[at..at + size]);
        at += size;
    }
    let b = buffer();
    answer(&b, kind, doc, Pos { line: line, character: character });
    return writeAll(1, b.text()) ? 0 : 1;
}

/**
 * Compiles a document in the child and writes the answer to its question.
 *
 * @param b - The buffer to write the answer into
 * @param kind - The question, such as {@link AskSummary}
 * @param doc - The index of the document
 * @param pos - The cursor, for a definition or a hover
 *
 * @remarks
 * Every open document overlays its file on disk, so the compile sees unsaved text.
 * A firmware package's `chip` sets the target, so `std/target` matches what `helix build` builds,
 * and a spec compiles with its tests for this machine.
 * When the file cannot be read at all, the answer is an empty summary or `null`.
 *
 * @since 1.0.0
 */

function answer(b: *Builder, kind: u32, doc: usize, pos: Pos): void {
    setQuiet(true);
    for (const path, i of docPaths.items) setOverlay(path, docTexts.items[i]);
    const path = docPaths.items[doc];
    // a firmware package's `chip` is the target, so `std/target` matches what `helix build` builds
    let options = defaultOptions();
    options.file = path;
    options.test = endsWith(path, ".spec.hx");   // specs run on this machine
    void applyChip(&options);
    let ok = false;
    const c = compileFront(path, true, endsWith(path, ".spec.hx"), options.target != null ? parseTarget(options.target) : null, &ok);
    if (c.modules.items.len == 0) {   // the file couldn't be read at all
        if (kind == AskSummary) raw(b, allocCString(`[]\x00{"data":[]}\x00[]\x00[]\x00{"children":[]}\x00${path}\n`));
        else raw(b, "null");
        return;
    }
    buildIndex(c);
    if (kind == AskSummary) writeSummary(b, c, path);
    else if (kind == AskDefinition) writeDefinition(b, c, offsetOf(c, 0, pos));
    else writeHover(b, c, offsetOf(c, 0, pos));
}

/**
 * Makes the summary of a document current with one compile, split into its sections.
 *
 * @param doc - The index of the document
 *
 * @remarks
 * A section that the compile did not give falls back to an empty answer.
 * A failed compile counts as current too, with the document itself as its only file,
 * so the server does not retry it until something changes.
 * The new diagnostics are marked as not yet published.
 *
 * @since 1.0.0
 */

function summarize(doc: usize): void {
    if (fresh(doc)) return;
    const got = ask(AskSummary, doc, Pos { line: 0, character: 0 }) ?? "";
    let parts = strings();
    let start: usize = 0;
    for (const c, i of got) {
        if (c != 0) continue;
        add(&parts, got[start..i]);
        start = i + 1;
    }
    add(&parts, got[start..]);
    const fallbacks: string[5] = ["[]", "{\"data\":[]}", "[]", "[]", "{\"children\":[]}"];
    for (const k of 0..Files) sections.items[doc * Sections + k] = parts.items.len == Sections ? parts.items[k] : fallbacks[k];
    // a failed compile is fresh too (its file list is itself), so it isn't retried until something changes
    sections.items[doc * Sections + Files] = parts.items.len == Sections && parts.items[Files].len > 0 ? parts.items[Files] : allocCString(`${docPaths.items[doc]}\n`);
    published.items[doc] = false;
}

/**
 * Sends the diagnostics of one file to the editor.
 *
 * @param uri - The URI of the file
 * @param diagnostics - The diagnostics, as a JSON array
 *
 * @remarks
 * The function sends a `textDocument/publishDiagnostics` notification,
 * so the editor replaces what it showed for that URI.
 * The diagnostics go in as JSON text without parsing, so the caller passes a valid array.
 *
 * @since 1.0.0
 */

function publish(uri: string, diagnostics: string): void {
    let b = buffer();
    raw(&b, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":");
    quoted(&b, uri);
    raw(&b, ",\"diagnostics\":");
    raw(&b, diagnostics);
    raw(&b, "}}");
    send(b.text());
}

/**
 * Publishes the diagnostics from the summary of a document.
 *
 * @param doc - The index of the document
 *
 * @remarks
 * It sends the document's own diagnostics, an empty list when there are none,
 * and those of each imported file that is not open, since an open file's own check speaks for it.
 * A file that the previous check reported and this one does not gets an empty list, which clears it.
 *
 * @since 1.0.0
 */

function publishFor(doc: usize): void {
    published.items[doc] = true;
    const json = section(doc, Diagnostics);
    let parsed = parse(json);
    defer hxJsonFree(&parsed.json);
    if (!parsed.ok || parsed.json.kind != JsonArray) return;
    const own = docUris.items[doc];
    let reported = "";
    let ownSent = false;
    for (const i of 0..parsed.json.count) {
        const entry = itemAt(&parsed.json, i);
        const uriValue = member(entry, "uri");
        const diagnostics = member(entry, "diagnostics");
        if (uriValue == null || diagnostics == null) continue;
        const uri = text(uriValue);
        const body = json[diagnostics.start..diagnostics.end];
        if (equal(uri, own)) {
            publish(uri, body);
            ownSent = true;
        } else if (findDoc(uri) == null) {
            publish(uri, body);
            reported = allocCString(`${reported}${uri}\n`);
        }
    }
    if (!ownSent) publish(own, "[]");
    for (const before of lines(reportedFor.items[doc]).items) {
        if (!containsLine(reported, before) && findDoc(before) == null) publish(before, "[]");
    }
    reportedFor.items[doc] = reported;
}

/**
 * Checks whether a message is waiting, so that a refresh steps aside for it.
 *
 * @returns `true` when the inbox holds a header block or stdin has bytes to read
 *
 * @remarks
 * The check does not block, so {@link refresh} can call it between documents.
 * A whole message may already sit in the inbox, so the inbox counts before stdin does.
 *
 * @since 1.0.0
 */

function inputWaiting(): bool {
    if (takeable()) return true;
    return hx_os_wait_stdin(0) > 0;
}

/**
 * Checks whether the inbox holds the end of a header block.
 *
 * @returns `true` when the inbox holds a blank line after headers
 *
 * @remarks
 * The test only finds the end of the headers, so the body may still be on its way.
 * {@link takeMessage} decides whether the whole message is there.
 *
 * @since 1.0.0
 */

function takeable(): bool {
    return indexOf(inbox.items, "\r\n\r\n") != null;
}

/**
 * Rebuilds the stale summaries and publishes what is new, one document at a time.
 *
 * @remarks
 * It stops early when input is waiting and leaves {@link changedAt} set,
 * so the next quiet moment carries on where it stopped.
 * Otherwise it clears {@link changedAt} at the end.
 *
 * @since 1.0.0
 */

function refresh(): void {
    for (const doc of 0..docUris.items.len) {
        if (fresh(doc) && published.items[doc]) continue;
        if (inputWaiting()) return;   // `changedAt` stays set: the next quiet moment continues
        summarize(doc);
        publishFor(doc);
    }
    changedAt = 0;
}

/**
 * Sends the result of a request.
 *
 * @param id - The id of the request, as its JSON text
 * @param result - The result, as JSON
 *
 * @remarks
 * The id goes in as its JSON text, so a number id stays a number and a string id keeps its quotes.
 * The result also goes in as JSON text without escaping.
 *
 * @since 1.0.0
 */

function respond(id: string, result: string): void {
    send(allocCString(`{"jsonrpc":"2.0","id":${id},"result":${result}}`));
}

/**
 * Sends an error for a request.
 *
 * @param id - The id of the request, as its JSON text
 * @param code - The JSON-RPC error code
 * @param message - The message of the error
 *
 * @remarks
 * The message goes through `quoted`, so any text gives valid JSON.
 * The server uses code -32601 for a method that it does not handle.
 *
 * @since 1.0.0
 */

function respondError(id: string, code: i32, message: string): void {
    let b = buffer();
    raw(&b, allocCString(`{"jsonrpc":"2.0","id":${id},"error":{"code":${code},"message":`));
    quoted(&b, message);
    raw(&b, "}}");
    send(b.text());
}

/**
 * Whether the client starts `helix.action` commands, which code lenses need.
 *
 * @remarks
 * Only a client that sends `"initializationOptions": { "actions": true }` gets the lenses.
 *
 * @since 1.0.0
 */

let actions = false;

/**
 * Builds the result of `initialize`.
 *
 * @returns The capabilities of the server and its name and version, as JSON
 *
 * @remarks
 * Positions count UTF-16 code units, and every change sends the whole text.
 * The semantic tokens legend comes from {@link TokenTypes} and {@link TokenModifiers}.
 * The experimental capabilities announce the `helix/tests` and `helix/projectActions` requests.
 *
 * @since 1.0.0
 */

function capabilities(): string {
    const lenses = actions ? ",\"codeLensProvider\":{\"resolveProvider\":false}" : "";
    return allocCString(`{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":1,"save":{"includeText":false}},"semanticTokensProvider":{"legend":{"tokenTypes":${TokenTypes},"tokenModifiers":${TokenModifiers}},"full":true},"documentSymbolProvider":true,"definitionProvider":true,"hoverProvider":true${lenses},"experimental":{"helixTests":true,"helixProjectActions":true}},"serverInfo":{"name":"helix","version":"${Version}"}}`);
}

/**
 * Reads the URI of the document that a message is about.
 *
 * @param params - The params of the message
 * @returns The text of `params.textDocument.uri`, or an empty string when it is missing or not a string
 *
 * @remarks
 * Most requests and notifications carry the document as `params.textDocument.uri`,
 * so this reads it once for all of them.
 * An empty result never matches an open document, so a malformed message finds nothing.
 *
 * @since 1.0.0
 */

function documentUri(params: ?readonly *HxJson): string {
    if (const doc = member(params, "textDocument")) {
        if (const uri = member(doc, "uri")) {
            if (uri.kind == JsonString) return text(uri);
        }
    }
    return "";
}

/**
 * Reads a JSON value as a position number.
 *
 * @param v - The value, which may be missing
 * @returns The number, or 0 when it is missing, not a number, or negative
 *
 * @remarks
 * Line and character must be non-negative integers in LSP,
 * so a bad value falls back to 0 rather than failing the request.
 * A fraction is cut toward zero.
 *
 * @since 1.0.0
 */

function number(v: ?readonly *HxJson): u32 {
    if (const n = v) {
        if (n.kind == JsonNumber && n.number >= 0) return n.number as u32;
    }
    return 0;
}

/**
 * Finds the section of a summary that answers a request.
 *
 * @param method - The method of the request
 * @returns The section, or {@link None} when the request needs a cursor or the server does not handle it
 *
 * @remarks
 * Definition and hover are not in the summary, so they give {@link None} here,
 * and the caller tells them apart from an unknown method.
 *
 * @since 1.0.0
 */

function summarySection(method: string): usize {
    if (equal(method, "textDocument/semanticTokens/full")) return Tokens;
    if (equal(method, "textDocument/documentSymbol")) return Symbols;
    if (equal(method, "textDocument/codeLens")) return Lenses;
    if (equal(method, "helix/tests")) return Tests;
    return None;
}

/**
 * Whether the editor sent `shutdown`, which makes the later `exit` a clean one.
 *
 * @since 1.0.0
 */

let shutdownAsked = false;

/**
 * Handles one message from the editor.
 *
 * @param body - The JSON of the message
 * @returns `false` when the server should stop, which only `exit` asks
 *
 * @remarks
 * Notifications about open, changed, saved, and closed documents update the documents and mark summaries stale.
 * Closing a document clears its diagnostics and those of the files it reported.
 * `helix/projectActions` answers with the actions of the project, and other requests go to {@link answerRequest}.
 * A message that is not a JSON object is ignored.
 *
 * @since 1.0.0
 */

function handle(body: string): bool {
    let parsed = parse(body);
    defer hxJsonFree(&parsed.json);
    if (!parsed.ok || parsed.json.kind != JsonObject) return true;
    const msg = &parsed.json;
    let method = "";
    if (const m = member(msg, "method")) {
        if (m.kind == JsonString) method = text(m);
    }
    let id = "";
    if (const i = member(msg, "id")) id = allocCString(`${body[i.start..i.end]}`);
    const params = member(msg, "params");

    if (equal(method, "initialize")) {
        if (const options = member(params, "initializationOptions")) {
            if (const a = member(options, "actions")) actions = a.kind == JsonBool && a.boolean;
        }
        respond(id, capabilities());
    } else if (equal(method, "shutdown")) {
        shutdownAsked = true;
        respond(id, "null");
    } else if (equal(method, "exit")) {
        return false;
    } else if (equal(method, "textDocument/didOpen")) {
        if (const doc = member(params, "textDocument")) {
            let content = "";
            if (const t = member(doc, "text")) content = text(t);
            const uri = documentUri(params);
            if (const i = findDoc(uri)) docTexts.items[i] = content;
            else void addDoc(uri, content);
            changed(pathOf(uri));
        }
    } else if (equal(method, "textDocument/didChange")) {
        if (const changes = member(params, "contentChanges")) {
            if (changes.kind == JsonArray && changes.count > 0) {
                if (const t = member(itemAt(changes, changes.count - 1), "text")) {
                    if (const i = findDoc(documentUri(params))) {
                        docTexts.items[i] = text(t);
                        changed(docPaths.items[i]);
                    }
                }
            }
        }
    } else if (equal(method, "textDocument/didSave")) {
        changed(pathOf(documentUri(params)));   // files that aren't open read it from disk
    } else if (equal(method, "textDocument/didClose")) {
        if (const i = findDoc(documentUri(params))) {
            for (const other of lines(reportedFor.items[i]).items) publish(other, "[]");
            publish(docUris.items[i], "[]");
            removeDoc(i);
        }
    } else if (equal(method, "helix/projectActions")) {
        let b = buffer();
        writeProjectActions(&b, pathOf(documentUri(params)));
        respond(id, b.text());
    } else if (id.len > 0) {
        answerRequest(id, method, params);
    }
    return true;
}

/**
 * Answers a request about one file, from its summary or from a compile at the cursor.
 *
 * @param id - The id of the request, as its JSON text
 * @param method - The method of the request
 * @param params - The params of the request
 *
 * @remarks
 * A file that is not open is read from disk and dropped again after the answer.
 * Definition and hover depend on the cursor, so they compile on demand.
 * A file that cannot be read gets an empty answer, and a method that the server does not handle gets error -32601.
 *
 * @since 1.0.0
 */

function answerRequest(id: string, method: string, params: ?readonly *HxJson): void {
    const which = summarySection(method);
    const cursor = equal(method, "textDocument/definition") || equal(method, "textDocument/hover");
    if (which == None && !cursor) {
        respondError(id, -32601, allocCString(`helix lsp doesn't handle ${method}`));
        return;
    }
    const uri = documentUri(params);
    let doc: usize = 0;
    let borrowed = false;
    if (const open = findDoc(uri)) {
        doc = open;
    } else {
        const content = os.readText(pathOf(uri));
        if (content == null) {
            respond(id, which == Tokens ? "{\"data\":[]}" : which == Tests ? "{\"children\":[]}" : which == None ? "null" : "[]");
            return;
        }
        doc = addDoc(uri, content);
        borrowed = true;
    }
    if (which != None) {
        summarize(doc);
        respond(id, section(doc, which));
    } else {
        let pos = Pos { line: 0, character: 0 };
        if (const p = member(params, "position")) pos = Pos { line: number(member(p, "line")), character: number(member(p, "character")) };
        respond(id, ask(equal(method, "textDocument/definition") ? AskDefinition : AskHover, doc, pos) ?? "null");
    }
    if (borrowed) removeDoc(doc);
}

/**
 * Runs `helix lsp`, the language server that every editor uses.
 *
 * @param answerFrom - The question file of `helix lsp --answer <file>`, or `null` to serve
 * @returns 0 after `shutdown` and `exit`, 1 when stdin closes or `exit` comes without a `shutdown`,
 *   or the status of the answer
 *
 * @remarks
 * The server speaks the Language Server Protocol on stdin and stdout:
 * `Content-Length: N` headers, then N bytes of JSON-RPC.
 * It adds two requests of its own, `helix/tests` for the test tree of a file
 * and `helix/projectActions` for the build, run, and test actions.
 *
 * The open files are kept in memory, and each question is answered by compiling in a child process.
 * One compile per open file gives its summary, which holds the diagnostics, semantic tokens, outline, lenses,
 * test tree, and the files it read.
 * The summary is kept until one of those files changes.
 * After a change, the server waits for {@link Debounce} seconds of quiet,
 * then rebuilds the stale summaries one file at a time, only while no request waits, and publishes their diagnostics.
 *
 * `HELIX_LSP_LOG=<file>` appends every message in and out to that file, for debugging a client.
 *
 * @example
 * ```hx
 * cmdLsp(null); // serves until the editor says exit, then 0
 * ```
 *
 * @see ask
 * @since 1.0.0
 */

export function cmdLsp(answerFrom: ?string): u8 {
    inbox = ArrayList<u8>.init(cAllocator());
    docUris = strings();
    docPaths = strings();
    docTexts = strings();
    reportedFor = strings();
    sections = strings();
    published = ArrayList<bool>.init(cAllocator());
    hx_os_binary_stdio();
    if (const question = answerFrom) return answerFile(question);
    if (const path = os.getenvSet("HELIX_LSP_LOG")) logFd = hx_os_open_append(toCString(path));
    while (true) {
        if (const body = takeMessage()) {
            if (!handle(body)) return shutdownAsked ? 0 : 1;
            continue;
        }
        let timeout: i32 = -1;
        if (changedAt > 0) {
            const left = Debounce - (os.secondsNow() - changedAt);
            if (left <= 0) {
                refresh();
                if (changedAt == 0 || takeable()) continue;
                timeout = 0;   // stepped aside for input: read it, then carry on
            } else {
                timeout = (left * 1000) as i32 + 1;
            }
        }
        const ready = hx_os_wait_stdin(timeout);
        if (ready == 0) continue;   // quiet long enough: the next turn refreshes
        if (!readInput()) return 1;
    }
}
