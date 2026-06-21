/*
 * tug.c — the tug RISC-V Linux sandbox as an embeddable C library (tug.h).
 *
 * This drives Bellard's TinyEMU core *programmatically* (no JSON config file):
 * it loads a bios (bbl), kernel (Image) and optional initrd from in-memory
 * blobs, wires the guest console to host callbacks, and runs. Two front-ends
 * link it: the tug/tug-embedded/tug-embedded-apk CLIs (src/tug_main.c) and the
 * Boat app (macOS + iOS).
 *
 * Unlike the old monolithic orchestrator, this never touches a terminal and
 * never exits the process: console bytes stream out through host->console_out,
 * input is fed in via tug_input(), and guest power-off returns from tug_run()
 * (via the patches/tinyemu-poweroff.patch hook) instead of calling exit().
 *
 * Single VM per process for now: the power-off hook is one global, so it routes
 * to the one live tug instance.
 *
 * The console glue / run loop / virtio-block backend are adapted from TinyEMU's
 * temu.c (MIT).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <fcntl.h>
#include <sys/file.h>   /* flock: guard the data disk against two tug instances */
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <netinet/in.h>

#include "tug.h"
#include "cutils.h"
#include "iomem.h"
#include "virtio.h"  /* also pulls in fs.h: fs_disk_init for the -S 9p share */
#include "machine.h"
#ifdef CONFIG_SLIRP
#include "slirp/libslirp.h"
#endif

/* Set by patches/tinyemu-poweroff.patch in riscv_machine.c. When non-NULL the
 * guest's shuthost request calls it instead of exit(0). */
extern void (*tug_poweroff_hook)(void);

#define TUG_SECTOR_SIZE 512
#define TUG_IN_RING     8192     /* host->guest input ring (bytes) */
#define MAX_EXEC_CYCLE  500000
#define MAX_SLEEP_TIME  10       /* ms: caps run-loop latency for tug_input/stop */

typedef struct {
    int fd;
    int64_t nb_sectors;
} TugBlockFile;

struct tug {
    VirtMachine  *vm;
    tug_host      host;
    tug_settings  cfg;             /* shallow copy; blob/string pointers must outlive us */

    /* host -> guest input ring (tug_input writes, run loop drains) */
    pthread_mutex_t in_mtx;
    uint8_t         in[TUG_IN_RING];
    int             in_head, in_tail;

    /* terminal size (tug_resize) */
    int   cols, rows;
    volatile int resize_pending;

    /* control / lifecycle */
    volatile int stop_flag;        /* tug_stop -> tug_run returns asap */
    volatile int powered_off;      /* guest shuthost -> tug_run returns */
    int          exit_status;

    int blk_fd;                    /* data-disk fd, fsync'd + closed in tug_free */
};

/* single live instance, for the global power-off hook */
static tug *g_current;

/* ----------------------------------------------------------- block device */
/* A read/write file-backed virtio-block device backing the persistent /dev/vda
 * data disk (Alpine apk userland). Raw pread/pwrite (NOT buffered stdio): random
 * block IO defeats a stdio buffer, and an fflush-per-write made seeding / apk
 * painfully slow. pwrite lands in the host page cache and is durable across a
 * normal exit; for crash durability we fsync once in tug_free. */

static int64_t tug_bf_get_sector_count(BlockDevice *bs)
{
    TugBlockFile *bf = bs->opaque;
    return bf->nb_sectors;
}

static int tug_bf_read_async(BlockDevice *bs, uint64_t sector_num, uint8_t *buf,
                             int n, BlockDeviceCompletionFunc *cb, void *opaque)
{
    TugBlockFile *bf = bs->opaque;
    size_t len = (size_t)n * TUG_SECTOR_SIZE;
    off_t off = (off_t)sector_num * TUG_SECTOR_SIZE;
    ssize_t r;
    if (bf->fd < 0 || n <= 0)
        return n <= 0 ? 0 : -1;
    r = pread(bf->fd, buf, len, off);
    if (r < 0)
        return -1;
    if ((size_t)r < len)           /* short read at a hole/EOF: zero the rest */
        memset(buf + r, 0, len - r);
    return 0; /* synchronous */
}

static int tug_bf_write_async(BlockDevice *bs, uint64_t sector_num,
                              const uint8_t *buf, int n,
                              BlockDeviceCompletionFunc *cb, void *opaque)
{
    TugBlockFile *bf = bs->opaque;
    size_t len = (size_t)n * TUG_SECTOR_SIZE;
    off_t off = (off_t)sector_num * TUG_SECTOR_SIZE;
    if (bf->fd < 0 || n <= 0)
        return n <= 0 ? 0 : -1;
    if (pwrite(bf->fd, buf, len, off) != (ssize_t)len)
        return -1;             /* no per-write flush: page cache + fsync at free */
    return 0; /* synchronous */
}

static BlockDevice *tug_block_device_init(tug *t, const char *filename)
{
    BlockDevice *bs;
    TugBlockFile *bf;
    int fd;
    off_t file_size;

    fd = open(filename, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "tug: cannot open data disk %s: %s\n",
                filename, strerror(errno));
        return NULL;
    }
    /* Exclusive advisory lock: two tug instances writing the same ext4 image
     * through independent guest filesystems would corrupt it (ext4 is not
     * cluster-aware). Released automatically when the fd closes / process exits. */
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
        fprintf(stderr, "tug: data disk %s is already in use by another tug "
                "instance (refusing to open it twice).\n", filename);
        close(fd);
        return NULL;
    }
    file_size = lseek(fd, 0, SEEK_END);

    bs = mallocz(sizeof(*bs));
    bf = mallocz(sizeof(*bf));
    bf->fd = fd;
    bf->nb_sectors = file_size / TUG_SECTOR_SIZE;
    bs->opaque = bf;
    bs->get_sector_count = tug_bf_get_sector_count;
    bs->read_async = tug_bf_read_async;
    bs->write_async = tug_bf_write_async;

    t->blk_fd = fd;
    return bs;
}

/* ------------------------------------------------------------------ console */

static void tug_console_write(void *opaque, const uint8_t *buf, int len)
{
    tug *t = opaque;
    if (t->host.console_out)
        t->host.console_out(t->host.ctx, buf, len);
}

/* drain queued input into the guest console (called from the run loop) */
static int tug_console_read(void *opaque, uint8_t *buf, int len)
{
    tug *t = opaque;
    int n = 0;
    if (len <= 0)
        return 0;
    pthread_mutex_lock(&t->in_mtx);
    while (n < len && t->in_head != t->in_tail) {
        buf[n++] = t->in[t->in_head];
        t->in_head = (t->in_head + 1) % TUG_IN_RING;
    }
    pthread_mutex_unlock(&t->in_mtx);
    return n;
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
static EthernetDevice *tug_slirp_open(tug *t)
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

    /* host_port:guest_port TCP forwards (e.g. 2222:22 for ssh). Bound to
     * 127.0.0.1 only — these never listen on the network. */
    {
        struct in_addr guest = { .s_addr = htonl(0x0a00020f) }; /* 10.0.2.15 */
        struct in_addr lo    = { .s_addr = htonl(0x7f000001) }; /* 127.0.0.1  */
        int i;
        for (i = 0; i < t->cfg.nforwards; i++) {
            int hp = t->cfg.forwards[i].host_port;
            int gp = t->cfg.forwards[i].guest_port;
            if (slirp_add_hostfwd(slirp_state, 0, lo, hp, guest, gp) < 0)
                fprintf(stderr, "tug: could not forward 127.0.0.1:%d -> guest:%d "
                        "(port in use?)\n", hp, gp);
            else
                fprintf(stderr, "tug: forwarding 127.0.0.1:%d -> guest:%d\n", hp, gp);
        }
    }
    return net;
}
#endif /* CONFIG_SLIRP */

/* ------------------------------------------------------------------ run loop */

static void tug_step(tug *t)
{
    VirtMachine *m = t->vm;
    fd_set rfds, wfds, efds;
    int fd_max, ret, delay;
    struct timeval tv;

    delay = virt_machine_get_sleep_duration(m, MAX_SLEEP_TIME);
    FD_ZERO(&rfds); FD_ZERO(&wfds); FD_ZERO(&efds);
    fd_max = -1;

    /* feed any queued input + apply a pending resize when the guest can take it */
    if (m->console_dev && virtio_console_can_write_data(m->console_dev)) {
        if (t->resize_pending) {
            virtio_console_resize_event(m->console_dev, t->cols, t->rows);
            t->resize_pending = 0;
        }
        uint8_t buf[128];
        int len = virtio_console_get_write_len(m->console_dev);
        len = min_int(len, (int)sizeof(buf));
        len = tug_console_read(t, buf, len);
        if (len > 0)
            virtio_console_write_data(m->console_dev, buf, len);
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
#else
    (void)ret;
#endif
    virt_machine_interp(m, MAX_EXEC_CYCLE);
}

/* ------------------------------------------------------------------ poweroff */

static void tug_on_poweroff(void)
{
    if (g_current) {
        g_current->powered_off = 1;
        g_current->exit_status = 0;
    }
}

/* ------------------------------------------------------------------ public API */

tug *tug_new(const tug_settings *settings, const tug_host *host)
{
    VirtMachineParams params, *p = &params;
    tug *t;

    if (!settings || !host || !settings->bios || !settings->kernel)
        return NULL;

    t = mallocz(sizeof(*t));
    t->host = *host;
    t->cfg  = *settings;
    pthread_mutex_init(&t->in_mtx, NULL);
    t->blk_fd = -1;
    t->cols = 80;
    t->rows = 25;
    t->resize_pending = 1;

    memset(p, 0, sizeof(*p));
    p->vmc = &riscv_machine_class;
    p->machine_name = strdup("riscv64");
    p->vmc->virt_machine_set_defaults(p);
    p->ram_size = (uint64_t)(settings->ram_mb > 0 ? settings->ram_mb : 256) << 20;
    p->rtc_real_time = TRUE;

    p->files[VM_FILE_BIOS].buf   = (uint8_t *)settings->bios;
    p->files[VM_FILE_BIOS].len   = settings->bios_len;
    p->files[VM_FILE_KERNEL].buf = (uint8_t *)settings->kernel;
    p->files[VM_FILE_KERNEL].len = settings->kernel_len;
    if (settings->initrd && settings->initrd_len > 0) {
        p->files[VM_FILE_INITRD].buf = (uint8_t *)settings->initrd;
        p->files[VM_FILE_INITRD].len = settings->initrd_len;
    }
    vm_add_cmdline(p, settings->cmdline ? settings->cmdline
                                        : "console=hvc0 virtio_net.napi_tx=false");

    /* console -> host callbacks (input is queued via tug_input) */
    {
        CharacterDevice *dev = mallocz(sizeof(*dev));
        dev->opaque = t;
        dev->write_data = tug_console_write;
        dev->read_data  = tug_console_read;
        p->console = dev;
    }

#ifdef CONFIG_SLIRP
    p->tab_eth[0].driver = strdup("user");
    p->tab_eth[0].net = tug_slirp_open(t);
    p->eth_count = p->tab_eth[0].net ? 1 : 0;
#endif

    /* -S host dir shared into the guest as a virtio-9p device (tag "tugshare") */
    if (settings->share_dir) {
        FSDevice *fs = fs_disk_init(settings->share_dir);
        if (!fs) {
            fprintf(stderr, "tug: share dir '%s' must be an existing directory\n",
                    settings->share_dir);
            free(t);
            return NULL;
        }
        p->tab_fs[0].fs_dev = fs;
        p->tab_fs[0].tag = strdup("tugshare");
        p->fs_count = 1;
    }

    /* persistent data disk -> virtio-block /dev/vda */
    if (settings->disk_path && settings->disk_path[0]) {
        BlockDevice *blk = tug_block_device_init(t, settings->disk_path);
        if (!blk) {
            free(t);
            return NULL;
        }
        p->tab_drive[0].block_dev = blk;
        p->drive_count = 1;
    }

    /* route guest power-off to us instead of exit() */
    g_current = t;
    tug_poweroff_hook = tug_on_poweroff;

    t->vm = virt_machine_init(p);
    if (!t->vm) {
        fprintf(stderr, "tug: virt_machine_init failed\n");
        g_current = NULL;
        tug_poweroff_hook = NULL;
        if (t->blk_fd >= 0) close(t->blk_fd);
        free(t);
        return NULL;
    }
    if (t->vm->net)
        t->vm->net->device_set_carrier(t->vm->net, TRUE);
    return t;
}

int tug_run(tug *t)
{
    if (!t)
        return -1;
    while (!t->powered_off && !t->stop_flag)
        tug_step(t);
    if (t->host.exited)
        t->host.exited(t->host.ctx, t->exit_status);
    return t->exit_status;
}

void tug_input(tug *t, const uint8_t *data, int len)
{
    int i;
    if (!t || !data || len <= 0)
        return;
    pthread_mutex_lock(&t->in_mtx);
    for (i = 0; i < len; i++) {
        int next = (t->in_tail + 1) % TUG_IN_RING;
        if (next == t->in_head)
            break;                 /* ring full: drop the rest */
        t->in[t->in_tail] = data[i];
        t->in_tail = next;
    }
    pthread_mutex_unlock(&t->in_mtx);
}

void tug_resize(tug *t, int cols, int rows)
{
    if (!t || cols < 4 || rows < 4)
        return;
    t->cols = cols;
    t->rows = rows;
    t->resize_pending = 1;
}

void tug_stop(tug *t)
{
    if (t)
        t->stop_flag = 1;
}

void tug_free(tug *t)
{
    if (!t)
        return;
    if (t->blk_fd >= 0) {
        fsync(t->blk_fd);
        close(t->blk_fd);
        t->blk_fd = -1;
    }
    if (g_current == t) {
        g_current = NULL;
        tug_poweroff_hook = NULL;
    }
    pthread_mutex_destroy(&t->in_mtx);
    free(t);
}
