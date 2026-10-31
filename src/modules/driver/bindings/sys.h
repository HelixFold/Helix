// What the driver calls in the C library, the OS and libclang. sys.hx is generated from it:
//   helix translate-c src/driver/sys.h -I/opt/homebrew/opt/llvm/include --all -o src/driver/sys.hx
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <ftw.h>
#include <limits.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <clang-c/Index.h>
