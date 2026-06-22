#!/usr/bin/env bash
# Build the ARM64 "apk" initramfs for VZ: the Alpine aarch64 minirootfs + an
# /init that self-seeds an empty /dev/vda on first boot and switch_roots into it
# (persistent apk), plus the `essentials` toolchain installer + banner + login.
# Output: alpine-arm64-apk.cpio.gz
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SEED=/tmp/alpine-arm64.tar.gz
[ -f "$SEED" ] || curl -fSL -o "$SEED" https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-minirootfs-3.24.1-aarch64.tar.gz
rm -rf r && mkdir r && tar xzf "$SEED" -C r

# --- /init: mount + first-boot self-seed + switch_root ----------------------
cat > r/init <<'INIT'
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
chmod +x r/init

# --- /sbin/tug-login: bring up VZ NAT networking, then a login shell --------
mkdir -p r/sbin
cat > r/sbin/tug-login <<'LOGIN'
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
chmod +x r/sbin/tug-login

# --- banner (aarch64 / VZ) --------------------------------------------------
mkdir -p r/etc/profile.d
cat > r/etc/profile.d/tug.sh <<'BANNER'
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

# --- essentials + first-login hook (verbatim from config/tug-apk-init) -------
mkdir -p r/usr/local/bin
python3 - "$here/../../config/tug-apk-init" r <<'EX'
import re,sys
src=open(sys.argv[1]).read(); out=sys.argv[2]
def grab(name): 
    m=re.search(r'<<\'%s\'\n(.*?)\n%s\n'%(name,name), src, re.S); return m.group(1)
open(out+"/usr/local/bin/essentials","w").write(grab("ESS"))
open(out+"/etc/profile.d/zz-essentials.sh","w").write(grab("HOOK"))
EX
chmod +x r/usr/local/bin/essentials

(cd r && find . | cpio -o -H newc 2>/dev/null | gzip) > alpine-arm64-apk.cpio.gz
echo "built alpine-arm64-apk.cpio.gz ($(du -h alpine-arm64-apk.cpio.gz | cut -f1)), essentials=$(wc -l <r/usr/local/bin/essentials) lines"
