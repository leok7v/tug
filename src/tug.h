/*
 * tug.h — the tug RISC-V Linux sandbox as an embeddable C library.
 *
 * One engine, two front-ends: the `tug`/`tug-embedded`/`tug-embedded-apk` CLIs
 * (src/tug_main.c) and the Boat app (macOS + iOS) both link this. The library
 * never touches a terminal or exits the process: console bytes stream through
 * callbacks, input is fed in, and guest power-off returns from tug_run().
 *
 * Threading: run tug_run() on a dedicated thread. tug_input()/tug_resize()/
 * tug_stop() are safe to call from another thread. console_out / exited fire on
 * the tug_run() thread — marshal to your UI thread as needed.
 *
 * Single VM per process for now (guest power-off is tracked in one global).
 */
#ifndef TUG_H
#define TUG_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tug tug;            /* opaque engine handle */

/* The "vtable": how the engine streams back to the embedder. */
typedef struct {
    void *ctx;                                                   /* passed to every callback */
    void (*console_out)(void *ctx, const uint8_t *data, int len); /* guest console -> host  */
    void (*exited)(void *ctx, int status);                       /* guest powered off / stopped */
} tug_host;

/* A 127.0.0.1:host_port -> guest:guest_port TCP forward (e.g. 2222:22 for ssh). */
typedef struct { uint16_t host_port, guest_port; } tug_forward;

/* Settings: everything the CLI's -m/-a/-d/-S/-L flags do, declaratively. */
typedef struct {
    int         ram_mb;          /* guest RAM; 0 => default 256 */
    const char *cmdline;         /* kernel command line; NULL => default */
    const char *disk_path;       /* writable image -> virtio-block /dev/vda; NULL => none */
    const char *share_dir;       /* host dir shared at /mnt/share via 9p; NULL => none */
    tug_forward forwards[8];     /* host<->guest TCP forwards */
    int         nforwards;

    /* Boot payload as in-memory blobs (e.g. baked into the app/binary).
     * The buffers must outlive the tug instance; the engine only reads them. */
    const uint8_t *bios,  *kernel, *initrd;
    int            bios_len, kernel_len, initrd_len;
} tug_settings;

/* Create an engine from settings + host callbacks. Returns NULL on failure
 * (bad disk/share, missing payload). Does not start the VM. */
tug *tug_new(const tug_settings *settings, const tug_host *host);

/* Run the VM loop until the guest powers off or tug_stop() is called. Blocking;
 * call on a dedicated thread. Returns the exit status (0 = clean power-off). */
int  tug_run(tug *t);

/* Feed console input (keyboard bytes) to the guest. Thread-safe. */
void tug_input(tug *t, const uint8_t *data, int len);

/* Tell the guest the terminal size (columns x rows). Thread-safe. */
void tug_resize(tug *t, int cols, int rows);

/* Ask tug_run() to return as soon as possible. Thread-safe. */
void tug_stop(tug *t);

/* Destroy the engine (fsyncs the data disk). Call after tug_run() returns. */
void tug_free(tug *t);

#ifdef __cplusplus
}
#endif
#endif /* TUG_H */
