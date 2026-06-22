# Boat — universal SwiftUI app (macOS + iPadOS + iOS) for tug.
# Independent of the project's top-level Makefile.
#
#   make            (re)generate boat.xcodeproj from project.yml  (needs xcodegen)
#   make mac        build the macOS app
#   make ios        build for the iOS Simulator ($(SIM))
#   make icons      regenerate the AppIcon set from $(ICON_SRC)  (needs ImageMagick)
#   make lsp        regenerate the SourceKit-LSP config (fixes editor false errors)
#   make open       open boat.xcodeproj in Xcode
#   make clean

SIM ?= iPhone 17 Pro
ICON_SRC ?= ../www/tug-icon.png
ICONSET := Assets.xcassets/AppIcon.appiconset
PAYLOAD := payload/bios.bin payload/kernel.bin payload/initrd.cgz payload/data.sparse
.PHONY: all mac ios icons lsp open clean payload

all: boat.xcodeproj

# Guest payload bundled as app resources: bios + kernel + the apk initramfs, plus
# the pre-seeded Alpine data disk packed into a sparse manifest. Build the repo
# artifacts first (at the repo root):  make embed-apk disk-seeded
payload: $(PAYLOAD)
$(PAYLOAD): stage-payload.sh build-sparse.py ../vendors/diskimage/bbl64.bin ../vendors/diskimage/Image-c2w ../generated/tug-embed-apk.cpio.gz ../tug-seed.img
	bash stage-payload.sh

boat.xcodeproj: project.yml Boat.swift Terminal.swift Platform-iOS.swift Platform-macOS.swift Boat-Bridging.h $(PAYLOAD)
	xcodegen generate

# Generate every AppIcon size from one source image (icon is square, no alpha).
icons:
	@command -v magick >/dev/null || { echo "need ImageMagick (brew install imagemagick)"; exit 1; }
	@for px in 16 32 64 128 256 512 1024; do \
	  magick "$(ICON_SRC)" -resize $${px}x$${px} -strip "$(ICONSET)/icon_$${px}.png"; done
	@echo "icons regenerated from $(ICON_SRC)"

mac: boat.xcodeproj
	xcodebuild -project boat.xcodeproj -scheme Boat -destination 'platform=macOS' \
	  -configuration Debug build CODE_SIGNING_ALLOWED=NO

ios: boat.xcodeproj
	xcodebuild -project boat.xcodeproj -scheme Boat \
	  -destination 'platform=iOS Simulator,name=$(SIM)' \
	  -configuration Debug build CODE_SIGNING_ALLOWED=NO

# Regenerate the SourceKit-LSP config (buildServer.json + .compile) so the editor
# resolves cross-file and per-platform symbols instead of showing false errors.
# Both platform builds are parsed so each Platform-*.swift gets its own SDK's
# flags (otherwise SourceKit sees both RootView definitions at once). The outputs
# are machine-specific and gitignored — rerun after adding/removing source files,
# then restart the build server / editor. Needs: brew install xcode-build-server
lsp: boat.xcodeproj
	@command -v xcode-build-server >/dev/null || { echo "need xcode-build-server (brew install xcode-build-server)"; exit 1; }
	# Index BOTH platforms so every file resolves under its own SDK. xcode-build-server
	# keys `.compile` by the single "Boat" module, so the two passes don't accumulate
	# (the last wins, leaving the other platform's files indexed against the wrong
	# SDK — "No such module 'Virtualization'/'AppKit'" or "'UIKit'"). So: parse iOS,
	# stash it, parse macOS (this wins/overwrites), then merge the iOS whole-module
	# entry back in (each carries its own SwiftFileList -> per-file SDK matching).
	@rm -f .compile .compile.ios   # start fresh: parse -a appends, so clear first
	xcodebuild -project boat.xcodeproj -scheme Boat -destination 'platform=iOS Simulator,name=$(SIM)' \
	  -configuration Debug clean build CODE_SIGNING_ALLOWED=NO 2>&1 | xcode-build-server parse -a
	mv .compile .compile.ios
	# macOS pass must NOT clean: a clean would delete the iOS SwiftFileList that the
	# merged iOS entry references (separate Debug-iphonesimulator dir, so building
	# macOS alongside it is fine).
	xcodebuild -project boat.xcodeproj -scheme Boat -destination 'platform=macOS' \
	  -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | xcode-build-server parse -a
	python3 merge-lsp.py .compile .compile.ios
	@rm -f .compile.ios
	@echo "LSP config regenerated — restart the build server / reopen the editor."

open: boat.xcodeproj
	open boat.xcodeproj

clean:
	rm -rf build Build DerivedData
