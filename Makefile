# tug — minimalist RISC-V sandbox
#
# Milestone 0 — TinyEMU bring-up:
#   vendor an unmodified TinyEMU + a stock riscv64 Linux image, build headless,
#   boot to a shell. (vendors / build / smoke / boot)
#
# Milestone 1 — our own guest payload:
#   build a riscv64-linux-musl cross toolchain (musl-cross-make), install kernel
#   headers, cross-build toybox + tcc, assemble a rootfs with mkroot, pack it as
#   ext2, and boot it as a full system (init=pid1) on the stock prebuilt kernel.
#   (toolchain / headers / tcc / rootfs / ext2 / payload / bootfs)
#
# Third-party sources are downloaded/cloned into ./vendors/ (gitignored). macOS
# build portability for TinyEMU lives in ./compat/ shims; functional changes to
# the emulator live as patches in ./patches/ (applied on extract) — currently
# tinyemu-rdtime.patch, which implements the unprivileged `time` CSR (rdtime) the
# 2019 release lacks, required to boot Linux 6.x userspace. The guest-payload
# build needs a GNU userland on macOS — run `make deps` once (Homebrew GNU tools).
#
# NOTE: building our own *kernel* is deferred (see `make kernel`). A native macOS
# kernel build hits open-ended host-tool issues; the plan is a Linux container
# for that one step. `make bootfs` boots our rootfs on the stock prebuilt kernel.

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
TCC_DIR    := $(VENDOR)/tinycc
TCC_CROSS  := $(TCC_DIR)/riscv64-tcc

ROOTFS_DIR := $(TOYBOX_DIR)/root/riscv64
INITRAMFS  := $(ROOTFS_DIR)/initramfs.cpio.gz
HEADERS    := $(SYSROOT)/include/linux/fs.h
EXT2       := $(IMAGE_DIR)/tug-root.ext2

# The guest-payload build (toybox/mkroot/tcc) assumes a GNU userland. On macOS,
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

.PHONY: help deps vendors build smoke boot \
        toolchain headers tcc rootfs ext2 payload bootfs kernel \
        clean distclean

help:
	@echo "tug — minimalist RISC-V sandbox"
	@echo
	@echo "Milestone 0 — TinyEMU bring-up:"
	@echo "  make vendors    download + checksum TinyEMU source and stock riscv64 image"
	@echo "  make build      compile headless temu ($(UNAME_S))"
	@echo "  make smoke      boot the stock image, assert a shell is reached"
	@echo "  make boot       boot the stock image interactively (exit: Ctrl-a x)"
	@echo
	@echo "Milestone 1 — our guest payload:"
	@echo "  make deps       (macOS) brew-install the GNU build userland"
	@echo "  make toolchain  build riscv64-linux-musl cross gcc (musl-cross-make) [~20-40 min]"
	@echo "  make headers    install riscv kernel headers into the sysroot"
	@echo "  make tcc        build the riscv64 cross-tcc + libtcc1.a"
	@echo "  make rootfs     build the toybox rootfs + initramfs.cpio.gz (mkroot)"
	@echo "  make ext2       pack the rootfs into an ext2 root image"
	@echo "  make payload    toolchain -> headers -> tcc -> rootfs -> ext2"
	@echo "  make bootfs     boot our rootfs as init on the stock kernel (assert)"
	@echo "  make kernel     (deferred) notes on building our own kernel"
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

$(IMAGE_DIR)/$(CFG): $(IMAGE_TGZ)
	rm -rf $(IMAGE_DIR) && mkdir -p $(IMAGE_DIR)
	tar xzf $(IMAGE_TGZ) -C $(IMAGE_DIR) --strip-components=1
	@touch $@   # tar restores 2018 mtimes; bump so make doesn't re-extract forever

smoke: $(TEMU) $(IMAGE_DIR)/$(CFG)
	@bash scripts/smoke.sh "$(CURDIR)/$(TEMU)" "$(CURDIR)/$(IMAGE_DIR)" "$(CFG)"

boot: $(TEMU) $(IMAGE_DIR)/$(CFG)
	@echo "Booting riscv64 Linux. Exit the emulator with: Ctrl-a x"
	@cd $(IMAGE_DIR) && exec "$(CURDIR)/$(TEMU)" $(CFG)

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

tcc: $(TCC_CROSS)

# Host-running cross-tcc that emits rv64 (+ the rv64 libtcc1.a runtime).
$(TCC_CROSS):
	test -d $(TCC_DIR) || git clone --depth 1 https://github.com/TinyCC/tinycc.git $(TCC_DIR)
	cd $(TCC_DIR) && $(GNUENV) ./configure && $(GNUENV) $(MAKE) cross-riscv64
	@echo "tcc: $(TCC_CROSS) (+ riscv64-libtcc1.a)"

rootfs: $(INITRAMFS)

# mkroot builds toybox (static rv64) and assembles a root filesystem + initramfs.
# NOCLEAR=1 keeps our env across mkroot's self-reexec; NOAIRLOCK=1 skips building
# a host toybox (toybox-on-macOS-as-host is unreliable). LDOPTIMIZE overrides the
# uname=Darwin -dead_strip default; the GNU PATH supplies sed/awk/od/find/cpio.
$(INITRAMFS): $(TC_GCC) $(HEADERS)
	test -d $(TOYBOX_DIR) || git clone --depth 1 https://github.com/landley/toybox.git $(TOYBOX_DIR)
	cd $(TOYBOX_DIR) && \
	  NOCLEAR=1 NOAIRLOCK=1 CROSS_COMPILE="$(CROSS)" \
	  LDOPTIMIZE='-Wl,--gc-sections -Wl,--as-needed' STRIP=strip \
	  $(GNUENV) bash mkroot/mkroot.sh
	@echo "rootfs: $(INITRAMFS)"

ext2: $(EXT2)

$(EXT2): $(INITRAMFS) $(IMAGE_DIR)/$(CFG)
	rm -f $@
	$(MKE2FS) -q -t ext2 -b 1024 -L tugroot -d $(ROOTFS_DIR)/fs -F $@ 16384
	@echo "ext2 root image: $@"

payload: $(EXT2) $(TCC_CROSS)
	@echo "payload ready: toolchain + tcc + rootfs + ext2"

# Boot our rootfs as a full system (init=pid1) on the stock prebuilt kernel.
bootfs: $(TEMU) $(EXT2) $(IMAGE_DIR)/$(CFG)
	@bash scripts/bootfs.sh "$(CURDIR)/$(TEMU)" "$(CURDIR)/$(IMAGE_DIR)"

kernel:
	@echo "Building our OWN kernel is deferred."
	@echo "A native macOS kernel build hits open-ended host-tool issues"
	@echo "(case-sensitivity, GNU make, elf.h, uuid_t, ...). The plan is to"
	@echo "build the kernel in a Linux container, which also answers whether a"
	@echo "modern kernel boots on TinyEMU's legacy SBI. For now 'make bootfs'"
	@echo "boots our rootfs on the stock prebuilt 4.15 kernel via ext2."

# ---------------------------------------------------------------------------
clean:
	-$(MAKE) -C $(TINYEMU_DIR) clean 2>/dev/null || true

distclean:
	rm -rf $(VENDOR)
