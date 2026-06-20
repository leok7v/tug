#!/usr/bin/env bash
# Cross-compile a static riscv64-linux-musl bash for the guest rootfs.
# Output: vendors/bash-5.2/bash  (static rv64 ELF, stripped).
#
# args: <toolchain_dir> <vendor_dir>
set -euo pipefail

TC="${1:?usage: build-bash.sh <toolchain_dir> <vendor_dir>}"
VENDOR="${2:?missing vendor dir}"
VER=5.2
URL="https://ftp.gnu.org/gnu/bash/bash-$VER.tar.gz"
SRC="$VENDOR/bash-$VER"

export PATH="$TC/bin:$PATH"

if [ ! -x "$SRC/bash" ]; then
    [ -f "$VENDOR/bash-$VER.tar.gz" ] || curl -fsSLo "$VENDOR/bash-$VER.tar.gz" "$URL"
    rm -rf "$SRC" && tar xzf "$VENDOR/bash-$VER.tar.gz" -C "$VENDOR"

    # Cross-compile cache: skip bash's run-tests, use its bundled termcap (no
    # ncurses), and credit musl with the strto*/etc. functions.
    cat > "$SRC/config.cache" <<'EOF'
ac_cv_func_setvbuf_reversed=no
ac_cv_func_strcoll_works=yes
ac_cv_func_working_mktime=yes
ac_cv_func_mmap_fixed_mapped=yes
ac_cv_func_memcmp_working=yes
ac_cv_func_strtol=yes
ac_cv_func_strtoul=yes
ac_cv_func_strtoll=yes
ac_cv_func_strtoull=yes
ac_cv_func_strtoimax=yes
ac_cv_func_strtoumax=yes
ac_cv_func_strtod=yes
ac_cv_func_dprintf=yes
bash_cv_func_sigsetjmp=present
bash_cv_func_strcoll_broken=no
bash_cv_getcwd_malloc=yes
bash_cv_job_control_missing=present
bash_cv_printf_a_format=yes
bash_cv_sys_named_pipes=present
bash_cv_ulimit_maxfds=yes
bash_cv_under_sys_siglist=yes
bash_cv_unusable_rtsigs=no
bash_cv_wcwidth_broken=no
bash_cv_dev_stdin=present
bash_cv_dev_fd=standard
bash_cv_termcap_lib=gnutermcap
gt_cv_int_divbyzero_sigfpe=yes
ac_cv_c_long_double=yes
EOF

    ( cd "$SRC" && ./configure --host=riscv64-linux-musl --without-bash-malloc \
        --enable-static-link --cache-file=config.cache \
        CC=riscv64-linux-musl-gcc CC_FOR_BUILD=cc CFLAGS="-Os" )
    # bash ships its own strto* etc.; musl has them too -> first-definition wins.
    ( cd "$SRC" && make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" \
        STATIC_LD="-static -Wl,--allow-multiple-definition" )
    "$TC"/bin/riscv64-linux-musl-strip "$SRC/bash"
fi

echo "bash: $SRC/bash ($(du -h "$SRC/bash" | cut -f1), $(file "$SRC/bash" | grep -o 'RISC-V'))"
