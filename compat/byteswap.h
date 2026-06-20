/* macOS shim for glibc <byteswap.h> (used by TinyEMU cutils.h). */
#ifndef _TUG_BYTESWAP_SHIM_H
#define _TUG_BYTESWAP_SHIM_H
#include <libkern/OSByteOrder.h>
#define bswap_16(x) OSSwapInt16(x)
#define bswap_32(x) OSSwapInt32(x)
#define bswap_64(x) OSSwapInt64(x)
#endif
