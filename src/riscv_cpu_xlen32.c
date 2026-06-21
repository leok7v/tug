/* Build riscv_cpu.c for XLEN=32. The Makefile produces riscv_cpu32.o the same
 * way (cc -DMAX_XLEN=32 ... riscv_cpu.c). This wrapper lets a single Xcode
 * target compile both widths without per-file build flags — riscv_cpu.c
 * namespaces every symbol via glue(name, MAX_XLEN), so the two objects don't
 * collide. Resolved through the vendors/tinyemu header search path. */
#define MAX_XLEN 32
#include "riscv_cpu.c"
