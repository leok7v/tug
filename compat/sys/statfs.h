/* macOS shim for glibc <sys/statfs.h>: statfs() lives in <sys/mount.h>. */
#ifndef _TUG_STATFS_SHIM_H
#define _TUG_STATFS_SHIM_H
#include <sys/param.h>
#include <sys/mount.h>
#endif
