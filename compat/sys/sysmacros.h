/* macOS shim for glibc <sys/sysmacros.h>: major()/minor()/makedev()
   are provided by <sys/types.h> on Darwin. */
#ifndef _TUG_SYSMACROS_SHIM_H
#define _TUG_SYSMACROS_SHIM_H
#include <sys/types.h>
#endif
