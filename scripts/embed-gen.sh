#!/usr/bin/env bash
# Build the embedded rootfs (mkroot fs + config/tug-init) and emit a Mach-O
# assembly file that .incbin's the bios, kernel and rootfs into the binary.
#
# args: <rootfs_fs_dir> <tug_init> <bbl_abs> <kernel_abs> <out_cpio_abs> <out_payload_s>
set -euo pipefail

ROOTFS_FS="${1:?}"; TUG_INIT="${2:?}"; BBL="${3:?}"; KERNEL="${4:?}"
OUT_CPIO="${5:?}"; OUT_S="${6:?}"

for f in "$BBL" "$KERNEL"; do
    [ -f "$f" ] || { echo "embed: missing $f (build the 6.x kernel — docs/kernel.md)"; exit 1; }
done

BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export PATH="$BREW/opt/cpio/bin:$BREW/opt/findutils/libexec/gnubin:$PATH"

# interactive rootfs = mkroot fs with our tug-init as /init
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp -a "$ROOTFS_FS"/. "$W"/
chmod -R u+w "$W"
cp "$TUG_INIT" "$W"/init && chmod +x "$W"/init
# rm -f first: toybox ships a `bash` symlink (usr/bin/bash -> toybox); cp onto it
# would follow the link and clobber the toybox binary itself.
if [ -n "${TUG_BASH:-}" ] && [ -f "$TUG_BASH" ]; then
    rm -f "$W"/usr/bin/bash && cp "$TUG_BASH" "$W"/usr/bin/bash && chmod 755 "$W"/usr/bin/bash
fi
if [ -n "${TUG_CURL:-}" ] && [ -f "$TUG_CURL" ]; then
    rm -f "$W"/usr/bin/curl && cp "$TUG_CURL" "$W"/usr/bin/curl && chmod 755 "$W"/usr/bin/curl
fi
if [ -n "${TUG_CACERT:-}" ] && [ -f "$TUG_CACERT" ]; then
    mkdir -p "$W"/etc/ssl/certs && cp "$TUG_CACERT" "$W"/etc/ssl/certs/ca-certificates.crt
fi
( cd "$W" && find . | cpio -o -H newc -R +0:+0 2>/dev/null | gzip ) > "$OUT_CPIO"

# Mach-O assembly: bake the three blobs into the read-only const section.
{
    echo '.section __TEXT,__const'
    for np in "tug_bbl:$BBL" "tug_kernel:$KERNEL" "tug_initrd:$OUT_CPIO"; do
        nm="${np%%:*}"; path="${np#*:}"
        printf '.balign 16\n.global _%s_start\n_%s_start:\n.incbin "%s"\n.global _%s_end\n_%s_end:\n' \
            "$nm" "$nm" "$path" "$nm" "$nm"
    done
} > "$OUT_S"

echo "embed: rootfs=$(du -h "$OUT_CPIO" | cut -f1)  asm=$OUT_S"
