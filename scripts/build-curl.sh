#!/usr/bin/env bash
# Cross-compile a static riscv64 curl with mbedTLS (HTTPS) + the Mozilla CA bundle.
# Output: vendors/curl-build/curl/src/curl  and  vendors/curl-build/cacert.pem
#
# args: <toolchain_dir> <vendor_dir>
set -euo pipefail

TC="${1:?usage: build-curl.sh <toolchain_dir> <vendor_dir>}"
VENDOR="${2:?missing vendor dir}"
CROSS="$TC/bin/riscv64-linux-musl-"
export PATH="$TC/bin:$PATH"
J="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

OUT="$VENDOR/curl-build"; mkdir -p "$OUT"
MBEDVER=3.6.2
CURLVER=8.11.1
MBEDINST="$OUT/mbedtls-prefix"

# --- mbedTLS (static libs only) ---
if [ ! -f "$MBEDINST/lib/libmbedtls.a" ]; then
    [ -f "$VENDOR/mbedtls-$MBEDVER.tar.bz2" ] || \
      curl -fsSLo "$VENDOR/mbedtls-$MBEDVER.tar.bz2" \
        "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBEDVER/mbedtls-$MBEDVER.tar.bz2"
    rm -rf "$OUT/mbedtls" && mkdir -p "$OUT/mbedtls"
    tar xjf "$VENDOR/mbedtls-$MBEDVER.tar.bz2" -C "$OUT/mbedtls" --strip-components=1
    make -C "$OUT/mbedtls" lib CC="${CROSS}gcc" AR="${CROSS}ar" CFLAGS="-Os" -j"$J"
    mkdir -p "$MBEDINST/lib" "$MBEDINST/include"
    cp "$OUT"/mbedtls/library/*.a "$MBEDINST/lib/"
    cp -r "$OUT"/mbedtls/include/* "$MBEDINST/include/"
fi

# --- curl (static, mbedTLS backend, minimal features) ---
if [ ! -x "$OUT/curl/src/curl" ]; then
    [ -f "$VENDOR/curl-$CURLVER.tar.gz" ] || \
      curl -fsSLo "$VENDOR/curl-$CURLVER.tar.gz" "https://curl.se/download/curl-$CURLVER.tar.gz"
    rm -rf "$OUT/curl" && mkdir -p "$OUT/curl"
    tar xzf "$VENDOR/curl-$CURLVER.tar.gz" -C "$OUT/curl" --strip-components=1
    ( cd "$OUT/curl" && ./configure --host=riscv64-linux-musl \
        --with-mbedtls="$MBEDINST" \
        --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
        --disable-shared --enable-static \
        --disable-ldap --disable-ldaps --disable-docs --disable-manual \
        --without-libpsl --without-zlib --without-brotli --without-zstd \
        --without-nghttp2 --without-libidn2 \
        CC="${CROSS}gcc" CPPFLAGS="-I$MBEDINST/include" \
        LDFLAGS="-static -L$MBEDINST/lib" )
    make -C "$OUT/curl" -j"$J" LDFLAGS="-all-static -L$MBEDINST/lib"
    "${CROSS}strip" "$OUT/curl/src/curl"
fi

# --- Mozilla CA bundle ---
curl -fsSLo "$OUT/cacert.pem" https://curl.se/ca/cacert.pem

echo "curl: $OUT/curl/src/curl ($(du -h "$OUT/curl/src/curl" | cut -f1))"
echo "ca:   $OUT/cacert.pem ($(du -h "$OUT/cacert.pem" | cut -f1))"
"$TC"/bin/riscv64-linux-musl-readelf -h "$OUT/curl/src/curl" 2>/dev/null | grep -E 'Type|Machine'
