/**
 * Imports
 */

import { equal } from "std";

/**
 * The kind of goods that an item is.
 *
 * @since 1.0.0
 */

enum Category {
    /**
     * Printed books.
     *
     * @since 1.0.0
     */

    Book,

    /**
     * Anything to eat.
     *
     * @since 1.0.0
     */

    Food,

    /**
     * Hand tools.
     *
     * @since 1.0.0
     */

    Tool,
}

/**
 * One line of the inventory.
 *
 * @remarks
 * A literal may leave out `stock`, which then takes its default.
 *
 * @since 1.0.0
 */

struct Item {
    /**
     * The name that orders and lookups use.
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The kind of goods.
     *
     * @since 1.0.0
     */

    category: Category,

    /**
     * The price of one unit.
     *
     * @since 1.0.0
     */

    price: u32,

    /**
     * The units on the shelf, none unless the literal says otherwise.
     *
     * @since 1.0.0
     */

    stock: u32 = 0,

    /**
     * Names the category in lowercase.
     *
     * @param this - The item, read in place
     * @returns `book`, `food`, or `tool`
     *
     * @remarks
     * The `switch` covers every member of `Category`, so it needs no `default`.
     *
     * @since 1.0.0
     */

    label(this: readonly *Item): string {
        return switch (this.category) {
            case Category.Book: "book";
            case Category.Food: "food";
            case Category.Tool: "tool";
        };
    }
}

/**
 * An order that changes the inventory.
 *
 * @since 1.0.0
 */

union Order {
    /**
     * Sells `count` units of the item at `index`.
     *
     * @since 1.0.0
     */

    buy: struct { index: usize, count: u32 },

    /**
     * Puts `count` more units of the item at `index` on the shelf.
     *
     * @since 1.0.0
     */

    restock: struct { index: usize, count: u32 },

    /**
     * Ends the day, which changes nothing.
     *
     * @since 1.0.0
     */

    close,
}

/**
 * The reasons that an order fails.
 *
 * @since 1.0.0
 */

error ShopError {
    /**
     * The order names an index past the end of the inventory.
     *
     * @since 1.0.0
     */

    NoSuchItem,

    /**
     * The shelf holds fewer units than the order asks for.
     *
     * @since 1.0.0
     */

    OutOfStock,
}

/**
 * Finds an item by its name.
 *
 * @param items - The inventory
 * @param name - The name to look for
 * @returns The index of the first item with that name, or null when none has it
 *
 * @remarks
 * `for (const item, i of items)` gives each item with its index.
 *
 * @since 1.0.0
 */

function find(items: readonly Item[], name: string): ?usize {
    for (const item, i of items) {
        if (equal(item.name, name)) return i;
    }
    return null;
}

/**
 * Applies one order to the inventory.
 *
 * @param items - The inventory, changed in place
 * @param order - The order to apply
 * @returns The money that the order takes in
 * @throws ShopError.NoSuchItem when the index is past the end
 * @throws ShopError.OutOfStock when a sale asks for more than the shelf holds
 *
 * @remarks
 * Each case destructures the payload of its variant.
 * The leading-dot cases, `.restock` and `.close`, take the union from the switched value.
 *
 * @since 1.0.0
 */

function apply(items: Item[], order: Order): u32 | ShopError {
    switch (order) {
        case Order.buy({ index, count }):
            if (index >= items.len) throw ShopError.NoSuchItem;
            if (items[index].stock < count) throw ShopError.OutOfStock;
            items[index].stock -= count;
            return items[index].price * count;
        case .restock({ index, count }):
            if (index >= items.len) throw ShopError.NoSuchItem;
            items[index].stock += count;
            return 0;
        case .close:
            return 0;
    }
}

/**
 * Runs a day of a small shop.
 *
 * @returns Nothing, or the error of an order that fails unexpectedly
 *
 * @remarks
 * It restocks, sells, looks an item up, and prints the inventory.
 * The last order asks for more than the shelf holds, so `catch` reports it and `main` returns.
 *
 * @example
 * ```bash
 * helix run examples/shop.hx    # ends with: order refused: OutOfStock
 * ```
 *
 * @since 1.0.0
 */

export function main(): void | Error {
    let items: Item[3] = undefined;
    items[0] = Item { name: "atlas", category: .Book, price: 30, stock: 2 };
    items[1] = Item { name: "bread", category: .Food, price: 3 };
    items[2] = Item { name: "chisel", category: .Tool, price: 12, stock: 5 };

    let revenue: u32 = 0;
    revenue += try apply(&items, Order.restock({ index: 1, count: 10 }));
    revenue += try apply(&items, Order.buy({ index: 1, count: 4 }));
    revenue += try apply(&items, Order.buy({ index: 2, count: 1 }));

    if (const index = find(&items, "bread")) {
        println(`bread is a ${items[index].category}, ${items[index].stock} left`);
    }
    for (const item of items) {
        println(`  ${item.name} (${item.label()}): ${item.stock} in stock`);
    }
    println(`revenue: ${revenue}`);

    const refused = apply(&items, Order.buy({ index: 0, count: 9 })) catch (e) {
        println(`order refused: ${e}`);
        return;
    };
    println(`unexpected sale: ${refused}`);
}
