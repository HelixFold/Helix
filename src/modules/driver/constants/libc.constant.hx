/**
 * The version of musl that Helix builds for Linux targets with the `-musl` ABI.
 *
 * @remarks
 * It names the unpacked source folder, `musl-<version>`, and goes into the `version.h` that musl's build would make.
 *
 * @example
 * ```hx
 * MuslVersion; // "1.2.5"
 * ```
 *
 * @see MuslUrl
 * @since 1.0.0
 */

export const MuslVersion = "1.2.5";

/**
 * The address of the musl source archive.
 *
 * @example
 * ```hx
 * MuslUrl; // "https://musl.libc.org/releases/musl-1.2.5.tar.gz"
 * ```
 *
 * @see MuslSha256
 * @since 1.0.0
 */

export const MuslUrl = "https://musl.libc.org/releases/musl-1.2.5.tar.gz";

/**
 * The pinned SHA-256 of the musl source archive.
 *
 * @remarks
 * It is the hash that musl.libc.org publishes.
 * An archive with another hash is deleted and never unpacked.
 *
 * @example
 * ```hx
 * MuslSha256; // "a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"
 * ```
 *
 * @since 1.0.0
 */

export const MuslSha256 = "a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4";

/**
 * The folder that the compiler-rt source archive unpacks into.
 *
 * @remarks
 * compiler-rt 17.0.6 is the last LLVM release with a compiler-rt archive of its own.
 * The builtins are plain functions whose ABI does not change between LLVM versions,
 * so this release serves the newer LLVM that Helix links.
 *
 * @example
 * ```hx
 * CrtName; // "compiler-rt-17.0.6.src"
 * ```
 *
 * @see CrtUrl
 * @since 1.0.0
 */

export const CrtName = "compiler-rt-17.0.6.src";

/**
 * The address of the compiler-rt source archive.
 *
 * @example
 * ```hx
 * CrtUrl; // the compiler-rt-17.0.6.src.tar.xz of the llvmorg-17.0.6 GitHub release
 * ```
 *
 * @see CrtSha256
 * @since 1.0.0
 */

export const CrtUrl = "https://github.com/llvm/llvm-project/releases/download/llvmorg-17.0.6/compiler-rt-17.0.6.src.tar.xz";

/**
 * The pinned SHA-256 of the compiler-rt source archive.
 *
 * @example
 * ```hx
 * CrtSha256; // "11b8d09dcf92a0f91c5c82defb5ad9ff4acf5cf073a80c317204baa922d136b4"
 * ```
 *
 * @since 1.0.0
 */

export const CrtSha256 = "11b8d09dcf92a0f91c5c82defb5ad9ff4acf5cf073a80c317204baa922d136b4";

/**
 * The wasi-libc tag that Helix builds for `wasm32-unknown-wasip1`.
 *
 * @example
 * ```hx
 * WasiLibcVersion; // "wasi-sdk-27"
 * ```
 *
 * @see WasiLibcUrl
 * @since 1.0.0
 */

export const WasiLibcVersion = "wasi-sdk-27";

/**
 * The address of the GitHub archive of the wasi-libc tag.
 *
 * @example
 * ```hx
 * WasiLibcUrl; // "https://github.com/WebAssembly/wasi-libc/archive/refs/tags/wasi-sdk-27.tar.gz"
 * ```
 *
 * @see WasiLibcSha256
 * @since 1.0.0
 */

export const WasiLibcUrl = "https://github.com/WebAssembly/wasi-libc/archive/refs/tags/wasi-sdk-27.tar.gz";

/**
 * The pinned SHA-256 of the wasi-libc archive.
 *
 * @remarks
 * It is the hash of the tag archive that GitHub serves.
 *
 * @example
 * ```hx
 * WasiLibcSha256; // "00850da0742670d5ad7fd556bf7bc5452512bac79f17ac76d5cfaa3b74526898"
 * ```
 *
 * @since 1.0.0
 */

export const WasiLibcSha256 = "00850da0742670d5ad7fd556bf7bc5452512bac79f17ac76d5cfaa3b74526898";

/**
 * An empty list of strings, for an argument that takes a list and needs none.
 *
 * @remarks
 * An archive made from it is empty, which is how the empty `libm.a` and `libpthread.a` come about.
 *
 * @example
 * ```hx
 * None.len; // 0
 * ```
 *
 * @since 1.0.0
 */

export const None: readonly string[] = [];

/**
 * The file extensions of C sources.
 *
 * @example
 * ```hx
 * COnly; // [ ".c" ]
 * ```
 *
 * @see CAndAsm
 * @since 1.0.0
 */

export const COnly: string[1] = [".c"];

/**
 * The file extensions of C and assembly sources.
 *
 * @example
 * ```hx
 * CAndAsm; // [ ".c", ".s" ]
 * ```
 *
 * @see COnly
 * @since 1.0.0
 */

export const CAndAsm: string[2] = [".c", ".s"];

/**
 * The include folders of the lower half of wasi-libc, relative to its source tree.
 *
 * @remarks
 * The lower half is the part that calls WASI, mostly cloudlibc.
 *
 * @example
 * ```hx
 * BottomDirs[0]; // "libc-bottom-half/headers/private"
 * ```
 *
 * @see TopDirs
 * @since 1.0.0
 */

export const BottomDirs: string[5] = [
    "libc-bottom-half/headers/private", "libc-bottom-half/cloudlibc/src/include", "libc-bottom-half/cloudlibc/src",
    "libc-top-half/musl/src/include", "libc-top-half/musl/src/internal",
];

/**
 * The include folders of the upper half of wasi-libc, relative to its source tree.
 *
 * @remarks
 * The upper half is the portable part of musl.
 *
 * @example
 * ```hx
 * TopDirs[2]; // "libc-top-half/musl/arch/wasm32"
 * ```
 *
 * @see BottomDirs
 * @since 1.0.0
 */

export const TopDirs: string[5] = [
    "libc-top-half/musl/src/include", "libc-top-half/musl/src/internal", "libc-top-half/musl/arch/wasm32",
    "libc-top-half/musl/arch/generic", "libc-top-half/headers/private",
];

/**
 * The flags of the wasi-libc files that print and scan numbers.
 *
 * @remarks
 * They leave out `long double` support, as the wasi-libc Makefile does.
 * The files are `vfprintf.c`, `vfwprintf.c`, `vfscanf.c`, `strtod.c`, `wcstod.c`, and `floatscan.c`.
 *
 * @example
 * ```hx
 * Printscan[0]; // "-D__wasilibc_printscan_no_long_double"
 * ```
 *
 * @since 1.0.0
 */

export const Printscan: string[2] = [
    "-D__wasilibc_printscan_no_long_double",
    "-D__wasilibc_printscan_full_support_option=\"long double printing isn't supported\"",
];

/**
 * The flags of the wasi-libc `memcpy.c`, `memmove.c`, and `memset.c`.
 *
 * @remarks
 * They use the bulk memory instructions for copies above 32 bytes.
 *
 * @example
 * ```hx
 * Bulk; // [ "-mbulk-memory", "-DBULK_MEMORY_THRESHOLD=32" ]
 * ```
 *
 * @since 1.0.0
 */

export const Bulk: string[2] = ["-mbulk-memory", "-DBULK_MEMORY_THRESHOLD=32"];

/**
 * The include folders of dlmalloc, the allocator of wasi-libc.
 *
 * @example
 * ```hx
 * MallocDirs; // [ "dlmalloc/include" ]
 * ```
 *
 * @since 1.0.0
 */

export const MallocDirs: string[1] = ["dlmalloc/include"];

/**
 * The include folders of the fts file tree functions in wasi-libc.
 *
 * @example
 * ```hx
 * FtsDirs; // [ "fts/musl-fts", "fts" ]
 * ```
 *
 * @since 1.0.0
 */

export const FtsDirs: string[2] = ["fts/musl-fts", "fts"];

/**
 * The files of musl's `src/internal` that the upper half of wasi-libc leaves out.
 *
 * @example
 * ```hx
 * OmitInternal[1]; // "syscall.c"
 * ```
 *
 * @since 1.0.0
 */

export const OmitInternal: string[6] = ["procfdname.c", "syscall.c", "syscall_ret.c", "vdso.c", "version.c", "emulate_wait4.c"];

/**
 * The files of musl's `src/stdio` that the upper half of wasi-libc leaves out.
 *
 * @remarks
 * They lock files, make temporary files, run processes, or rename and remove files.
 *
 * @example
 * ```hx
 * OmitStdio[0]; // "flockfile.c"
 * ```
 *
 * @since 1.0.0
 */

export const OmitStdio: string[12] = [
    "flockfile.c", "funlockfile.c", "__lockfile.c", "ftrylockfile.c", "rename.c", "tmpnam.c", "tmpfile.c",
    "tempnam.c", "popen.c", "pclose.c", "remove.c", "gets.c",
];

/**
 * The files of musl's `src/string` that the upper half of wasi-libc leaves out.
 *
 * @example
 * ```hx
 * OmitString; // [ "strsignal.c" ]
 * ```
 *
 * @since 1.0.0
 */

export const OmitString: string[1] = ["strsignal.c"];

/**
 * The files of musl's `src/locale` that the upper half of wasi-libc leaves out.
 *
 * @example
 * ```hx
 * OmitLocale[1]; // "textdomain.c"
 * ```
 *
 * @since 1.0.0
 */

export const OmitLocale: string[3] = ["dcngettext.c", "textdomain.c", "bind_textdomain_codeset.c"];

/**
 * The files of musl's `src/math` that the upper half of wasi-libc leaves out.
 *
 * @remarks
 * WebAssembly has instructions for these functions, such as `sqrt`, `floor`, and `fmin`.
 *
 * @example
 * ```hx
 * OmitMath[6]; // "ceilf.c"
 * ```
 *
 * @since 1.0.0
 */

export const OmitMath: string[26] = [
    "__signbit.c", "__signbitf.c", "__signbitl.c", "__fpclassify.c", "__fpclassifyf.c", "__fpclassifyl.c", "ceilf.c",
    "ceil.c", "floorf.c", "floor.c", "truncf.c", "trunc.c", "rintf.c", "rint.c", "nearbyintf.c", "nearbyint.c",
    "sqrtf.c", "sqrt.c", "fabsf.c", "fabs.c", "copysignf.c", "copysign.c", "fminf.c", "fmaxf.c", "fmin.c", "fmax.c",
];

/**
 * The files of musl's `src/complex` that the upper half of wasi-libc leaves out.
 *
 * @example
 * ```hx
 * OmitComplex[0]; // "crealf.c"
 * ```
 *
 * @since 1.0.0
 */

export const OmitComplex: string[6] = ["crealf.c", "creal.c", "creall.c", "cimagf.c", "cimag.c", "cimagl.c"];

/**
 * The headers removed from the wasi-libc `include/` folder after it is copied.
 *
 * @remarks
 * They are the `.in` templates that are not headers, the headers that the compiler brings itself,
 * musl's `bits/errno.h` in favor of the WASI one, and the headers of what WASI does not have.
 *
 * @example
 * ```hx
 * WasiOmitHeaders[3]; // "stdarg.h"
 * ```
 *
 * @since 1.0.0
 */

export const WasiOmitHeaders: readonly string[] = [
    "bits/syscall.h.in", "bits/alltypes.h.in", "alltypes.h.in", "stdarg.h", "stddef.h", "bits/errno.h",
    "sys/procfs.h", "sys/user.h", "sys/kd.h", "sys/vt.h", "sys/soundcard.h", "sys/sem.h", "sys/shm.h", "sys/msg.h",
    "sys/ipc.h", "sys/ptrace.h", "sys/statfs.h", "bits/kd.h", "bits/vt.h", "bits/soundcard.h", "bits/sem.h",
    "bits/shm.h", "bits/msg.h", "bits/ipc.h", "bits/ptrace.h", "bits/statfs.h", "sys/vfs.h", "syslog.h",
    "sys/syslog.h", "wait.h", "sys/wait.h", "ucontext.h", "sys/ucontext.h", "paths.h", "utmp.h", "utmpx.h",
    "lastlog.h", "sys/acct.h", "sys/cachectl.h", "sys/epoll.h", "sys/reboot.h", "sys/swap.h", "sys/sendfile.h",
    "sys/inotify.h", "sys/quota.h", "sys/klog.h", "sys/fsuid.h", "sys/io.h", "sys/prctl.h", "sys/mtio.h",
    "sys/mount.h", "sys/fanotify.h", "sys/personality.h", "elf.h", "link.h", "bits/link.h", "scsi/scsi.h",
    "scsi/scsi_ioctl.h", "scsi/sg.h", "sys/auxv.h", "pwd.h", "shadow.h", "grp.h", "mntent.h", "resolv.h", "pty.h",
    "ulimit.h", "sys/xattr.h", "wordexp.h", "spawn.h", "sys/membarrier.h", "sys/signalfd.h", "termios.h",
    "sys/termios.h", "bits/termios.h", "net/if.h", "net/if_arp.h", "net/ethernet.h", "net/route.h",
    "netinet/if_ether.h", "netinet/ether.h", "sys/timerfd.h", "libintl.h", "sys/sysmacros.h", "aio.h", "netdb.h",
];

/**
 * The portable files of musl that the upper half of wasi-libc takes one by one, relative to musl's `src`.
 *
 * @remarks
 * The list ends with the pthread functions that work in a single-threaded program.
 *
 * @example
 * ```hx
 * WasiPicked[0]; // "misc/a64l.c"
 * ```
 *
 * @since 1.0.0
 */

export const WasiPicked: readonly string[] = [
    "misc/a64l.c", "misc/basename.c", "misc/dirname.c", "misc/ffs.c", "misc/ffsl.c", "misc/ffsll.c", "misc/fmtmsg.c",
    "misc/getdomainname.c", "misc/gethostid.c", "misc/getopt.c", "misc/getopt_long.c", "misc/getsubopt.c",
    "misc/realpath.c", "misc/uname.c", "misc/nftw.c", "errno/strerror.c", "network/htonl.c", "network/htons.c",
    "network/ntohl.c", "network/ntohs.c", "network/inet_ntop.c", "network/inet_pton.c", "network/inet_aton.c",
    "network/in6addr_any.c", "network/in6addr_loopback.c", "fenv/fenv.c", "fenv/fesetround.c", "fenv/feupdateenv.c",
    "fenv/fesetexceptflag.c", "fenv/fegetexceptflag.c", "fenv/feholdexcept.c", "exit/exit.c", "exit/atexit.c",
    "exit/assert.c", "exit/quick_exit.c", "exit/at_quick_exit.c", "time/strftime.c", "time/asctime.c",
    "time/asctime_r.c", "time/ctime.c", "time/ctime_r.c", "time/wcsftime.c", "time/strptime.c", "time/difftime.c",
    "time/timegm.c", "time/ftime.c", "time/gmtime.c", "time/gmtime_r.c", "time/timespec_get.c", "time/getdate.c",
    "time/localtime.c", "time/localtime_r.c", "time/mktime.c", "time/__tm_to_secs.c", "time/__month_to_secs.c",
    "time/__secs_to_tm.c", "time/__year_to_secs.c", "time/__tz.c", "fcntl/creat.c", "dirent/alphasort.c",
    "dirent/versionsort.c", "env/__stack_chk_fail.c", "env/clearenv.c", "env/getenv.c", "env/putenv.c",
    "env/setenv.c", "env/unsetenv.c", "unistd/posix_close.c", "stat/futimesat.c", "legacy/getpagesize.c",
    "thread/thrd_sleep.c",
    // pthreads functions that work single-threaded
    "thread/default_attr.c", "thread/pthread_attr_destroy.c", "thread/pthread_attr_get.c", "thread/pthread_attr_init.c",
    "thread/pthread_attr_setdetachstate.c", "thread/pthread_attr_setguardsize.c", "thread/pthread_attr_setschedparam.c",
    "thread/pthread_attr_setstack.c", "thread/pthread_attr_setstacksize.c", "thread/pthread_barrierattr_destroy.c",
    "thread/pthread_barrierattr_init.c", "thread/pthread_barrierattr_setpshared.c", "thread/pthread_cancel.c",
    "thread/pthread_cleanup_push.c", "thread/pthread_condattr_destroy.c", "thread/pthread_condattr_init.c",
    "thread/pthread_condattr_setclock.c", "thread/pthread_condattr_setpshared.c", "thread/pthread_equal.c",
    "thread/pthread_getspecific.c", "thread/pthread_key_create.c", "thread/pthread_mutex_destroy.c",
    "thread/pthread_mutex_init.c", "thread/pthread_mutexattr_destroy.c", "thread/pthread_mutexattr_init.c",
    "thread/pthread_mutexattr_setprotocol.c", "thread/pthread_mutexattr_setpshared.c",
    "thread/pthread_mutexattr_setrobust.c", "thread/pthread_mutexattr_settype.c", "thread/pthread_rwlock_destroy.c",
    "thread/pthread_rwlock_init.c", "thread/pthread_rwlockattr_destroy.c", "thread/pthread_rwlockattr_init.c",
    "thread/pthread_rwlockattr_setpshared.c", "thread/pthread_self.c", "thread/pthread_setcancelstate.c",
    "thread/pthread_setcanceltype.c", "thread/pthread_setspecific.c", "thread/pthread_spin_destroy.c",
    "thread/pthread_spin_init.c", "thread/pthread_testcancel.c",
];
