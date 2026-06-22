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
cd /root 2>/dev/null || cd /
SH=/bin/ash; [ -x /bin/bash ] && SH=/bin/bash
export SHELL="$SH"
exec setsid -c <>/dev/console >&0 2>&1 "$SH" -l
LOGIN
chmod +x "$R/sbin/tug-login"

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
