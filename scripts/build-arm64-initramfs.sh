#!/usr/bin/env bash
# Build the ARM64 "apk" initramfs for VZ: the Alpine aarch64 minirootfs + an
# /init that self-seeds an empty ext4 /dev/vda on first boot (tar-copies itself)
# and switch_roots into it, so apk persists — no separate seed tarball or
# host-side seeding. Bakes in the `essentials` toolchain installer + first-login
# offer (verbatim from config/tug-apk-init) and a VZ banner; udhcpc for VZ NAT.
# Output: generated/tug-arm64-apk.cpio.gz
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ALPINE_TGZ="${1:?usage: build-arm64-initramfs.sh <alpine-aarch64-minirootfs.tar.gz>}"
OUT="$REPO/generated/tug-arm64-apk.cpio.gz"
mkdir -p "$REPO/generated"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
R="$WORK/r"; mkdir -p "$R"
tar xzf "$ALPINE_TGZ" -C "$R"

cat > "$R/init" <<'INIT'
#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM=vt100
mount -t devtmpfs dev /dev 2>/dev/null
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sys /sys 2>/dev/null
NEWROOT=/mnt; mkdir -p "$NEWROOT"
[ -b /dev/vda ] && mount -t ext4 /dev/vda "$NEWROOT" 2>/dev/null
if ! grep -q " $NEWROOT " /proc/mounts 2>/dev/null; then
  printf '\n  tug: no /dev/vda — running RAM-only (apk will not persist)\n\n'
  exec /sbin/tug-login
fi
if [ ! -f "$NEWROOT/.tug-seeded" ]; then
  printf '\n  tug: first boot — seeding Alpine aarch64 onto /dev/vda ...\n'
  ( cd / && tar --exclude=./proc --exclude=./sys --exclude=./dev \
        --exclude=./mnt --exclude=./run --exclude=./tmp -cf - . ) \
    | ( cd "$NEWROOT" && tar -xf - ) && sync && : > "$NEWROOT/.tug-seeded"
  printf '  tug: seeded. apk is now persistent on /dev/vda.\n'
fi
# Refresh the tug control bits from the initramfs onto the disk every boot, so
# updates (login, the winsize agent, essentials, banner) apply even on an
# already-seeded disk — same idea as the riscv tug-apk-init.
mkdir -p "$NEWROOT/sbin" "$NEWROOT/usr/local/sbin" "$NEWROOT/usr/local/bin" "$NEWROOT/etc/profile.d"
for f in /sbin/tug-login /usr/local/sbin/tug-winsize /usr/local/bin/essentials \
         /etc/profile.d/tug.sh /etc/profile.d/zz-essentials.sh; do
  [ -e "$f" ] && cp "$f" "$NEWROOT$f" 2>/dev/null
done
chmod +x "$NEWROOT/sbin/tug-login" "$NEWROOT/usr/local/sbin/tug-winsize" \
         "$NEWROOT/usr/local/bin/essentials" 2>/dev/null
mkdir -p "$NEWROOT/dev" "$NEWROOT/proc" "$NEWROOT/sys" "$NEWROOT/tmp"
mount --move /dev  "$NEWROOT/dev"  2>/dev/null
mount --move /proc "$NEWROOT/proc" 2>/dev/null
mount --move /sys  "$NEWROOT/sys"  2>/dev/null
mount -t tmpfs tmpfs "$NEWROOT/tmp" 2>/dev/null
mkdir -p "$NEWROOT/dev/pts"; mount -t devpts devpts "$NEWROOT/dev/pts" 2>/dev/null
exec switch_root "$NEWROOT" /sbin/tug-login
INIT
chmod +x "$R/init"

mkdir -p "$R/sbin"
cat > "$R/sbin/tug-login" <<'LOGIN'
#!/bin/sh
export HOME=/root TERM=vt100 PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ip link set lo up 2>/dev/null; ip link set eth0 up 2>/dev/null
udhcpc -i eth0 -q -n >/dev/null 2>&1
[ -s /etc/resolv.conf ] || echo 'nameserver 1.1.1.1' > /etc/resolv.conf
[ -x /usr/local/sbin/tug-winsize ] && /usr/local/sbin/tug-winsize &  # host->guest resize
cd /root 2>/dev/null || cd /
SH=/bin/ash; [ -x /bin/bash ] && SH=/bin/bash
export SHELL="$SH"
# Use the real virtio tty /dev/hvc0 (not /dev/console, which doesn't support the
# winsize ioctls) so the host-driven resize agent can reflow this shell.
TTY=/dev/console; [ -c /dev/hvc0 ] && TTY=/dev/hvc0
exec setsid -c <>"$TTY" >&0 2>&1 "$SH" -l
LOGIN
chmod +x "$R/sbin/tug-login"

# tug-winsize: a tiny vsock agent so the host can convey the terminal size VZ's
# serial console can't. Listens on vsock port 5000; on "<cols> <rows>" it sets the
# winsize of /dev/console (SIGWINCH reflows the shell / vi). Built static for
# aarch64 with clang + the musl.cc sysroot (same as the kernel/bench).
REPO_TC="$REPO/vendors/aarch64-linux-musl-cross"
mkdir -p "$R/usr/local/sbin"
if [ -d "$REPO_TC" ]; then
  CLANG="$(brew --prefix llvm)/bin/clang"; LLD="$(brew --prefix lld)/bin/ld.lld"
  cat > "$WORK/winsize.c" <<'WS'
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <linux/vm_sockets.h>
int main(void) {
    int s = socket(AF_VSOCK, SOCK_STREAM, 0);
    struct sockaddr_vm a; memset(&a, 0, sizeof a);
    a.svm_family = AF_VSOCK; a.svm_cid = VMADDR_CID_ANY; a.svm_port = 5000;
    if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 4)) return 1;
    for (;;) {
        int c = accept(s, 0, 0); if (c < 0) continue;
        char b[64] = {0}; int n = read(c, b, sizeof b - 1); int cols = 0, rows = 0;
        if (n > 0 && sscanf(b, "%d %d", &cols, &rows) == 2 && cols > 0 && rows > 0) {
            struct winsize w; memset(&w, 0, sizeof w);
            w.ws_col = cols; w.ws_row = rows;
            int t = open("/dev/hvc0", O_RDWR | O_NOCTTY);   // the real shell tty
            if (t < 0) t = open("/dev/console", O_RDWR | O_NOCTTY);
            if (t >= 0) { ioctl(t, TIOCSWINSZ, &w); close(t); }
        }
        close(c);
    }
}
WS
  "$CLANG" --target=aarch64-linux-musl --sysroot="$REPO_TC/aarch64-linux-musl" \
    --gcc-toolchain="$REPO_TC" --ld-path="$LLD" -static -O2 \
    "$WORK/winsize.c" -o "$R/usr/local/sbin/tug-winsize"
  chmod +x "$R/usr/local/sbin/tug-winsize"
fi

mkdir -p "$R/etc/profile.d"
cat > "$R/etc/profile.d/tug.sh" <<'BANNER'
if [ -t 0 ]; then
  echo
  echo "  tug — Alpine $(. /etc/os-release 2>/dev/null; echo "$VERSION_ID") aarch64 on Apple Virtualization (HVF)"
  echo "  setup:    run 'essentials' to install the dev toolchain (build-base clang node python ...)"
  echo "  packages: apk update && apk add <pkg>   e.g.  build-base clang  nodejs npm  python3 py3-pip  cargo"
  echo "  storage:  persistent /  on /dev/vda ($(df -h / 2>/dev/null | awk 'NR==2{print $2}'))   scratch: /tmp"
  echo "  keys:     poweroff -> shutdown"
  echo
fi
BANNER

# essentials + first-login hook: verbatim from config/tug-apk-init (arch-agnostic).
mkdir -p "$R/usr/local/bin"
python3 - "$REPO/config/tug-apk-init" "$R" <<'EX'
import re, sys
src = open(sys.argv[1]).read(); out = sys.argv[2]
def grab(name): return re.search(r"<<'%s'\n(.*?)\n%s\n" % (name, name), src, re.S).group(1)
open(out + "/usr/local/bin/essentials", "w").write(grab("ESS"))
open(out + "/etc/profile.d/zz-essentials.sh", "w").write(grab("HOOK"))
EX
chmod +x "$R/usr/local/bin/essentials"

( cd "$R" && find . | cpio -o -H newc 2>/dev/null | gzip ) > "$OUT"
echo "initrd: generated/tug-arm64-apk.cpio.gz ($(du -h "$OUT" | cut -f1))"
