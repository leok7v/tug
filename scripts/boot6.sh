#!/usr/bin/env bash
# Boot our own modern (6.x) kernel + toybox rootfs to an interactive shell on
# TinyEMU, using config/tug-init (TinyEMU-appropriate, no blocking NTP).
#
# Usage: boot6.sh <temu> <image_dir> <rootfs_dir> <tug_init> [test]
#   default mode = interactive; "test" mode feeds a marker + poweroff and asserts.
#
# The 6.x kernel (Image-c2w) is built per docs/kernel.md and must already exist
# in <image_dir>.
set -euo pipefail

TEMU="${1:?}"; IMG_DIR="${2:?}"; ROOTFS_DIR="${3:?}"; TUG_INIT="${4:?}"
MODE="${5:-interactive}"
KERNEL="$IMG_DIR/Image-c2w"

[ -f "$KERNEL" ] || { echo "missing $KERNEL — build the 6.x kernel first (docs/kernel.md)"; exit 1; }

# Need GNU cpio/find for the newc archive + -R ownership.
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export PATH="$BREW/opt/cpio/bin:$BREW/opt/findutils/libexec/gnubin:$PATH"

# Build an initramfs from the mkroot rootfs with our init as /init.
# Interactive mode uses config/tug-init (a setsid shell). Test mode uses a
# self-running init (driving an interactive shell over a pipe is unreliable;
# a human at a real terminal gets a proper shell from tug-init).
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp -a "$ROOTFS_DIR"/. "$WORK"/
chmod -R u+w "$WORK"
if [ -n "${TUG_BASH:-}" ] && [ -f "$TUG_BASH" ]; then
    cp "$TUG_BASH" "$WORK"/usr/bin/bash && chmod 755 "$WORK"/usr/bin/bash
fi
if [ -n "${TUG_CURL:-}" ] && [ -f "$TUG_CURL" ]; then
    cp "$TUG_CURL" "$WORK"/usr/bin/curl && chmod 755 "$WORK"/usr/bin/curl
fi
if [ -n "${TUG_CACERT:-}" ] && [ -f "$TUG_CACERT" ]; then
    mkdir -p "$WORK"/etc/ssl/certs && cp "$TUG_CACERT" "$WORK"/etc/ssl/certs/ca-certificates.crt
fi
if [ "$MODE" = test ]; then
    cat > "$WORK"/init <<'EOF'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
echo TUG6_SHELL_OK
uname -a
poweroff -f
EOF
else
    cp "$TUG_INIT" "$WORK"/init
fi
chmod +x "$WORK"/init
( cd "$WORK" && find . | cpio -o -H newc -R +0:+0 2>/dev/null | gzip > "$IMG_DIR/tug6.cpio.gz" )

cat > "$IMG_DIR/tug6.cfg" <<'EOF'
{
    version: 1, machine: "riscv64", memory_size: 256,
    bios: "bbl64.bin", kernel: "Image-c2w", initrd: "tug6.cpio.gz",
    cmdline: "console=hvc0 virtio_net.napi_tx=false",
    eth0: { driver: "user" },
}
EOF

cd "$IMG_DIR"
if [ "$MODE" = test ]; then
    LOG="$(mktemp -t tug6.XXXXXX)"; trap 'rm -rf "$WORK" "$LOG"' EXIT
    # Pipe stdin (the init self-runs) so backgrounded temu doesn't take SIGTTIN
    # from the terminal and stop.
    ( sleep 16 ) | "$TEMU" tug6.cfg >"$LOG" 2>&1 &
    P=$!; ( sleep 16; kill -9 "$P" 2>/dev/null ) & G=$!; disown "$G" 2>/dev/null || true
    wait "$P" 2>/dev/null || true; kill -9 "$G" 2>/dev/null || true
    grep -aE 'TUG6_SHELL_OK|riscv64 Toybox|6\.1' "$LOG" | sed 's/\r$//' || true
    if grep -aq TUG6_SHELL_OK "$LOG"; then
        echo "BOOT6: PASS — our 6.x kernel boots to a toybox shell on TinyEMU"
    else
        echo "BOOT6: FAIL"; tail -20 "$LOG"; exit 1
    fi
else
    echo "Booting our 6.x kernel to an interactive shell. Exit emulator: Ctrl-a x"
    exec "$TEMU" tug6.cfg
fi
