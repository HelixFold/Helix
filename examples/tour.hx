/**
 * Imports
 */

import { stdout, fprintln } from "std/io";
import { ArrayList, Allocator, DebugAllocator, cAllocator, free, readFile } from "std";

/**
 * The most users that the list takes.
 *
 * @since 1.0.0
 */

const MaxUsers: usize = 1_024;

/**
 * What a user may do.
 *
 * @since 1.0.0
 */

enum Role {
    /**
     * Everything, including managing other users.
     *
     * @since 1.0.0
     */

    Admin,

    /**
     * The usual rights of a signed-up user.
     *
     * @since 1.0.0
     */

    Member,

    /**
     * Reading only.
     *
     * @since 1.0.0
     */

    Guest,
}

/**
 * The reasons that adding a user fails.
 *
 * @since 1.0.0
 */

error UserError {
    /**
     * The name is empty.
     *
     * @since 1.0.0
     */

    EmptyName,

    /**
     * The list already holds `MaxUsers` users.
     *
     * @since 1.0.0
     */

    TooMany,
}

/**
 * A user, with defaults for the optional fields.
 *
 * @remarks
 * A literal may leave out `email` and `role`, which then take their defaults.
 *
 * @since 1.0.0
 */

struct User {
    /**
     * The position of the user in the list when it was added.
     *
     * @since 1.0.0
     */

    id: u32,

    /**
     * The name, never empty.
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The email address, or null when the user gave none.
     *
     * @since 1.0.0
     */

    email: ?string = null,

    /**
     * What the user may do, `Role.Guest` unless the literal says otherwise.
     *
     * @since 1.0.0
     */

    role: Role = Role.Guest,

    /**
     * Prints the name and the email address to stdout.
     *
     * @param this - The user, read in place
     * @returns Nothing, or the error of the write
     *
     * @remarks
     * `??` gives `none` for a user without an email address.
     *
     * @since 1.0.0
     */

    display(this: readonly *User): void | Error {
        try fprintln(stdout(), `${this.name} <${this.email ?? "none"}>`);
    }
}

/**
 * Names a role for people.
 *
 * @param role - The role to name
 * @returns `admin` for `Role.Admin`, and `user` for the others
 *
 * @remarks
 * The expression form of `switch` gives one value for each case.
 *
 * @since 1.0.0
 */

function label(role: Role): string {
    return switch (role) {
        case Role.Admin: "admin";
        case Role.Member, Role.Guest: "user";
    };
}

/**
 * Appends a user to the list.
 *
 * @param list - The list to append to
 * @param name - The name of the new user
 * @returns A pointer to the new user in the list
 * @throws UserError.EmptyName when the name is empty
 * @throws UserError.TooMany when the list is full
 *
 * @remarks
 * The error set is inferred, so it also holds the allocation error of `append`.
 * The pointer stays valid only until the list grows again.
 *
 * @since 1.0.0
 */

function addUser(list: *ArrayList<User>, name: string): *User | Error {
    if (name.len == 0) throw UserError.EmptyName;
    if (list.items.len >= MaxUsers) throw UserError.TooMany;

    try list.append(User { id: list.items.len as u32, name });
    return &list.items[list.items.len - 1];
}

/**
 * Prints the size of a file, or why it can't be read.
 *
 * @param a - The allocator for the contents of the file
 * @param path - The file to read
 *
 * @remarks
 * `catch` handles the error here, so the function can't fail.
 *
 * @since 1.0.0
 */

function load(a: dyn Allocator, path: string): void {
    const text = readFile(a, path) catch (e) {
        println(`no user file: ${e}`);
        return;
    };
    defer free(a, text);
    println(`${path}: ${text.len} bytes`);
}

/**
 * Walks through the language on a small list of users.
 *
 * @returns Nothing, or an error that nothing here expects
 *
 * @remarks
 * It allocates through a `DebugAllocator`, which reports a leak when `deinit` runs.
 * The last step adds a user without a name, so `catch` prints the error and `main` returns.
 *
 * @example
 * ```bash
 * helix run examples/tour.hx    # ends with: refused: EmptyName
 * ```
 *
 * @since 1.0.0
 */

export function main(): void | Error {
    let debug = DebugAllocator.init(cAllocator());
    defer void debug.deinit();
    const a = debug.allocator();

    let users = ArrayList<User>.init(a);
    defer users.deinit();

    const ada = try addUser(&users, "ada");
    ada.role = Role.Admin;
    ada.email = "ada@example.com";
    void try addUser(&users, "bob");

    for (const user, i of users.items) {
        println(`${i}: ${user.name} is ${label(user.role)}`);
    }
    try users.items[0].display();

    let total: u8 = 250;
    for (const i of 0..10) {
        total = total +% (i as u8);    // wrapping add
    }
    println(`total: ${total}`);

    load(a, "users.txt");

    const empty = addUser(&users, "") catch (e) {
        println(`refused: ${e}`);
        return;
    };
    println(`added ${empty.name}`);
}
