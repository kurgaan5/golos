#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/macos/Source"
ARCH="$(uname -m)"
BUILD="$ROOT/.build/macos-$ARCH"
WHISPER="$ROOT/.build/whisper.cpp-1.8.2"
APP="$ROOT/dist/Голос.app"
mkdir -p "$ROOT/.build" "$ROOT/dist" "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ ! -d "$WHISPER" ]; then
  curl --fail --location --retry 3 https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.8.2.tar.gz -o "$ROOT/.build/whisper.tar.gz"
  tar -xzf "$ROOT/.build/whisper.tar.gz" -C "$ROOT/.build"
fi
cmake -S "$WHISPER" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_CURL=OFF -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_ACCELERATE=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build "$BUILD" --parallel 4
python3 "$ROOT/scripts/fetch-models.py" "$APP/Contents/Resources"
cp "$SOURCE/Info.plist" "$APP/Contents/Info.plist"
cp "$SOURCE/AppIcon.icns" "$ROOT/ThirdPartyNotices.txt" "$APP/Contents/Resources/"
xcrun clang++ -std=c++17 -O3 -mmacosx-version-min=14.0 -I "$WHISPER/include" -I "$WHISPER/ggml/include" -c "$SOURCE/WhisperBridge.cpp" -o "$BUILD/WhisperBridge.o"
xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macosx14.0" -module-cache-path "$BUILD/swift-cache" -import-objc-header "$SOURCE/WhisperBridge.h" "$SOURCE/main.swift" "$SOURCE/SpeechVocabulary.swift" "$SOURCE/DeveloperPassword.swift" "$BUILD/WhisperBridge.o" \
  "$BUILD/src/libwhisper.a" "$BUILD/ggml/src/libggml.a" "$BUILD/ggml/src/libggml-base.a" "$BUILD/ggml/src/libggml-cpu.a" "$BUILD/ggml/src/ggml-metal/libggml-metal.a" "$BUILD/ggml/src/ggml-blas/libggml-blas.a" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework Carbon -framework ApplicationServices -framework Accelerate -framework Metal -framework MetalKit -framework Foundation -lc++ -o "$APP/Contents/MacOS/Golos"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/Golos" --self-test
"$APP/Contents/MacOS/Golos" --transcribe-file "$ROOT/tests/fixtures/mixed-test.wav"
cp "$ROOT/MACOS.txt" "$ROOT/dist/Как пользоваться.txt"
NAME="Golos-1.7-macOS-$ARCH.zip"
ditto -c -k --keepParent "$APP" "$ROOT/dist/$NAME"
(cd "$ROOT/dist" && shasum -a 256 "$NAME" > "$NAME.sha256")
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Голос.app"
ln -sfn /Applications "$STAGE/Программы"
cp "$ROOT/MACOS.txt" "$STAGE/Как установить.txt"
DMG="Golos-1.7-macOS-$ARCH.dmg"
hdiutil create -volname "Голос" -srcfolder "$STAGE" -format UDZO -ov "$ROOT/dist/$DMG"
hdiutil verify "$ROOT/dist/$DMG"
(cd "$ROOT/dist" && shasum -a 256 "$DMG" > "$DMG.sha256")
