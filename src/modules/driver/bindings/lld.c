/*
 * lld, linked into the compiler (compile.component.hx): the ELF, Mach-O, COFF, MinGW and WebAssembly linkers that
 * `ld.lld`, `ld64.lld`, `lld-link` and `wasm-ld` run, called in this process, so a build runs no linker program.
 *
 * lld's interface is C++ only, so its functions are declared here by their Itanium C++ names, which every platform the
 * compiler is built for uses, MinGW included. The types are laid out as C++ lays them out and passed as it passes them:
 * an `llvm::ArrayRef` is a pointer and a length, a `raw_ostream &` is a pointer, and `lld::Flavor` is an int.
 */

#include <stdbool.h>
#include <stddef.h>

/** `llvm::ArrayRef<T>`. */
typedef struct {
    const void *data;
    size_t length;
} ArrayRef;

/** `lld::Driver`: one linker's `link(args, stdout, stderr, exitEarly, disableOutput)`, true on success. */
typedef bool (*Driver)(ArrayRef args, void *out, void *err, bool exit_early, bool disable_output);

/** `lld::DriverDef`: a linker and the `lld::Flavor` it handles. */
typedef struct {
    int flavor;
    Driver link;
} DriverDef;

/** `lld::Result`: the exit code, and whether lld's state is clean enough for another link in this process. */
typedef struct {
    int code;
    bool can_run_again;
} Result;

/** The values of `lld::Flavor`. */
enum { Gnu = 1, MinGW = 2, WinLink = 3, Darwin = 4, Wasm = 5 };

/** `llvm::outs()` and `llvm::errs()`: the process's standard output and error as `raw_ostream`. */
void *_ZN4llvm4outsEv(void);
void *_ZN4llvm4errsEv(void);

/** `lld::elf::link`, `lld::macho::link`, `lld::coff::link`, `lld::mingw::link` and `lld::wasm::link`. */
bool _ZN3lld3elf4linkEN4llvm8ArrayRefIPKcEERNS1_11raw_ostreamES7_bb(ArrayRef, void *, void *, bool, bool);
bool _ZN3lld5macho4linkEN4llvm8ArrayRefIPKcEERNS1_11raw_ostreamES7_bb(ArrayRef, void *, void *, bool, bool);
bool _ZN3lld4coff4linkEN4llvm8ArrayRefIPKcEERNS1_11raw_ostreamES7_bb(ArrayRef, void *, void *, bool, bool);
bool _ZN3lld5mingw4linkEN4llvm8ArrayRefIPKcEERNS1_11raw_ostreamES7_bb(ArrayRef, void *, void *, bool, bool);
bool _ZN3lld4wasm4linkEN4llvm8ArrayRefIPKcEERNS1_11raw_ostreamES7_bb(ArrayRef, void *, void *, bool, bool);

/** `lld::lldMain(args, stdout, stderr, drivers)`: picks the linker from `args[0]`, links, then resets lld. */
Result _ZN3lld7lldMainEN4llvm8ArrayRefIPKcEERNS0_11raw_ostreamES6_NS1_INS_9DriverDefEEE(
    ArrayRef args, void *out, void *err, ArrayRef drivers);

/** Set once lld crashed: its state is then broken, and no other link may run in this process. */
static bool broken;

/**
 * Links with lld, as the program named by `argv[0]` would: `ld.lld`, `ld64.lld`, `lld-link`, or `wasm-ld`.
 * `ld.lld -m i386pep` (or `arm64pe`) is the MinGW linker. lld prints its own errors.
 * The exit code is 0 on success, and -1 without linking once a crashed link has left lld broken.
 */
int hx_lld_link(const char *const *argv, size_t argc) {
    static const DriverDef drivers[] = {
        {WinLink, _ZN3lld4coff4linkEN4llvm8ArrayRefIPKcEERNS1_11raw_ostreamES7_bb},
        {Gnu, _ZN3lld3elf4linkEN4llvm8ArrayRefIPKcEERNS1_11raw_ostreamES7_bb},
        {MinGW, _ZN3lld5mingw4linkEN4llvm8ArrayRefIPKcEERNS1_11raw_ostreamES7_bb},
        {Darwin, _ZN3lld5macho4linkEN4llvm8ArrayRefIPKcEERNS1_11raw_ostreamES7_bb},
        {Wasm, _ZN3lld4wasm4linkEN4llvm8ArrayRefIPKcEERNS1_11raw_ostreamES7_bb},
    };
    if (broken) return -1;
    ArrayRef args = {argv, argc};
    ArrayRef defs = {drivers, sizeof drivers / sizeof drivers[0]};
    Result result = _ZN3lld7lldMainEN4llvm8ArrayRefIPKcEERNS0_11raw_ostreamES6_NS1_INS_9DriverDefEEE(
        args, _ZN4llvm4outsEv(), _ZN4llvm4errsEv(), defs);
    if (!result.can_run_again) broken = true;
    return result.code;
}
