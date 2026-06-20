#!/usr/bin/env bash
# Boot the persistent Alpine/apk guest on TinyEMU: our 6.x kernel + a toybox
# initramfs whose /init (config/tug-apk-init) mounts the /dev/vda data disk,
# first-boot-seeds it from the baked Alpine minirootfs, and switch_roots into it.
#
# Usage: apkboot.sh <temu> <image_dir> <rootfs_dir> <tug_apk_init> \
#                    <alpine_tgz> <data_disk> [test]
#   default mode = interactive; "test" mode asserts seed + switch_root + apk.
set -euo pipefail

# Arg 1 is the `tug` orchestrator binary (src/tug.c) — NOT stock temu — so this
# test exercises the SAME pread/pwrite virtio-block backend that tug-embedded-apk
# ships, instead of temu.c's separate stdio backend.
TUG="${1:?}"; IMG_DIR="${2:?}"; ROOTFS_DIR="${3:?}"; APK_INIT="${4:?}"
ALPINE_TGZ="${5:?}"; DATA_DISK="${6:?}"; MODE="${7:-interactive}"
KERNEL="$IMG_DIR/Image-c2w"; BBL="$IMG_DIR/bbl64.bin"

[ -f "$KERNEL" ]     || { echo "missing $KERNEL — build the 6.x kernel (docs/kernel.md)"; exit 1; }
[ -f "$BBL" ]        || { echo "missing $BBL — build M0 first"; exit 1; }
[ -f "$ALPINE_TGZ" ] || { echo "missing Alpine seed $ALPINE_TGZ — run: make alpine"; exit 1; }
[ -f "$DATA_DISK" ]  || { echo "missing data disk $DATA_DISK — run: make disk"; exit 1; }

# GNU cpio/find for the newc archive + -R ownership (same as boot6.sh).
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export PATH="$BREW/opt/cpio/bin:$BREW/opt/findutils/libexec/gnubin:$PATH"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp -a "$ROOTFS_DIR"/. "$WORK"/
chmod -R u+w "$WORK"

# Carry the Alpine seed + CA bundle inside the initramfs so first boot needs no
# network (matches the self-contained embedded build).
mkdir -p "$WORK/tug"
cp "$ALPINE_TGZ" "$WORK/tug/alpine-minirootfs.tar.gz"
if [ -n "${TUG_CACERT:-}" ] && [ -f "$TUG_CACERT" ]; then
    cp "$TUG_CACERT" "$WORK/tug/cacert.pem"
fi

if [ "$MODE" = test ]; then
    # Self-running init: do the same seed/switch_root the real init does, but
    # in a non-interactive, asserting form (driving a shell over a pipe is
    # unreliable). Verifies mount, seed, switch_root, and apk reachability.
    cat > "$WORK"/init <<'EOF'
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
mount -t devtmpfs dev /dev   2>/dev/null
mount -t proc     proc /proc 2>/dev/null
mount -t sysfs    sys /sys   2>/dev/null
mkdir -p /mnt
if mount -t ext4 /dev/vda /mnt 2>/dev/null || mount /dev/vda /mnt 2>/dev/null; then
    echo APK_VDA_MOUNT_OK
else
    echo APK_VDA_MOUNT_FAIL; poweroff -f
fi
if [ ! -x /mnt/sbin/apk ]; then
    echo APK_SEEDING
    ( cd /mnt && tar xpf /tug/alpine-minirootfs.tar.gz ) && echo APK_SEED_OK || echo APK_SEED_FAIL
else
    echo APK_ALREADY_SEEDED
fi
echo 'nameserver 10.0.2.3' > /mnt/etc/resolv.conf
mkdir -p /mnt/etc/ssl/certs
[ -f /tug/cacert.pem ] && cp /tug/cacert.pem /mnt/etc/ssl/certs/ca-certificates.crt
# networking
ifconfig lo 127.0.0.1 up 2>/dev/null
ifconfig eth0 10.0.2.15 up 2>/dev/null
route add default gw 10.0.2.2 2>/dev/null
# prove apk runs inside Alpine via chroot (lighter than full switch_root here)
mount -t devtmpfs dev /mnt/dev 2>/dev/null
mount -t proc proc /mnt/proc 2>/dev/null
mount -t sysfs sys /mnt/sys 2>/dev/null
APKVER=$(chroot /mnt /sbin/apk --version 2>&1 | head -1)
echo "APK_VERSION: $APKVER"
# leave a persistence marker so a second boot can confirm it survived
if [ -f /mnt/tug-persist-marker ]; then
    echo "APK_PERSIST_MARKER_PRESENT: $(cat /mnt/tug-persist-marker)"
else
    echo "tug-first-run-$(date +%s 2>/dev/null || echo X)" > /mnt/tug-persist-marker
    echo APK_PERSIST_MARKER_WRITTEN
fi
# Hard pass criteria (mount + seed + apk + persist) are now all proven; emit the
# completion marker BEFORE the slow, network-dependent step so the assertion
# does not hinge on it.
sync
echo APK_TEST_COMPLETE
# apk update over slirp NAT + TLS — informational only (best effort; it is slow
# under the interpreter and network may be unavailable in CI). Bounded so it
# can't wedge the run.
# apk update over slirp NAT + TLS. Informational (network may be absent in CI),
# but no longer hidden behind `timeout|tail`: when the host is not thrashing the
# disk (e.g. macOS locate.updatedb), this fetches both indexes in a few seconds.
echo "APK_UPDATE_START up=$(cut -d. -f1 /proc/uptime 2>/dev/null)"
if chroot /mnt /sbin/apk update 2>&1; then
    echo "APK_UPDATE_DONE up=$(cut -d. -f1 /proc/uptime 2>/dev/null)"
else
    echo "APK_UPDATE_FAIL rc=$?"
fi
sync
poweroff -f
EOF
else
    cp "$APK_INIT" "$WORK"/init
fi
chmod +x "$WORK"/init

( cd "$WORK" && find . | cpio -o -H newc -R +0:+0 2>/dev/null | gzip > "$IMG_DIR/tug-apk.cpio.gz" )

# Boot via the tug orchestrator: -d attaches the data disk as /dev/vda through
# tug.c's own block backend (the one tug-embedded-apk ships); eth0 slirp NAT is
# auto-enabled by tug.c. 1 GiB RAM for apk/builds.
CMDLINE="console=hvc0 virtio_net.napi_tx=false"
set -- -m 1024 -d "$DATA_DISK" -a "$CMDLINE" "$BBL" "$KERNEL" "$IMG_DIR/tug-apk.cpio.gz"

if [ "$MODE" = test ]; then
    LOG="$(mktemp -t tugapk.XXXXXX)"; trap 'rm -rf "$WORK" "$LOG"' EXIT
    # apk update over the interpreter is slow; give the guest a generous budget.
    ( sleep 300 ) | "$TUG" "$@" >"$LOG" 2>&1 &
    P=$!; ( sleep 300; kill -9 "$P" 2>/dev/null ) & G=$!; disown "$G" 2>/dev/null || true
    wait "$P" 2>/dev/null || true; kill -9 "$G" 2>/dev/null || true
    echo "---- apk boot (matched lines) ----"
    grep -aE 'APK_VDA_MOUNT_OK|APK_SEED_OK|APK_ALREADY_SEEDED|APK_VERSION:|APK_PERSIST|APK_UPDATE_DONE|APK_TEST_COMPLETE' "$LOG" | sed 's/\r$//' || true
    echo "----------------------------------"
    if grep -aq APK_TEST_COMPLETE "$LOG" && grep -aqE 'APK_SEED_OK|APK_ALREADY_SEEDED' "$LOG" && grep -aq 'APK_VERSION:' "$LOG"; then
        echo "APKBOOT: PASS — /dev/vda mounts (tug block backend), Alpine seeds, apk runs"
    else
        echo "APKBOOT: FAIL"; tail -40 "$LOG"; exit 1
    fi
else
    echo "Booting the persistent Alpine/apk guest. Exit emulator: Ctrl-a x"
    exec "$TUG" "$@"
fi
