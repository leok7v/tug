/* macOS shim for Linux <linux/if_tun.h>.
   TinyEMU's tap backend (tun_open) is only reached for `driver: "tap"`.
   On Apple platforms we use the slirp `"user"` backend, so the tap path is
   never executed; these definitions exist only so temu.c compiles unmodified.
   The TUNSETIFF value is intentionally a placeholder and must not be used. */
#ifndef _TUG_IF_TUN_SHIM_H
#define _TUG_IF_TUN_SHIM_H
#include <net/if.h>
#define IFF_TUN   0x0001
#define IFF_TAP   0x0002
#define IFF_NO_PI 0x1000
#define TUNSETIFF 0x400454ca /* placeholder: tap unsupported on macOS */
#endif
