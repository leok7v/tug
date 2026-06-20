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
#include <netinet/in.h>

#include "cutils.h"
#include "iomem.h"
#include "virtio.h"
#include "machine.h"
#ifdef CONFIG_SLIRP
#include "slirp/libslirp.h"
#endif

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
    /* Ctrl-C escape: forward every ^C to the guest, but if the guest looks wedged
     * (N consecutive ^C, nothing else typed, within a short window) offer to
     * force-quit tug itself. A healthy guest gives a prompt back and the next
     * keystroke resets the count, so normal interrupts never kill tug. */
    int  ctrlc_count;
    BOOL ctrlc_armed;
    uint64_t ctrlc_last_ms;
} STDIODevice;

/* force-quit tug after this many consecutive ^C (the last one is the confirm) */
#define CTRLC_ARM_COUNT   3
#define CTRLC_WINDOW_MS   2000

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

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
            case 'x': printf("Terminated\r\n"); exit(0);
            case 1: goto output_char;
            default: break;
            }
        } else if (ch == 1) {
            s->console_esc_state = 1;
        } else if (ch == 3) {
            /* Ctrl-C: always forward to the guest so bash gets SIGINT. Track
             * consecutive presses to offer a force-quit if the guest is wedged. */
            uint64_t t = now_ms();
            if (t - s->ctrlc_last_ms > CTRLC_WINDOW_MS) {
                s->ctrlc_count = 0;
                s->ctrlc_armed = FALSE;
            }
            s->ctrlc_last_ms = t;
            if (s->ctrlc_armed) {
                fputs("\r\n[tug] terminated\r\n", stderr);
                exit(0);
            }
            buf[j++] = ch;                /* deliver this ^C to the guest */
            if (++s->ctrlc_count >= CTRLC_ARM_COUNT) {
                fputs("\r\n[tug] guest not responding to Ctrl-C? "
                      "press Ctrl-C again to quit tug (or Ctrl-A x).\r\n", stderr);
                fflush(stderr);
                s->ctrlc_armed = TRUE;
            }
        } else {
        output_char:
            s->ctrlc_count = 0;           /* any other key means progress */
            s->ctrlc_armed = FALSE;
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

/* --------------------------------------------------------------- slirp NAT */
#ifdef CONFIG_SLIRP
static Slirp *slirp_state;

static void slirp_write_packet(EthernetDevice *net, const uint8_t *buf, int len)
{
    slirp_input(net->opaque, buf, len);
}
/* called back by the slirp library — must be external symbols */
int slirp_can_output(void *opaque)
{
    EthernetDevice *net = opaque;
    return net->device_can_write_packet(net);
}
void slirp_output(void *opaque, const uint8_t *pkt, int pkt_len)
{
    EthernetDevice *net = opaque;
    net->device_write_packet(net, pkt, pkt_len);
}
static void slirp_select_fill1(EthernetDevice *net, int *pfd_max,
                               fd_set *rfds, fd_set *wfds, fd_set *efds, int *pdelay)
{
    slirp_select_fill(net->opaque, pfd_max, rfds, wfds, efds);
}
static void slirp_select_poll1(EthernetDevice *net,
                               fd_set *rfds, fd_set *wfds, fd_set *efds, int select_ret)
{
    slirp_select_poll(net->opaque, rfds, wfds, efds, (select_ret <= 0));
}
/* user-mode NAT: guest 10.0.2.15, gateway/host 10.0.2.2, DNS 10.0.2.3 */
static EthernetDevice *slirp_open(void)
{
    EthernetDevice *net = mallocz(sizeof(*net));
    struct in_addr net_addr = { .s_addr = htonl(0x0a000200) };
    struct in_addr mask     = { .s_addr = htonl(0xffffff00) };
    struct in_addr host     = { .s_addr = htonl(0x0a000202) };
    struct in_addr dhcp     = { .s_addr = htonl(0x0a00020f) };
    struct in_addr dns      = { .s_addr = htonl(0x0a000203) };
    slirp_state = slirp_init(0, net_addr, mask, host, NULL, "", NULL, dhcp, dns, net);
    net->mac_addr[0] = 0x02; net->mac_addr[1] = 0x00; net->mac_addr[2] = 0x00;
    net->mac_addr[3] = 0x00; net->mac_addr[4] = 0x00; net->mac_addr[5] = 0x01;
    net->opaque = slirp_state;
    net->write_packet = slirp_write_packet;
    net->select_fill  = slirp_select_fill1;
    net->select_poll  = slirp_select_poll1;
    return net;
}
#endif /* CONFIG_SLIRP */

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
#ifdef CONFIG_SLIRP
    if (m->net)
        m->net->select_fill(m->net, &fd_max, &rfds, &wfds, &efds, &delay);
#endif
    tv.tv_sec = delay / 1000;
    tv.tv_usec = (delay % 1000) * 1000;
    ret = select(fd_max + 1, &rfds, &wfds, &efds, &tv);
#ifdef CONFIG_SLIRP
    if (m->net)
        m->net->select_poll(m->net, &rfds, &wfds, &efds, ret);
#endif
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
    const char *cmdline = "console=hvc0 virtio_net.napi_tx=false";
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
    /* allow_ctrlc=FALSE: do NOT let the host tty turn ^C into SIGINT for tug.
     * ^C is forwarded to the guest (bash SIGINT); console_read handles the
     * force-quit escape (see CTRLC_ARM_COUNT). */
    p->console = console_init(FALSE);

#ifdef CONFIG_SLIRP
    /* user-mode NAT: guest reaches the Internet via the host, no privileges */
    p->tab_eth[0].driver = strdup("user");
    p->tab_eth[0].net = slirp_open();
    p->eth_count = p->tab_eth[0].net ? 1 : 0;
#endif

    if (benchmark) {
        clock_gettime(CLOCK_MONOTONIC, &t_start);
        atexit(report_stats);
    }

    s = virt_machine_init(p);
    if (!s) { fprintf(stderr, "tug: virt_machine_init failed\n"); return 1; }
    if (s->net)
        s->net->device_set_carrier(s->net, TRUE);

    for (;;)
        tug_run(s);
    /* not reached: guest power-off calls exit() inside the core */
    return 0;
}
