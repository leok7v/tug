# tug — minimalist RISC-V sandbox
#
# Milestone 0 — TinyEMU bring-up:
#   vendor an unmodified TinyEMU + a stock riscv64 Linux image, build headless,
#   boot to a shell. (vendors / build)
#
# Milestone 1 — our own guest payload:
#   build a riscv64-linux-musl cross toolchain (musl-cross-make), install kernel
#   headers, cross-build toybox + bash/curl/busybox, assemble a rootfs with
#   mkroot, and boot it on our own 6.x kernel.
#   (toolchain / headers / rootfs / bash / curl / busyboxvi / boot6 / embed)
#
# Phase 4 — persistent Alpine apk userland on a virtio-block data disk:
#   (alpine / disk / apkboot / embed-apk)
#
# Third-party sources are downloaded/cloned into ./vendors/ (gitignored). macOS
# build portability for TinyEMU lives in ./compat/ shims; functional changes to
# the emulator live as patches in ./patches/ (applied on extract) — rdtime,
# fence.tso, rng-seed, rtc, timer. The guest-payload build needs a GNU userland
# on macOS — run `make deps` once (Homebrew GNU tools).
#
# NOTE: building our own *kernel* is deferred (see `make kernel` / docs/kernel.md).
# The shipped 6.x kernel (Image-c2w) is placed in vendors/diskimage/ per that doc;
# bbl64.bin comes from the stock diskimage tarball.

.DEFAULT_GOAL := help

VENDOR := vendors
COMPAT := $(CURDIR)/compat
UNAME_S := $(shell uname -s)
JOBS := $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

CURL := curl -fSL --retry 3
SHA  := shasum -a 256

# ---------------------------------------------------------------------------
# Milestone 0: TinyEMU + stock image
# ---------------------------------------------------------------------------
TINYEMU_VER := 2019-12-21
TINYEMU_URL := https://bellard.org/tinyemu/tinyemu-$(TINYEMU_VER).tar.gz
TINYEMU_SHA := be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555
TINYEMU_TGZ := $(VENDOR)/tinyemu-$(TINYEMU_VER).tar.gz
TINYEMU_DIR := $(VENDOR)/tinyemu
TEMU        := $(TINYEMU_DIR)/temu

IMAGE_VER := 2018-09-23
IMAGE_URL := https://bellard.org/tinyemu/diskimage-linux-riscv-$(IMAGE_VER).tar.gz
IMAGE_SHA := 808ecc1b32efdd76103172129b77b46002a616dff2270664207c291e4fde9e14
IMAGE_TGZ := $(VENDOR)/diskimage-linux-riscv-$(IMAGE_VER).tar.gz
IMAGE_DIR := $(VENDOR)/diskimage
CFG       := root-riscv64.cfg

# ---------------------------------------------------------------------------
# apk integration: Alpine riscv64 minirootfs (seed) + persistent data disk
# ---------------------------------------------------------------------------
# Alpine 3.24 is the first stable release with an official riscv64 port. The
# minirootfs is fully self-contained (ships /sbin/apk, /etc/apk/keys, the musl
# loader, a CA bundle and a correct /etc/apk/repositories), so seeding the data
# disk is just "extract the tarball". apk then reaches dl-cdn over slirp NAT.
ALPINE_REL  := 3.24
ALPINE_VER  := 3.24.1
ALPINE_URL  := https://dl-cdn.alpinelinux.org/alpine/v$(ALPINE_REL)/releases/riscv64/alpine-minirootfs-$(ALPINE_VER)-riscv64.tar.gz
ALPINE_SHA  := 7201513262d851f39105102cf95519410100259bd7996fca13bade517838d7b7
ALPINE_TGZ  := $(VENDOR)/alpine-minirootfs-$(ALPINE_VER)-riscv64.tar.gz

# Persistent writable data disk (becomes the Alpine / after switch_root). Raw
# ext4, created sparse so the host file only consumes used blocks; a high
# bytes-per-inode keeps an empty 32G fs from preallocating gigabytes of inodes.
# Override size at the command line, e.g.  make disk DISK_SIZE=64G
DISK_SIZE   ?= 32G
DATA_DISK   := tug-data.img

# ---------------------------------------------------------------------------
# ARM64 (macOS / Apple Virtualization, HVF) — our own arm64 kernel + Alpine
# aarch64. macOS runs the guest hardware-virtualized (~12x the riscv interpreter,
# measured in mac/vz-spike). Built natively on macOS with clang/lld (LLVM=1; the
# only arm64-Linux compiler that runs here) + a musl.cc aarch64 sysroot.
LINUX_ARM_VER   ?= 6.12
ALPINE_ARM_URL  := https://dl-cdn.alpinelinux.org/alpine/v$(ALPINE_REL)/releases/aarch64/alpine-minirootfs-$(ALPINE_VER)-aarch64.tar.gz
ALPINE_ARM_SHA  := f55a90f69052c5bd6f92cb09a8f47065970830b194c917a006fb94028e721259
ALPINE_ARM_TGZ  := $(VENDOR)/alpine-minirootfs-$(ALPINE_VER)-aarch64.tar.gz
AARCH64_CROSS   := $(VENDOR)/aarch64-linux-musl-cross
KERNEL_ARM      := $(IMAGE_DIR)/Image-arm64
INITRD_ARM      := generated/tug-arm64-apk.cpio.gz
DATA_ARM_SPARSE := generated/data-arm64.sparse

TEMU_CONFIG := CONFIG_FS_NET= CONFIG_SDL= CONFIG_X86EMU= CONFIG_INT128=
ifeq ($(UNAME_S),Darwin)
TEMU_CC   := cc -I$(COMPAT) -include $(COMPAT)/darwin_compat.h
TEMU_LIBS :=
else
TEMU_CC   := cc
TEMU_LIBS := -lrt
endif

# ---------------------------------------------------------------------------
# Milestone 1: guest payload toolchain + build env
# ---------------------------------------------------------------------------
TC      := $(CURDIR)/$(VENDOR)/toolchain
CROSS   := $(TC)/bin/riscv64-linux-musl-
TC_GCC  := $(TC)/bin/riscv64-linux-musl-gcc
SYSROOT := $(TC)/riscv64-linux-musl
GCC_VER := 13.3.0

MCM_DIR    := $(VENDOR)/musl-cross-make
TOYBOX_DIR := $(VENDOR)/toybox

ROOTFS_DIR := $(TOYBOX_DIR)/root/riscv64
INITRAMFS  := $(ROOTFS_DIR)/initramfs.cpio.gz
HEADERS    := $(SYSROOT)/include/linux/fs.h

# The guest-payload build (toybox/mkroot) assumes a GNU userland. On macOS,
# prepend Homebrew's GNU tools (run `make deps` to install them). On Linux the
# native tools already satisfy this.
ifeq ($(UNAME_S),Darwin)
BREW    := $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)
GNUBIN  := $(BREW)/opt/make/libexec/gnubin:$(BREW)/opt/bison/bin:$(BREW)/opt/flex/bin:$(BREW)/opt/cpio/bin:$(BREW)/opt/findutils/libexec/gnubin:$(BREW)/opt/coreutils/libexec/gnubin:$(BREW)/opt/gnu-sed/libexec/gnubin:$(BREW)/opt/gawk/libexec/gnubin:$(BREW)/bin
GNUENV  := PATH="$(GNUBIN):$$PATH"
MKE2FS  := $(BREW)/opt/e2fsprogs/sbin/mke2fs
else
GNUENV  :=
MKE2FS  := mke2fs
endif

.PHONY: aarch64-toolchain kernel-arm64 alpine-arm64 initrd-arm64 disk-arm64 arm64 \
        help deps vendors build \
        toolchain headers rootfs boot6 orchestrator embed bash curl busyboxvi kernel \
        alpine disk disk-seeded apkboot embed-apk \
        clean distclean

help:
	@echo "tug — minimalist RISC-V sandbox"
	@echo
	@echo "Milestone 0 — TinyEMU bring-up:"
	@echo "  make vendors    download + checksum TinyEMU source and stock riscv64 image"
	@echo "  make build      compile headless temu ($(UNAME_S))"
	@echo
	@echo "Milestone 1 — our guest payload:"
	@echo "  make deps       (macOS) brew-install the GNU build userland"
	@echo "  make toolchain  build riscv64-linux-musl cross gcc (musl-cross-make) [~20-40 min]"
	@echo "  make headers    install riscv kernel headers into the sysroot"
	@echo "  make rootfs     build the toybox rootfs + initramfs.cpio.gz (mkroot)"
	@echo "  make boot6      boot our own 6.x kernel to a shell (MODE=test to assert)"
	@echo "  make orchestrator  build ./tug, the standalone programmatic emulator"
	@echo "  make embed      build ./tug-embedded, self-contained (payload baked in)"
	@echo "  make bash       cross-build static riscv64 bash for the guest shell"
	@echo "  make curl       cross-build static riscv64 curl+mbedTLS (HTTPS) + CA bundle"
	@echo "  make busyboxvi  cross-build static riscv64 busybox vi (replaces buggy toybox vi)"
	@echo "  make kernel     (deferred) notes on building our own kernel"
	@echo
	@echo "apk / persistent Alpine userland:"
	@echo "  make alpine     vendor the Alpine $(ALPINE_VER) riscv64 minirootfs (apk seed)"
	@echo "  make disk       create a sparse $(DISK_SIZE) ext4 data disk ($(DATA_DISK)); DISK_SIZE= to override (rebuild ERASES it)"
	@echo "  make apkboot    boot the Alpine guest (seeds /dev/vda on first run); MODE=test to assert"
	@echo "  make embed-apk  self-contained ./tug-embedded-apk (Alpine seed baked in)"
	@echo
	@echo "ARM64 (macOS / Apple Virtualization — the HVF backend for Boat.app):"
	@echo "  make arm64      build the arm64 payload (our kernel + Alpine apk initramfs + disk)"
	@echo "                  -> then  make -C mac payload && make -C mac mac"
	@echo "  (sub-targets: aarch64-toolchain kernel-arm64 alpine-arm64 initrd-arm64 disk-arm64)"
	@echo
	@echo "  make clean / distclean"

# ---------------------------------------------------------------------------
# Milestone 0 targets
# ---------------------------------------------------------------------------
vendors: $(TINYEMU_TGZ) $(IMAGE_TGZ)

$(TINYEMU_TGZ):
	@mkdir -p $(VENDOR)
	$(CURL) -o $@ $(TINYEMU_URL)
	@echo "$(TINYEMU_SHA)  $@" | $(SHA) -c -

$(IMAGE_TGZ):
	@mkdir -p $(VENDOR)
	$(CURL) -o $@ $(IMAGE_URL)
	@echo "$(IMAGE_SHA)  $@" | $(SHA) -c -

build: $(TEMU)

$(TEMU): $(TINYEMU_TGZ) $(wildcard patches/tinyemu-*.patch)
	rm -rf $(TINYEMU_DIR) && mkdir -p $(TINYEMU_DIR)
	tar xzf $(TINYEMU_TGZ) -C $(TINYEMU_DIR) --strip-components=1
	@for p in $(CURDIR)/patches/tinyemu-*.patch; do \
	  echo "applying $$p"; patch -d $(TINYEMU_DIR) -p1 < "$$p" || exit 1; done
	$(MAKE) -C $(TINYEMU_DIR) temu CC='$(TEMU_CC)' $(TEMU_CONFIG) EMU_LIBS='$(TEMU_LIBS)'
	@echo "built: $(TEMU)"

# Extract the stock diskimage tarball — kept solely for bbl64.bin (the BIOS our
# 6.x boot uses); the stock 4.15 kernel + cfg come with it. NOT wiped on re-run
# so a manually-built Image-c2w (docs/kernel.md) placed here is preserved.
$(IMAGE_DIR)/$(CFG): $(IMAGE_TGZ)
	@mkdir -p $(IMAGE_DIR)
	tar xzf $(IMAGE_TGZ) -C $(IMAGE_DIR) --strip-components=1
	@touch $@   # tar restores 2018 mtimes; bump so make doesn't re-extract forever

# (the old `smoke` target booted the stock 4.15 image; obsolete now that
#  `make boot6 MODE=test` / `make apkboot MODE=test` assert our own 6.x stack.)

# ---------------------------------------------------------------------------
# Milestone 1 targets
# ---------------------------------------------------------------------------
deps:
ifeq ($(UNAME_S),Darwin)
	brew install coreutils gnu-sed gawk bash findutils cpio make bison flex e2fsprogs wget
	@echo "GNU build userland installed."
else
	@echo "Linux host: ensure build-essential, bison, flex, bc, libelf, e2fsprogs are installed."
endif

toolchain: $(TC_GCC)

# musl-cross-make: a riscv64-linux-musl gcc that runs natively on the build host.
# GCC 13.3 (mcm default 9.4 fails to build with clang on Apple Silicon).
# --with-system-zlib avoids the macOS zlib zutil.h/TARGET_OS_MAC fdopen bug.
$(TC_GCC):
	@command -v sha1sum >/dev/null 2>&1 || { echo "need sha1sum + wget (make deps)"; exit 1; }
	test -d $(MCM_DIR) || git clone --depth 1 https://github.com/richfelker/musl-cross-make.git $(MCM_DIR)
	printf 'TARGET = riscv64-linux-musl\nOUTPUT = $(TC)\nGCC_VER = $(GCC_VER)\nCOMMON_CONFIG += --disable-nls\nBINUTILS_CONFIG += --with-system-zlib --disable-gprofng\nGCC_CONFIG += --enable-languages=c --disable-libquadmath --disable-libgomp --with-system-zlib\n' > $(MCM_DIR)/config.mak
	cd $(MCM_DIR) && $(GNUENV) $(MAKE) -j$(JOBS) && $(GNUENV) $(MAKE) install
	@echo "toolchain: $(TC_GCC)"

headers: $(HEADERS)

# Install sanitized riscv kernel headers (musl-cross-make ships the package).
$(HEADERS): $(TC_GCC)
	cd $(MCM_DIR) && hdr=`ls -d linux-headers-*/ | head -1` && \
	  $(GNUENV) $(MAKE) -C "$$hdr" ARCH=riscv prefix= DESTDIR=$(SYSROOT) install
	@echo "installed riscv kernel headers into $(SYSROOT)/include"

rootfs: $(INITRAMFS)

# mkroot builds toybox (static rv64) and assembles a root filesystem + initramfs.
# NOCLEAR=1 keeps our env across mkroot's self-reexec; NOAIRLOCK=1 skips building
# a host toybox (toybox-on-macOS-as-host is unreliable). LDOPTIMIZE overrides the
# uname=Darwin -dead_strip default; the GNU PATH supplies sed/awk/od/find/cpio.
$(INITRAMFS): $(TC_GCC) $(HEADERS)
	test -d $(TOYBOX_DIR) || git clone --depth 1 https://github.com/landley/toybox.git $(TOYBOX_DIR)
	cd $(TOYBOX_DIR) && \
	  NOCLEAR=1 NOAIRLOCK=1 CROSS_COMPILE="$(CROSS)" PENDING="VI" \
	  LDOPTIMIZE='-Wl,--gc-sections -Wl,--as-needed' STRIP=strip \
	  $(GNUENV) bash mkroot/mkroot.sh
	@echo "rootfs: $(INITRAMFS)"

# Boot our OWN 6.x kernel (built per docs/kernel.md -> $(IMAGE_DIR)/Image-c2w) to
# an interactive shell with config/tug-init. `make boot6 MODE=test` to assert.
MODE ?= interactive
boot6: $(TEMU) $(INITRAMFS) $(IMAGE_DIR)/$(CFG)
	@TUG_BASH="$(CURDIR)/$(BASH_BIN)" TUG_CURL="$(CURDIR)/$(CURL_BIN)" TUG_CACERT="$(CURDIR)/$(CACERT)" bash scripts/boot6.sh "$(CURDIR)/$(TEMU)" "$(CURDIR)/$(IMAGE_DIR)" \
	  "$(CURDIR)/$(ROOTFS_DIR)/fs" "$(CURDIR)/config/tug-init" $(MODE)

# Phase 2: a standalone pure-C orchestrator (src/tug.c) that drives the TinyEMU
# core programmatically (no JSON config). Links the core objects built for temu,
# minus Bellard's temu.o (its own main) and slirp (host net callbacks live in
# temu.c). Usage: ./tug [-m MB] [-a cmdline] [-b] <bbl> <Image> [initrd]
# The engine lives in src/tug.c (the embeddable library, tug.h); src/tug_main.c
# is the CLI front-end. All three binaries link both.
TUG_SRC := src/tug.c src/tug_main.c
TUG_HDR := src/tug.h
TUG_BIN := tug
orchestrator: $(TUG_BIN)
$(TUG_BIN): $(TUG_SRC) $(TUG_HDR) $(TEMU)
	$(TEMU_CC) -I$(TINYEMU_DIR) -Isrc -O2 -g -DCONFIG_SLIRP -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE \
	  -D_GNU_SOURCE -DCONFIG_RISCV_MAX_XLEN=64 $(TUG_SRC) \
	  `ls $(TINYEMU_DIR)/*.o | grep -v '/temu\.o$$'` $(TINYEMU_DIR)/slirp/*.o $(TEMU_LIBS) -o $@
	@echo "built orchestrator: $@  (./tug -b <bbl> <Image> [initrd] to benchmark)"

# Self-contained build: bake bios + our 6.x kernel + an interactive rootfs into
# the binary via .incbin (no external files) — the iOS-app-bundle shape.
KERNEL6      := $(IMAGE_DIR)/Image-c2w
BBL_BIN      := $(IMAGE_DIR)/bbl64.bin
BASH_BIN     := $(VENDOR)/bash-5.2/bash
CURL_BIN     := $(VENDOR)/curl-build/curl/src/curl
CACERT       := $(VENDOR)/curl-build/cacert.pem
BUSYBOX_BIN  := $(VENDOR)/busybox-1.36.1/busybox
EMBED_BIN    := tug-embedded
EMBED_INITRD := generated/tug-embed.cpio.gz
EMBED_S      := generated/payload.s

# apk variant of the self-contained binary: bakes the Alpine seed + tug-apk-init
# into the initramfs. Boots and (first run) seeds /dev/vda — auto-detected as
# tug-data.img next to the binary, or $TUG_DISK, or `-d`.
EMBED_APK_BIN    := tug-embedded-apk
EMBED_APK_INITRD := generated/tug-embed-apk.cpio.gz
EMBED_APK_S      := generated/payload-apk.s

# bash for the guest: static riscv64-linux-musl, gives the shell line editing
# (arrows/history/completion) that toybox's pending sh lacks.
bash: $(BASH_BIN)
$(BASH_BIN): $(TC_GCC)
	bash scripts/build-bash.sh "$(TC)" "$(CURDIR)/$(VENDOR)"

# curl + libcurl (mbedTLS, HTTPS) static for the guest, + Mozilla CA bundle.
curl: $(CURL_BIN)
$(CURL_BIN): $(TC_GCC)
	bash scripts/build-curl.sh "$(TC)" "$(CURDIR)/$(VENDOR)"

# busybox built with just vi (toybox's pending vi is buggy); overlaid as /usr/bin/vi.
busyboxvi: $(BUSYBOX_BIN)
$(BUSYBOX_BIN): $(TC_GCC)
	bash scripts/build-busybox.sh "$(TC)" "$(CURDIR)/$(VENDOR)"

embed: $(EMBED_BIN)
$(EMBED_BIN): $(TUG_SRC) $(TUG_HDR) $(TEMU) $(INITRAMFS) config/tug-init $(BASH_BIN) $(CURL_BIN) $(BUSYBOX_BIN)
	@mkdir -p generated
	TUG_BASH="$(CURDIR)/$(BASH_BIN)" TUG_CURL="$(CURDIR)/$(CURL_BIN)" TUG_CACERT="$(CURDIR)/$(CACERT)" \
	  TUG_BUSYBOX="$(CURDIR)/$(BUSYBOX_BIN)" \
	  bash scripts/embed-gen.sh "$(CURDIR)/$(ROOTFS_DIR)/fs" "$(CURDIR)/config/tug-init" \
	  "$(CURDIR)/$(BBL_BIN)" "$(CURDIR)/$(KERNEL6)" "$(CURDIR)/$(EMBED_INITRD)" "$(CURDIR)/$(EMBED_S)"
	$(TEMU_CC) -I$(TINYEMU_DIR) -Isrc -O2 -DTUG_EMBEDDED -DCONFIG_SLIRP -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE \
	  -D_GNU_SOURCE -DCONFIG_RISCV_MAX_XLEN=64 $(TUG_SRC) $(EMBED_S) \
	  `ls $(TINYEMU_DIR)/*.o | grep -v '/temu\.o$$'` $(TINYEMU_DIR)/slirp/*.o $(TEMU_LIBS) -o $@
	@echo "built self-contained $@ (`du -h $@ | cut -f1`) — run: ./$@  (no args)"

# Self-contained apk build: like `embed`, but bakes the Alpine seed + apk-init.
# Run `make disk` once, then ./tug-embedded-apk auto-attaches ./tug-data.img.
embed-apk: $(EMBED_APK_BIN)
$(EMBED_APK_BIN): $(TUG_SRC) $(TUG_HDR) $(TEMU) $(INITRAMFS) config/tug-apk-init $(CURL_BIN) $(BUSYBOX_BIN) $(ALPINE_TGZ) $(BBL_BIN) $(KERNEL6)
	@mkdir -p generated
	TUG_CURL="$(CURDIR)/$(CURL_BIN)" TUG_CACERT="$(CURDIR)/$(CACERT)" \
	  TUG_BUSYBOX="$(CURDIR)/$(BUSYBOX_BIN)" TUG_ALPINE_SEED="$(CURDIR)/$(ALPINE_TGZ)" \
	  bash scripts/embed-gen.sh "$(CURDIR)/$(ROOTFS_DIR)/fs" "$(CURDIR)/config/tug-apk-init" \
	  "$(CURDIR)/$(BBL_BIN)" "$(CURDIR)/$(KERNEL6)" "$(CURDIR)/$(EMBED_APK_INITRD)" "$(CURDIR)/$(EMBED_APK_S)"
	$(TEMU_CC) -I$(TINYEMU_DIR) -Isrc -O2 -DTUG_EMBEDDED -DCONFIG_SLIRP -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE \
	  -D_GNU_SOURCE -DCONFIG_RISCV_MAX_XLEN=64 $(TUG_SRC) $(EMBED_APK_S) \
	  `ls $(TINYEMU_DIR)/*.o | grep -v '/temu\.o$$'` $(TINYEMU_DIR)/slirp/*.o $(TEMU_LIBS) -o $@
	@echo "built self-contained $@ (`du -h $@ | cut -f1`) — run: make disk && ./$@"

# ---------------------------------------------------------------------------
# apk integration
# ---------------------------------------------------------------------------
alpine: $(ALPINE_TGZ)

$(ALPINE_TGZ):
	@mkdir -p $(VENDOR)
	$(CURL) -o $@ $(ALPINE_URL)
	@echo "$(ALPINE_SHA)  $@" | $(SHA) -c -
	@echo "alpine minirootfs: $@"

# Sparse raw ext4 data disk. truncate makes a sparse file of the full size;
# mke2fs -E nodiscard,lazy_itable_init writes only metadata so the host file
# stays small. -i 65536 (bytes/inode) caps inode preallocation; -m 0 leaves no
# reserved-root blocks (this is a data disk, not the host's /). The guest seeds
# it on first boot — we only format here.
disk: $(DATA_DISK)
$(DATA_DISK):
	rm -f $@
	truncate -s $(DISK_SIZE) $@
	$(MKE2FS) -q -t ext4 -L tugdata -m 0 -i 65536 \
	  -E nodiscard,lazy_itable_init=1,lazy_journal_init=1 -F $@
	@echo "data disk: $@  ($(DISK_SIZE) sparse, on-disk `du -h $@ | cut -f1`)"

# A *pre-seeded* disk for shipping (e.g. bundling into the Boat app): a fresh disk
# booted once through tug-embedded-apk so its init extracts the Alpine userland,
# then powered off. Separate file ($(SEED_DISK), default tug-seed.img) so it never
# clobbers a working tug-data.img. No toolchains installed; the first-boot
# "install essentials?" prompt is preserved for the end user.
SEED_DISK ?= tug-seed.img
disk-seeded: $(SEED_DISK)
$(SEED_DISK): $(EMBED_APK_BIN)
	rm -f $@
	truncate -s $(DISK_SIZE) $@
	$(MKE2FS) -q -t ext4 -L tugdata -m 0 -i 65536 \
	  -E nodiscard,lazy_itable_init=1,lazy_journal_init=1 -F $@
	bash scripts/seed-disk.sh "$(CURDIR)/$(EMBED_APK_BIN)" "$(CURDIR)/$@"
	@echo "seeded disk: $@  (on-disk `du -h $@ | cut -f1`)"

# Boot the persistent Alpine guest: our 6.x kernel + a tiny initramfs that
# mounts /dev/vda, first-boot-seeds it from the baked Alpine minirootfs, then
# switch_roots into it and drops to a shell with apk available.
# MODE=test runs a self-checking init (mounts, seeds, apk update, poweroff).
# Boots via the tug orchestrator ($(TUG_BIN)) so the test exercises tug.c's own
# virtio-block backend (the shipping path), not stock temu's.
apkboot: $(TUG_BIN) $(INITRAMFS) $(ALPINE_TGZ) $(DATA_DISK) config/tug-apk-init
	@TUG_CURL="$(CURDIR)/$(CURL_BIN)" TUG_CACERT="$(CURDIR)/$(CACERT)" \
	  bash scripts/apkboot.sh "$(CURDIR)/$(TUG_BIN)" "$(CURDIR)/$(IMAGE_DIR)" \
	  "$(CURDIR)/$(ROOTFS_DIR)/fs" "$(CURDIR)/config/tug-apk-init" \
	  "$(CURDIR)/$(ALPINE_TGZ)" "$(CURDIR)/$(DATA_DISK)" $(MODE)

kernel:
	@echo "Rebuilding our 6.x kernel (Image-c2w) is a documented manual step:"
	@echo "see docs/kernel.md. A native macOS kernel build hits open-ended"
	@echo "host-tool issues (case-sensitivity, GNU make, elf.h, uuid_t, ...);"
	@echo "the recipe handles them. The prebuilt Image-c2w already lives in"
	@echo "vendors/diskimage/ and 'make boot6' / 'make embed' use it."

# ---------------------------------------------------------------------------
# ARM64 (macOS / Apple Virtualization) — the macOS-only HVF backend payload.
# `make arm64` builds kernel + apk initramfs + an empty data disk; then
# `make -C mac payload` bundles them into Boat.app. macOS host only.
# ---------------------------------------------------------------------------
# aarch64 cross sysroot (musl.cc) + LLVM/lld. The musl.cc gcc is Linux-hosted, so
# it won't run on macOS, but clang uses its sysroot + libgcc to build aarch64.
aarch64-toolchain: $(AARCH64_CROSS)/bin/aarch64-linux-musl-gcc
$(AARCH64_CROSS)/bin/aarch64-linux-musl-gcc:
	@command -v "$(BREW)/opt/llvm/bin/clang" >/dev/null 2>&1 || brew install llvm
	@ls "$(BREW)/opt/lld/bin/ld.lld" >/dev/null 2>&1 || brew install lld
	@mkdir -p $(VENDOR)
	$(CURL) -o $(VENDOR)/aarch64-linux-musl-cross.tgz https://musl.cc/aarch64-linux-musl-cross.tgz
	tar xzf $(VENDOR)/aarch64-linux-musl-cross.tgz -C $(VENDOR)
	@echo "aarch64 sysroot: $(AARCH64_CROSS)"

alpine-arm64: $(ALPINE_ARM_TGZ)
$(ALPINE_ARM_TGZ):
	@mkdir -p $(VENDOR)
	$(CURL) -o $@ $(ALPINE_ARM_URL)
	@echo "$(ALPINE_ARM_SHA)  $@" | $(SHA) -c -

# Our own arm64 Image (case-sensitive volume + host shims + LLVM=1; ~10-30 min).
kernel-arm64: $(KERNEL_ARM)
$(KERNEL_ARM): $(AARCH64_CROSS)/bin/aarch64-linux-musl-gcc scripts/build-arm64-kernel.sh
	LINUX_ARM_VER=$(LINUX_ARM_VER) bash scripts/build-arm64-kernel.sh

# Alpine aarch64 apk initramfs (self-seeds /dev/vda + switch_root + essentials).
initrd-arm64: $(INITRD_ARM)
$(INITRD_ARM): scripts/build-arm64-initramfs.sh config/tug-apk-init $(ALPINE_ARM_TGZ)
	bash scripts/build-arm64-initramfs.sh "$(CURDIR)/$(ALPINE_ARM_TGZ)"

# Empty ext4 data disk packed sparse (the guest fills it on first boot).
disk-arm64: $(DATA_ARM_SPARSE)
$(DATA_ARM_SPARSE):
	@mkdir -p generated
	rm -f generated/data-arm64-empty.img
	truncate -s $(DISK_SIZE) generated/data-arm64-empty.img
	$(MKE2FS) -q -t ext4 -L tugdata -m 0 -i 65536 \
	  -E nodiscard,lazy_itable_init=1,lazy_journal_init=1 -F generated/data-arm64-empty.img
	python3 mac/build-sparse.py generated/data-arm64-empty.img $@
	@echo "arm64 data disk (sparse): $@  (`du -h $@ | cut -f1`)"

# Full arm64 payload for Boat.app (macOS/VZ).
arm64: kernel-arm64 initrd-arm64 disk-arm64
	@echo "arm64 payload ready — run: make -C mac payload && make -C mac mac"

# ---------------------------------------------------------------------------
clean:
	-$(MAKE) -C $(TINYEMU_DIR) clean 2>/dev/null || true

distclean:
	rm -rf $(VENDOR)
