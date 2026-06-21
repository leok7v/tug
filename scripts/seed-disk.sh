#!/usr/bin/env bash
# Pre-seed a tug data disk for shipping: boot tug-embedded-apk against it once so
# its init extracts the Alpine userland onto /dev/vda + switch_roots, then power
# off cleanly. Leaves a populated, product-shaped disk (no toolchains installed,
# and the first-login "install essentials?" marker cleared so the end user is
# still asked on their first real boot).
#
# Usage: seed-disk.sh <tug-embedded-apk> <disk.img>
set -euo pipefail
BIN="${1:?usage: seed-disk.sh <tug-embedded-apk> <disk.img>}"
DISK="${2:?missing disk image}"
[ -x "$BIN" ]  || { echo "seed-disk: $BIN not built (make embed-apk)"; exit 1; }
[ -f "$DISK" ] || { echo "seed-disk: $DISK missing (make disk)"; exit 1; }

python3 - "$BIN" "$DISK" <<'PY'
import os, pty, select, sys, time
binp, disk = sys.argv[1], sys.argv[2]
m, s = pty.openpty()
pid = os.fork()
if pid == 0:
    os.setsid(); os.dup2(s, 0); os.dup2(s, 1); os.dup2(s, 2); os.close(m)
    os.execv(binp, [binp, "-d", disk]); os._exit(127)
os.close(s)
buf = bytearray()

def rd(t):
    r, _, _ = select.select([m], [], [], t)
    if r:
        try: return os.read(m, 8192)
        except OSError: return b""
    return b""

def wait_for(subs, maxt):
    end = time.time() + maxt
    while time.time() < end:
        d = rd(0.4)
        if d:
            buf.extend(d); sys.stdout.write(d.decode("latin1", "replace")); sys.stdout.flush()
        for sub in subs:
            if sub in bytes(buf): return sub
    return None

def send(b): os.write(m, b)

# 1) wait for the first-login essentials prompt or the shell prompt (NOT the
#    banner text, which contains "apk add" and would false-trigger).
hit = wait_for([b"Install these?", b"localhost:~#"], 300)
if hit is None:
    print("\nseed-disk: timed out before Alpine login", file=sys.stderr); os.kill(pid, 9); sys.exit(1)
# 2) decline the essentials prompt (we ship a base disk; the user is asked later)
if hit == b"Install these?":
    send(b"n\n")
    wait_for([b"localhost:~#"], 30)
time.sleep(1)
# 3) clear the "asked" marker (so the real user is still prompted) and power off
send(b"rm -f /root/.config/tug/essentials-asked; sync; poweroff -f\n")
wait_for([b"reboot: Power down", b"Power off"], 30)
time.sleep(1)
try: os.kill(pid, 9)
except Exception: pass
print("\nseed-disk: disk seeded and powered off cleanly")
PY
