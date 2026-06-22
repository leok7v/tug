#!/usr/bin/env python3
# Merge the iOS compile DB into the macOS one for SourceKit-LSP.
#
# xcode-build-server keys its `.compile` by the single "Boat" module, so two
# sequential `parse` runs don't accumulate — the last one wins. That leaves the
# other platform's files indexed against the wrong SDK ("No such module
# 'Virtualization'/'AppKit'" or "'UIKit'"). We run both passes, then append the
# iOS-simulator whole-module entry (it carries its own SwiftFileList) so SourceKit
# matches each file to the right-SDK command. Shared files appear in both lists;
# either SDK resolves their cross-platform APIs.
#
# Usage: merge-lsp.py <.compile (macOS, kept)> <.compile.ios (iOS, source)>
import json, sys

dst, src = sys.argv[1], sys.argv[2]
mac = json.load(open(dst))
ios = json.load(open(src))
ios_only = [e for e in ios if "iPhoneSimulator" in e.get("command", "")]
json.dump(mac + ios_only, open(dst, "w"), indent=1)
print(f"lsp: merged {len(mac)} macOS + {len(ios_only)} iOS compile entries")
