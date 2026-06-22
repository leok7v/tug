/* Self-timing compute kernel. On Linux it runs as PID 1 (init): time, print,
 * power off. On macOS it just times+prints (native-arm64 proxy for VZ speed). */
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/reboot.h>
#endif
int main(void) {
    const uint64_t n = 300000000ULL;          /* 3e8 iterations, ~4 ops each */
    struct timespec a, b;
    volatile uint64_t sink;
    clock_gettime(CLOCK_MONOTONIC, &a);
    uint64_t x = 0x9e3779b97f4a7c15ULL;
    for (uint64_t i = 0; i < n; i++) {
        x = x * 6364136223846793005ULL + 1442695040888963407ULL;
        x ^= x >> 31;
    }
    clock_gettime(CLOCK_MONOTONIC, &b);
    sink = x;
    double s = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
    printf("\nBENCH iters=%llu time=%.4fs Miter_s=%.1f checksum=%llx\n",
           (unsigned long long)n, s, (double)n / s / 1e6,
           (unsigned long long)sink);
    fflush(stdout);
#ifdef __linux__
    sync(); reboot(RB_POWER_OFF); for (;;) pause();
#endif
    return 0;
}
