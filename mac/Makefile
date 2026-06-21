# Boat — universal SwiftUI app (macOS + iPadOS + iOS) for tug.
# Independent of the project's top-level Makefile.
#
#   make            (re)generate boat.xcodeproj from project.yml  (needs xcodegen)
#   make mac        build the macOS app
#   make ios        build for the iOS Simulator ($(SIM))
#   make icons      regenerate the AppIcon set from $(ICON_SRC)  (needs ImageMagick)
#   make open       open boat.xcodeproj in Xcode
#   make clean

SIM ?= iPhone 17 Pro
ICON_SRC ?= ../www/tug-icon.png
ICONSET := Assets.xcassets/AppIcon.appiconset
PAYLOAD := payload/bios.bin payload/kernel.bin payload/initrd.cgz
.PHONY: all mac ios icons open clean payload

all: boat.xcodeproj

# Guest payload bundled as app resources. Depends on the repo build artifacts
# (run `make build embed` at the repo root first).
payload: $(PAYLOAD)
$(PAYLOAD): stage-payload.sh ../vendors/diskimage/bbl64.bin ../vendors/diskimage/Image-c2w ../generated/tug-embed.cpio.gz
	bash stage-payload.sh

boat.xcodeproj: project.yml Boat.swift Platform-iOS.swift Platform-macOS.swift Boat-Bridging.h $(PAYLOAD)
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

open: boat.xcodeproj
	open boat.xcodeproj

clean:
	rm -rf build DerivedData
