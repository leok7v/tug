/*
 * tug — a minimal standalone orchestrator around the TinyEMU RISC-V core.
 *
 * Unlike Bellard's `temu`, this drives the emulator *programmatically* (no JSON
 * config file): it loads a bios (bbl), kernel (Image) and optional initrd into
 * memory, wires the guest console to host stdin/stdout, and runs. This is the
 * embeddable "kernel in a box" core for the iOS/Android story.
 *
 * The console glue and run loop are adapted from TinyEMU's temu.c (MIT).
 *
 * Usage: tug [-m MB] [-a cmdline] [-b] <bbl.bin> <Image> [initrd.cpio.gz]
 *   -m MB        guest RAM in MiB (default 256)
 *   -a cmdline   kernel command line (default "console=hvc0")
 *   -b           benchmark: report boot wall-time + peak RSS on exit (to stderr)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <signal.h>

#include "cutils.h"
#include "iomem.h"
#include "virtio.h"
#include "machine.h"

#ifdef TUG_EMBEDDED
/* payload baked into the binary by generated/payload.s (.incbin) */
extern const unsigned char tug_bbl_start[],    tug_bbl_end[];
extern const unsigned char tug_kernel_start[], tug_kernel_end[];
extern const unsigned char tug_initrd_start[], tug_initrd_end[];
#endif

/* ------------------------------------------------------------------ console */

typedef struct {
    int stdin_fd;
    int console_esc_state;
    BOOL resize_pending;
} STDIODevice;

static struct termios oldtty;
static int old_fd0_flags;
static STDIODevice *global_stdio_device;
static BOOL tty_inited;

static void term_exit(void)
{
    if (tty_inited) {
        tcsetattr(0, TCSANOW, &oldtty);
        fcntl(0, F_SETFL, old_fd0_flags);
    }
}

static void term_init(BOOL allow_ctrlc)
{
    struct termios tty;
    /* only switch the terminal to raw mode if stdin is actually a tty */
    if (!isatty(0))
        return;
    memset(&tty, 0, sizeof(tty));
    tcgetattr(0, &tty);
    oldtty = tty;
    old_fd0_flags = fcntl(0, F_GETFL);

    tty.c_iflag &= ~(IGNBRK|BRKINT|PARMRK|ISTRIP|INLCR|IGNCR|ICRNL|IXON);
    tty.c_oflag |= OPOST;
    tty.c_lflag &= ~(ECHO|ECHONL|ICANON|IEXTEN);
    if (!allow_ctrlc)
        tty.c_lflag &= ~ISIG;
    tty.c_cflag &= ~(CSIZE|PARENB);
    tty.c_cflag |= CS8;
    tty.c_cc[VMIN] = 1;
    tty.c_cc[VTIME] = 0;
    tcsetattr(0, TCSANOW, &tty);
    tty_inited = TRUE;
    atexit(term_exit);
}

static void console_write(void *opaque, const uint8_t *buf, int len)
{
    fwrite(buf, 1, len, stdout);
    fflush(stdout);
}

static int console_read(void *opaque, uint8_t *buf, int len)
{
    STDIODevice *s = opaque;
    int ret, i, j;
    uint8_t ch;

    if (len <= 0)
        return 0;
    ret = read(s->stdin_fd, buf, len);
    if (ret < 0)
        return 0;
    if (ret == 0)
        return 0; /* EOF: keep running (self-running init powers off the VM) */

    j = 0;
    for (i = 0; i < ret; i++) {
        ch = buf[i];
        if (s->console_esc_state) {
            s->console_esc_state = 0;
            switch (ch) {
            case 'x': printf("Terminated\n"); exit(0);
            case 1: goto output_char;
            default: break;
            }
        } else if (ch == 1) {
            s->console_esc_state = 1;
        } else {
        output_char:
            buf[j++] = ch;
        }
    }
    return j;
}

static void term_resize_handler(int sig)
{
    if (global_stdio_device)
        global_stdio_device->resize_pending = TRUE;
}

static void console_get_size(STDIODevice *s, int *pw, int *ph)
{
    struct winsize ws;
    int width = 80, height = 25;
    if (ioctl(s->stdin_fd, TIOCGWINSZ, &ws) == 0 && ws.ws_col >= 4 && ws.ws_row >= 4) {
        width = ws.ws_col;
        height = ws.ws_row;
    }
    *pw = width;
    *ph = height;
}

static CharacterDevice *console_init(BOOL allow_ctrlc)
{
    CharacterDevice *dev;
    STDIODevice *s;
    struct sigaction sig;

    term_init(allow_ctrlc);
    dev = mallocz(sizeof(*dev));
    s = mallocz(sizeof(*s));
    s->stdin_fd = 0;
    fcntl(s->stdin_fd, F_SETFL, O_NONBLOCK);
    s->resize_pending = TRUE;
    global_stdio_device = s;

    sig.sa_handler = term_resize_handler;
    sigemptyset(&sig.sa_mask);
    sig.sa_flags = 0;
    sigaction(SIGWINCH, &sig, NULL);

    dev->opaque = s;
    dev->write_data = console_write;
    dev->read_data = console_read;
    return dev;
}

/* ------------------------------------------------------------------ run loop */

#define MAX_EXEC_CYCLE  500000
#define MAX_SLEEP_TIME  10 /* ms */

static void tug_run(VirtMachine *m)
{
    fd_set rfds, wfds, efds;
    int fd_max, ret, delay, stdin_fd = -1;
    struct timeval tv;

    delay = virt_machine_get_sleep_duration(m, MAX_SLEEP_TIME);
    FD_ZERO(&rfds); FD_ZERO(&wfds); FD_ZERO(&efds);
    fd_max = -1;
    if (m->console_dev && virtio_console_can_write_data(m->console_dev)) {
        STDIODevice *s = m->console->opaque;
        stdin_fd = s->stdin_fd;
        FD_SET(stdin_fd, &rfds);
        fd_max = stdin_fd;
        if (s->resize_pending) {
            int w, h;
            console_get_size(s, &w, &h);
            virtio_console_resize_event(m->console_dev, w, h);
            s->resize_pending = FALSE;
        }
    }
    tv.tv_sec = delay / 1000;
    tv.tv_usec = (delay % 1000) * 1000;
    ret = select(fd_max + 1, &rfds, &wfds, &efds, &tv);
    if (ret > 0 && m->console_dev && FD_ISSET(stdin_fd, &rfds)) {
        uint8_t buf[128];
        int len = virtio_console_get_write_len(m->console_dev);
        len = min_int(len, (int)sizeof(buf));
        len = m->console->read_data(m->console->opaque, buf, len);
        if (len > 0)
            virtio_console_write_data(m->console_dev, buf, len);
    }
    virt_machine_interp(m, MAX_EXEC_CYCLE);
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

static void report_stats(void)
{
    struct timespec now;
    struct rusage ru;
    double secs;
    clock_gettime(CLOCK_MONOTONIC, &now);
    secs = (now.tv_sec - t_start.tv_sec) + (now.tv_nsec - t_start.tv_nsec) / 1e9;
    getrusage(RUSAGE_SELF, &ru);
    /* ru_maxrss is bytes on Darwin, KiB on Linux */
#if defined(__APPLE__)
    double rss_mb = ru.ru_maxrss / (1024.0 * 1024.0);
#else
    double rss_mb = ru.ru_maxrss / 1024.0;
#endif
    fprintf(stderr, "\n[tug] wall=%.3fs  peak_rss=%.1f MiB\n", secs, rss_mb);
}

/* ------------------------------------------------------------------ main */

int main(int argc, char **argv)
{
    VirtMachineParams params, *p = &params;
    VirtMachine *s;
    const char *cmdline = "console=hvc0";
    uint64_t ram_mb = 256;
    BOOL benchmark = FALSE;
    int c, len;

    while ((c = getopt(argc, argv, "m:a:b")) != -1) {
        switch (c) {
        case 'm': ram_mb = strtoull(optarg, NULL, 0); break;
        case 'a': cmdline = optarg; break;
        case 'b': benchmark = TRUE; break;
        default:
            fprintf(stderr, "usage: tug [-m MB] [-a cmdline] [-b] bbl.bin Image [initrd]\n");
            return 1;
        }
    }
    int nfiles = argc - optind;

    memset(p, 0, sizeof(*p));
    p->vmc = &riscv_machine_class;
    p->machine_name = strdup("riscv64");
    p->vmc->virt_machine_set_defaults(p);
    p->ram_size = ram_mb << 20;
    p->rtc_real_time = TRUE;

#ifdef TUG_EMBEDDED
    if (nfiles == 0) {
        /* self-contained: payload baked into the binary, no external files */
        p->files[VM_FILE_BIOS].buf   = (uint8_t *)tug_bbl_start;    p->files[VM_FILE_BIOS].len   = (int)(tug_bbl_end    - tug_bbl_start);
        p->files[VM_FILE_KERNEL].buf = (uint8_t *)tug_kernel_start; p->files[VM_FILE_KERNEL].len = (int)(tug_kernel_end - tug_kernel_start);
        p->files[VM_FILE_INITRD].buf = (uint8_t *)tug_initrd_start; p->files[VM_FILE_INITRD].len = (int)(tug_initrd_end - tug_initrd_start);
    } else
#endif
    if (nfiles >= 2) {
        p->files[VM_FILE_BIOS].buf   = load_file(argv[optind],   &len); p->files[VM_FILE_BIOS].len   = len;
        p->files[VM_FILE_KERNEL].buf = load_file(argv[optind+1], &len); p->files[VM_FILE_KERNEL].len = len;
        if (nfiles >= 3) {
            p->files[VM_FILE_INITRD].buf = load_file(argv[optind+2], &len);
            p->files[VM_FILE_INITRD].len = len;
        }
    } else {
        fprintf(stderr, "usage: tug [-m MB] [-a cmdline] [-b] bbl.bin Image [initrd]\n");
        return 1;
    }
    vm_add_cmdline(p, cmdline);
    p->console = console_init(TRUE);

    if (benchmark) {
        clock_gettime(CLOCK_MONOTONIC, &t_start);
        atexit(report_stats);
    }

    s = virt_machine_init(p);
    if (!s) { fprintf(stderr, "tug: virt_machine_init failed\n"); return 1; }

    for (;;)
        tug_run(s);
    /* not reached: guest power-off calls exit() inside the core */
    return 0;
}
