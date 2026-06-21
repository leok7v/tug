# Boat — universal SwiftUI app (macOS + iPadOS + iOS) for tug.
# Independent of the project's top-level Makefile.
#
#   make            (re)generate boat.xcodeproj from project.yml  (needs xcodegen)
#   make mac        build the macOS app
#   make ios        build for the iOS Simulator ($(SIM))
#   make open       open boat.xcodeproj in Xcode
#   make clean

SIM ?= iPhone 17 Pro
.PHONY: all mac ios open clean
all: boat.xcodeproj

boat.xcodeproj: project.yml Boat.swift Platform-iOS.swift Platform-macOS.swift
	xcodegen generate

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
