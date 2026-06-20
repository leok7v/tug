/* Forced-include (-include) compat shim for building TinyEMU on Darwin.
   Maps Linux struct stat timespec member names to their Darwin equivalents.
   Applied to every translation unit so the vendored source stays pristine. */
#ifndef _TUG_DARWIN_COMPAT_H
#define _TUG_DARWIN_COMPAT_H
#if defined(__APPLE__)
#define st_atim st_atimespec
#define st_mtim st_mtimespec
#define st_ctim st_ctimespec
#endif
#endif
