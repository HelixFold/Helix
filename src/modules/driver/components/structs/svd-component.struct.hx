/**
 * Imports
 */

import { ArrayList } from "std/list";
import { Strings } from "@modules/driver/components/structs/os-component.struct";

/**
 * An element of the XML document that {@link parseXml} reads.
 *
 * @remarks
 * The reader keeps elements, their attribute text, and the text between their tags.
 * It skips comments, declarations such as `<?xml ...?>` and `<!DOCTYPE ...>`, and CDATA sections.
 * The nodes live in one list, and a node refers to its children by their index in that list.
 *
 * @example
 * ```hx
 * // <field><name>EN</name></field>
 * node.name;     // "field"
 * node.children; // [ the index of the name element ]
 * ```
 *
 * @see parseXml
 * @since 1.0.0
 */

export struct XNode {
    /**
     * The tag name of the element, or an empty string for the document node at index 0.
     *
     * @example
     * ```hx
     * node.name; // "register"
     * ```
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The raw attribute text of the start tag, after the tag name.
     *
     * @remarks
     * {@link attribute} looks a value up in this text when it is needed.
     *
     * @example
     * ```hx
     * // <peripheral derivedFrom="GPIOA">
     * node.attrs; // ' derivedFrom="GPIOA"'
     * ```
     *
     * @since 1.0.0
     */

    attrs: string,

    /**
     * The raw text between the start tag and the end tag.
     *
     * @remarks
     * For a leaf element it is the value of the element, with its entities still encoded.
     * For an element with children it also holds their markup.
     * A self-closing element keeps an empty text.
     *
     * @example
     * ```hx
     * // <description>A &amp; B</description>
     * node.text; // "A &amp; B"
     * ```
     *
     * @since 1.0.0
     */

    text: string,

    /**
     * The indexes of the child elements, in document order.
     *
     * @example
     * ```hx
     * node.children.items.len; // 2 for <field><name/><bitOffset/></field>
     * ```
     *
     * @since 1.0.0
     */

    children: ArrayList<u32>,
}

/**
 * A bit field of a register.
 *
 * @remarks
 * A field with a width of 0, or one that reaches past bit 63, is never made.
 *
 * @example
 * ```hx
 * // <field><name>MODER0</name><bitOffset>0</bitOffset><bitWidth>2</bitWidth></field>
 * field; // { name: "MODER0", description: "", lsb: 0, width: 2 }
 * ```
 *
 * @since 1.0.0
 */

export struct Field {
    /**
     * The name of the field in the SVD file, with any `%s` already replaced.
     *
     * @example
     * ```hx
     * field.name; // "GPIOAEN"
     * ```
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The description of the field, or an empty string.
     *
     * @example
     * ```hx
     * field.description; // "IO port A clock enable"
     * ```
     *
     * @since 1.0.0
     */

    description: string,

    /**
     * The lowest bit of the field.
     *
     * @example
     * ```hx
     * field.lsb; // 4 for a bitRange of [7:4]
     * ```
     *
     * @since 1.0.0
     */

    lsb: u32,

    /**
     * The number of bits in the field.
     *
     * @example
     * ```hx
     * field.width; // 4 for a bitRange of [7:4]
     * ```
     *
     * @since 1.0.0
     */

    width: u32,
}

/**
 * A register of a peripheral, with its offset from the base address of the peripheral.
 *
 * @remarks
 * Registers inside a cluster carry the cluster name and `_` before their own name,
 * and their offset already includes the offset of the cluster.
 *
 * @example
 * ```hx
 * // <register><name>MODER</name><addressOffset>0x0</addressOffset>...</register>
 * reg.offset; // 0
 * reg.size;   // 32
 * ```
 *
 * @since 1.0.0
 */

export struct Reg {
    /**
     * The name of the register.
     *
     * @remarks
     * It is the SVD name until {@link settle} makes it a unique Helix identifier.
     *
     * @example
     * ```hx
     * reg.name; // "MODER"
     * ```
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The description of the register, or an empty string.
     *
     * @example
     * ```hx
     * reg.description; // "GPIO port mode register"
     * ```
     *
     * @since 1.0.0
     */

    description: string,

    /**
     * The offset of the register from the base address of its peripheral, in bytes.
     *
     * @example
     * ```hx
     * reg.offset; // 0x14
     * ```
     *
     * @since 1.0.0
     */

    offset: u64,

    /**
     * The size of the register in bits.
     *
     * @remarks
     * It comes from the register, else from the peripheral, else from the device, and defaults to 32.
     *
     * @example
     * ```hx
     * reg.size; // 16
     * ```
     *
     * @since 1.0.0
     */

    size: u32,

    /**
     * The bit fields of the register, with field arrays spelled out.
     *
     * @example
     * ```hx
     * reg.fields.items.len; // 0 for a register written as a whole
     * ```
     *
     * @since 1.0.0
     */

    fields: ArrayList<Field>,

    /**
     * The name of a register in the same peripheral whose fields this one copies, or an empty string.
     *
     * @example
     * ```hx
     * reg.derivedFrom; // "CR1"
     * ```
     *
     * @since 1.0.0
     */

    derivedFrom: string,
}

/**
 * A peripheral instance of the chip, such as one GPIO port.
 *
 * @remarks
 * Each instance becomes one `export const` of its struct type in the output.
 *
 * @example
 * ```hx
 * periph; // { name: "GPIOB", base: 0x40020400, typeOf: 0 }
 * ```
 *
 * @since 1.0.0
 */

export struct Periph {
    /**
     * The name of the peripheral, made a Helix identifier.
     *
     * @example
     * ```hx
     * periph.name; // "USART1"
     * ```
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The description of the peripheral.
     *
     * @remarks
     * A derived peripheral without registers or a description of its own takes the one of its base.
     *
     * @example
     * ```hx
     * periph.description; // "General-purpose I/Os"
     * ```
     *
     * @since 1.0.0
     */

    description: string,

    /**
     * The base address of the peripheral.
     *
     * @example
     * ```hx
     * periph.base; // 0x40020000
     * ```
     *
     * @since 1.0.0
     */

    base: u64,

    /**
     * The index of the `<peripheral>` element in the parsed document.
     *
     * @example
     * ```hx
     * periph.node; // 12
     * ```
     *
     * @since 1.0.0
     */

    node: u32,

    /**
     * The index of the struct type of the peripheral in the list of types.
     *
     * @remarks
     * Peripherals with the same registers share one index, so they share one struct type.
     *
     * @example
     * ```hx
     * periph.typeOf; // 0 for both GPIOA and GPIOB
     * ```
     *
     * @since 1.0.0
     */

    typeOf: usize,
}

/**
 * A struct type of the output, which holds the registers that some peripherals share.
 *
 * @remarks
 * A peripheral that says `derivedFrom` without registers of its own reuses the type of its base.
 * Another peripheral reuses a type whose registers have the same names, offsets, sizes, and field counts.
 *
 * @example
 * ```hx
 * ptype.name;  // "Gpio"
 * ptype.enums; // [ "GpioModer", "GpioOtyper", ... ]
 * ```
 *
 * @since 1.0.0
 */

export struct PType {
    /**
     * The name of the struct, in Pascal case, from the group name of the peripheral or else from its name.
     *
     * @example
     * ```hx
     * ptype.name; // "Gpio"
     * ```
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The description of the first peripheral that made the type.
     *
     * @example
     * ```hx
     * ptype.description; // "General-purpose I/Os"
     * ```
     *
     * @since 1.0.0
     */

    description: string,

    /**
     * The registers of the type, in the order of the SVD file.
     *
     * @example
     * ```hx
     * ptype.regs.items[0].name; // "MODER"
     * ```
     *
     * @since 1.0.0
     */

    regs: ArrayList<Reg>,

    /**
     * The name of the field enum of each register, at the same index as the register.
     *
     * @example
     * ```hx
     * ptype.enums.items[0]; // "GpioModer"
     * ```
     *
     * @since 1.0.0
     */

    enums: Strings,
}

/**
 * An interrupt of the chip.
 *
 * @remarks
 * An interrupt is kept once, the first time its number or its name appears.
 *
 * @example
 * ```hx
 * irq; // { name: "TIM2", description: "TIM2 global interrupt", value: 28 }
 * ```
 *
 * @since 1.0.0
 */

export struct Irq {
    /**
     * The name of the interrupt, made a Helix identifier.
     *
     * @example
     * ```hx
     * irq.name; // "TIM2"
     * ```
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The description of the interrupt, or an empty string.
     *
     * @example
     * ```hx
     * irq.description; // "TIM2 global interrupt"
     * ```
     *
     * @since 1.0.0
     */

    description: string,

    /**
     * The number of the interrupt, so its handler is `IRQ<value>_Handler`.
     *
     * @example
     * ```hx
     * irq.value; // 28
     * ```
     *
     * @since 1.0.0
     */

    value: u64,
}
