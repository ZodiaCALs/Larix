#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
root="$PWD"
dev="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ -d "$dev/Toolchains" ]]; then
    bin="$dev/Toolchains/XcodeDefault.xctoolchain/usr/bin"
    sdk="$dev/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
else
    bin="$dev/usr/bin"
    sdk="$dev/SDKs/MacOSX.sdk"
fi
export SDKROOT="$sdk"
export TMPDIR="$root/.build/tmp"
export PATH="$bin:$PATH"
cache="$root/.build/modules"
mkdir -p "$TMPDIR" "$cache" build
bundle="$root/.build/stage/Larix.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
swiftargs=(-sdk "$sdk" -module-cache-path "$cache" -swift-version 5)
"$bin/clang" -O2 -Wall -isysroot "$sdk" Tests/SignalTests.c Sources/Signal.c -o .build/signal-tests
.build/signal-tests
"$bin/swiftc" "${swiftargs[@]}" Tools/MakeIcon.swift Sources/Waveform.swift -o .build/make-icon
.build/make-icon "$bundle/Contents/Resources/LarixWaveform.icns"
rm -f "$bundle/Contents/Resources/Larix.icns"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
executables=()
for arch in ${ARCHS:-arm64 x86_64}; do
    target="$arch-apple-macos14.2"
    objects="$root/.build/$arch"
    mkdir -p "$objects"
    flags=(-target "$target" -isysroot "$sdk" -O2 -Wall -Wextra -Wno-unused-parameter)
    "$bin/clang" "${flags[@]}" -c Sources/Signal.c -o "$objects/Signal.o"
    "$bin/clang" "${flags[@]}" -fobjc-arc -fmodules -fmodules-cache-path="$cache" -c Sources/AudioBridge.m -o "$objects/AudioBridge.o"
    "$bin/swiftc" "${swiftargs[@]}" -Osize -whole-module-optimization -Xlinker -dead_strip -target "$target" -module-name Larix -import-objc-header Sources/AudioBridge.h \
        Sources/*.swift "$objects/Signal.o" "$objects/AudioBridge.o" -framework AudioUnit -framework AudioToolbox -framework CoreAudio -o "$objects/Larix"
    executables+=("$objects/Larix")
done
"$bin/lipo" -create "${executables[@]}" -output "$bundle/Contents/MacOS/Larix"
"$bin/strip" -x "$bundle/Contents/MacOS/Larix"
/usr/bin/codesign --force --sign "${SIGN_IDENTITY:--}" "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
/usr/bin/ditto "$bundle" "$root/build/Larix.app"
rm -f "$root/build/Larix.app/Contents/Resources/Larix.icns"
/usr/bin/codesign --verify --strict "$root/build/Larix.app"
touch "$root/build/Larix.app"
echo "Built $root/build/Larix.app"
