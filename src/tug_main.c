/*
 * tug_main.c — command-line front-end for the tug library (tug.h).
 *
 * Builds three binaries from one source:
 *   tug              external bbl/Image/initrd files on the command line
 *   tug-embedded     payload (.incbin) baked in (TUG_EMBEDDED)
 *   tug-embedded-apk same, with the Alpine apk seed baked in
 *
 * This owns everything host-terminal: raw tty, the Ctrl-A x / Ctrl-C escapes,
 * SIGWINCH, and turning argv into a tug_settings. The library does the VM.
 *
 * Usage: tug [-m MB] [-a cmdline] [-d disk.img] [-L hp:gp] [-S dir] [-b] <bbl.bin> <Image> [initrd.cpio.gz]
 *   -m MB        guest RAM in MiB (default 256)
 *   -a cmdline   kernel command line (default "console=hvc0 ...")
 *   -d disk.img  attach a raw image as virtio-block /dev/vda (persistent disk).
 *                For tug-embedded, defaults to "tug-data.img" next to the binary
 *                (or $TUG_DISK) when present; -d overrides; -d "" disables.
 *   -L hp:gp     forward host 127.0.0.1:hp -> guest:gp (TCP; repeatable). e.g.
 *                -L 2222:22 then `ssh -p 2222 root@127.0.0.1` (run `tug-sshd` in guest).
 *   -S dir       share host directory `dir` into the guest via 9p (tag "tugshare").
 *   -b           benchmark: report boot wall-time + peak RSS on exit (to stderr)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <signal.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/resource.h>

#include "tug.h"

#if defined(__APPLE__)
int _NSGetExecutablePath(char *buf, uint32_t *bufsize);
#endif

#ifdef TUG_EMBEDDED
/* payload baked into the binary by generated/payload.s (.incbin) */
extern const unsigned char tug_bbl_start[],    tug_bbl_end[];
extern const unsigned char tug_kernel_start[], tug_kernel_end[];
extern const unsigned char tug_initrd_start[], tug_initrd_end[];
#endif

/* ------------------------------------------------------------------ raw tty */

static struct termios oldtty;
static int  old_fd0_flags;
static int  tty_inited;

static void term_exit(void)
{
    if (tty_inited) {
        tcsetattr(0, TCSANOW, &oldtty);
        fcntl(0, F_SETFL, old_fd0_flags);
    }
}

/* Raw mode, ISIG cleared: ^C is forwarded to the guest (bash SIGINT), never
 * delivered to tug. The reader thread implements the Ctrl-A x / Ctrl-C escapes. */
static void term_init(void)
{
    struct termios tty;
    if (!isatty(0))
        return;
    memset(&tty, 0, sizeof(tty));
    tcgetattr(0, &tty);
    oldtty = tty;
    old_fd0_flags = fcntl(0, F_GETFL);

    tty.c_iflag &= ~(IGNBRK|BRKINT|PARMRK|ISTRIP|INLCR|IGNCR|ICRNL|IXON);
    tty.c_oflag |= OPOST;
    tty.c_lflag &= ~(ECHO|ECHONL|ICANON|IEXTEN|ISIG);
    tty.c_cflag &= ~(CSIZE|PARENB);
    tty.c_cflag |= CS8;
    tty.c_cc[VMIN] = 1;
    tty.c_cc[VTIME] = 0;
    tcsetattr(0, TCSANOW, &tty);
    tty_inited = 1;
    atexit(term_exit);
}

/* ------------------------------------------------------------ host callbacks */

static void on_console_out(void *ctx, const uint8_t *data, int len)
{
    int off = 0;
    (void)ctx;
    while (off < len) {
        ssize_t w = write(1, data + off, (size_t)(len - off));
        if (w <= 0)
            break;
        off += (int)w;
    }
}

static void on_exited(void *ctx, int status)
{
    (void)ctx; (void)status;
    /* tug_run returns the status to main; nothing to do here */
}

/* ------------------------------------------------------------- input reader */

/* force-quit tug after this many consecutive ^C (the last one is the confirm) */
#define CTRLC_ARM_COUNT  3
#define CTRLC_WINDOW_MS  2000

static volatile sig_atomic_t g_winch   = 1;   /* apply size at startup */
static volatile sig_atomic_t g_running = 1;

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void on_winch(int sig) { (void)sig; g_winch = 1; }

static void apply_winsize(tug *t)
{
    struct winsize ws;
    int w = 80, h = 25;
    if (ioctl(0, TIOCGWINSZ, &ws) == 0 && ws.ws_col >= 4 && ws.ws_row >= 4) {
        w = ws.ws_col;
        h = ws.ws_row;
    }
    tug_resize(t, w, h);
}

/* Reads stdin, applies the Ctrl-A x / Ctrl-C escapes, and feeds the rest to the
 * guest via tug_input. Polls with a timeout so SIGWINCH + g_running are seen. */
static void *reader_thread(void *arg)
{
    tug *t = arg;
    int esc_state = 0, ctrlc_count = 0, ctrlc_armed = 0;
    uint64_t ctrlc_last = 0;

    while (g_running) {
        fd_set rfds;
        struct timeval tv = { 0, 100 * 1000 };
        uint8_t in[256], out[256];
        int n, i, j = 0;

        if (g_winch) { g_winch = 0; apply_winsize(t); }

        FD_ZERO(&rfds); FD_SET(0, &rfds);
        if (select(1, &rfds, NULL, NULL, &tv) <= 0)
            continue;
        n = read(0, in, sizeof(in));
        if (n <= 0)
            continue;

        for (i = 0; i < n; i++) {
            uint8_t ch = in[i];
            if (esc_state) {
                esc_state = 0;
                if (ch == 'x') {
                    fputs("\r\n[tug] terminated\r\n", stderr);
                    g_running = 0; tug_stop(t);
                    return NULL;
                }
                if (ch == 1) { out[j++] = 1; }   /* Ctrl-A Ctrl-A -> literal ^A */
                continue;
            }
            if (ch == 1) {                       /* Ctrl-A: escape prefix */
                esc_state = 1;
            } else if (ch == 3) {                /* Ctrl-C */
                uint64_t tm = now_ms();
                if (tm - ctrlc_last > CTRLC_WINDOW_MS) { ctrlc_count = 0; ctrlc_armed = 0; }
                ctrlc_last = tm;
                if (ctrlc_armed) {
                    fputs("\r\n[tug] terminated\r\n", stderr);
                    g_running = 0; tug_stop(t);
                    return NULL;
                }
                out[j++] = ch;                   /* deliver ^C to the guest */
                if (++ctrlc_count >= CTRLC_ARM_COUNT) {
                    fputs("\r\n[tug] guest not responding to Ctrl-C? "
                          "press Ctrl-C again to quit tug (or Ctrl-A x).\r\n", stderr);
                    fflush(stderr);
                    ctrlc_armed = 1;
                }
            } else {
                ctrlc_count = 0; ctrlc_armed = 0;
                out[j++] = ch;
            }
        }
        if (j > 0)
            tug_input(t, out, j);
    }
    return NULL;
}

/* ------------------------------------------------------------------ helpers */

static uint8_t *load_file(const char *filename, int *plen)
{
    FILE *f = fopen(filename, "rb");
    uint8_t *buf;
    long size;
    if (!f) { fprintf(stderr, "tug: cannot open %s: %s\n", filename, strerror(errno)); exit(1); }
    fseek(f, 0, SEEK_END); size = ftell(f); fseek(f, 0, SEEK_SET);
    buf = malloc(size);
    if (fread(buf, 1, size, f) != (size_t)size) { fprintf(stderr, "tug: read error %s\n", filename); exit(1); }
    fclose(f);
    *plen = (int)size;
    return buf;
}

static struct timespec t_start;
static int benchmark;

static void report_stats(void)
{
    struct timespec now;
    struct rusage ru;
    double secs;
    if (!benchmark)
        return;
    clock_gettime(CLOCK_MONOTONIC, &now);
    secs = (now.tv_sec - t_start.tv_sec) + (now.tv_nsec - t_start.tv_nsec) / 1e9;
    getrusage(RUSAGE_SELF, &ru);
#if defined(__APPLE__)
    double rss_mb = ru.ru_maxrss / (1024.0 * 1024.0);   /* bytes on Darwin */
#else
    double rss_mb = ru.ru_maxrss / 1024.0;              /* KiB on Linux */
#endif
    fprintf(stderr, "\n[tug] wall=%.3fs  peak_rss=%.1f MiB\n", secs, rss_mb);
}

static const char *usage =
    "usage: tug [-m MB] [-a cmdline] [-d disk.img] [-L hport:gport] [-S dir] [-b] bbl.bin Image [initrd]\n";

/* ------------------------------------------------------------------ main */

int main(int argc, char **argv)
{
    tug_settings cfg;
    tug_host host;
    tug *t;
    char default_disk[4096];        /* must outlive tug_run: cfg.disk_path may point here */
    const char *disk_path = NULL;
    int disk_explicit = 0;
    int c, len, rc;
    pthread_t reader;

    memset(&cfg, 0, sizeof(cfg));
    cfg.ram_mb  = 256;
    cfg.cmdline = "console=hvc0 virtio_net.napi_tx=false";

    while ((c = getopt(argc, argv, "m:a:d:L:S:b")) != -1) {
        switch (c) {
        case 'm': cfg.ram_mb = (int)strtoul(optarg, NULL, 0); break;
        case 'a': cfg.cmdline = optarg; break;
        case 'd': disk_path = optarg; disk_explicit = 1; break;
        case 'S': cfg.share_dir = optarg; break;
        case 'L': {
            int hp = 0, gp = 0;
            if (sscanf(optarg, "%d:%d", &hp, &gp) == 2 && hp > 0 && gp > 0
                && cfg.nforwards < 8) {
                cfg.forwards[cfg.nforwards].host_port  = (uint16_t)hp;
                cfg.forwards[cfg.nforwards].guest_port = (uint16_t)gp;
                cfg.nforwards++;
            } else {
                fprintf(stderr, "tug: bad -L '%s' (want hostport:guestport)\n", optarg);
                return 1;
            }
            break;
        }
        case 'b': benchmark = 1; break;
        default:
            fputs(usage, stderr);
            return 1;
        }
    }
    int nfiles = argc - optind;

#ifdef TUG_EMBEDDED
    if (nfiles == 0) {
        cfg.bios       = tug_bbl_start;    cfg.bios_len   = (int)(tug_bbl_end    - tug_bbl_start);
        cfg.kernel     = tug_kernel_start; cfg.kernel_len = (int)(tug_kernel_end - tug_kernel_start);
        cfg.initrd     = tug_initrd_start; cfg.initrd_len = (int)(tug_initrd_end - tug_initrd_start);
    } else
#endif
    if (nfiles >= 2) {
        cfg.bios   = load_file(argv[optind],   &len); cfg.bios_len   = len;
        cfg.kernel = load_file(argv[optind+1], &len); cfg.kernel_len = len;
        if (nfiles >= 3) {
            cfg.initrd = load_file(argv[optind+2], &len);
            cfg.initrd_len = len;
        }
    } else {
        fputs(usage, stderr);
        return 1;
    }

    /* Persistent data disk: explicit -d wins; for tug-embedded fall back to
     * $TUG_DISK or "tug-data.img" beside the binary when it exists. -d "" off. */
    if (disk_explicit) {
        cfg.disk_path = (disk_path && disk_path[0]) ? disk_path : NULL;
    } else {
#ifdef TUG_EMBEDDED
        const char *env = getenv("TUG_DISK");
        if (env && env[0]) {
            cfg.disk_path = env;
        } else {
            char exe[4096];
            ssize_t n = -1;
#if defined(__APPLE__)
            uint32_t sz = sizeof(exe);
            if (_NSGetExecutablePath(exe, &sz) == 0) n = (ssize_t)strlen(exe);
#else
            n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
            if (n > 0) exe[n] = '\0';
#endif
            if (n > 0) {
                char *slash = strrchr(exe, '/');
                size_t dirlen = slash ? (size_t)(slash - exe + 1) : 0;
                snprintf(default_disk, sizeof(default_disk),
                         "%.*stug-data.img", (int)dirlen, exe);
                if (access(default_disk, F_OK) == 0)
                    cfg.disk_path = default_disk;
            }
        }
#endif
    }

    if (cfg.share_dir)
        fprintf(stderr, "tug: sharing host dir %s as 9p (guest: mount -t 9p "
                "-o trans=virtio tugshare /mnt/share)\n", cfg.share_dir);

    term_init();

    host.ctx = NULL;
    host.console_out = on_console_out;
    host.exited = on_exited;

    t = tug_new(&cfg, &host);
    if (!t) {
        term_exit();
        return 1;
    }

    /* SIGWINCH -> re-read terminal size in the reader thread */
    {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = on_winch;
        sigaction(SIGWINCH, &sa, NULL);
    }

    if (benchmark) {
        clock_gettime(CLOCK_MONOTONIC, &t_start);
        atexit(report_stats);
    }

    pthread_create(&reader, NULL, reader_thread, t);
    rc = tug_run(t);          /* blocks until guest power-off or Ctrl escape */
    g_running = 0;
    pthread_join(reader, NULL);

    tug_free(t);
    term_exit();
    report_stats();
    return rc;
}
