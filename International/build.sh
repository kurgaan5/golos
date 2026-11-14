#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$ROOT/Source"
DEPENDENCY_DIR="${GOLOS_DEPENDENCY_DIR:-$ROOT/..}"
WHISPER="$DEPENDENCY_DIR/work/whisper.cpp-1.8.2"
BUILD="$DEPENDENCY_DIR/work/whisper-build"
APP="${DICTANEST_APP_DIR:-$ROOT/dist/DictaNest.app}"
mkdir -p "$ROOT/work/swift-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
for MODEL in ggml-large-v3-turbo-q5_0.bin ggml-silero-v5.1.2.bin; do
  test -f "$DEPENDENCY_DIR/work/$MODEL"
  if [ ! -f "$APP/Contents/Resources/$MODEL" ]; then cp -c "$DEPENDENCY_DIR/work/$MODEL" "$APP/Contents/Resources/$MODEL"; fi
done
cp "$SOURCE/Info.plist" "$APP/Contents/Info.plist"
cp "$SOURCE/AppIcon.icns" "$SOURCE/ThirdPartyNotices.txt" "$SOURCE/Localizations.json" "$APP/Contents/Resources/"
python3 - "$SOURCE" "$APP/Contents/Resources" <<'PY'
import json, pathlib, sys
source, destination = map(pathlib.Path, sys.argv[1:])
for code, strings in json.loads((source/'Localizations.json').read_text()).items():
    folder=destination/(code+'.lproj'); folder.mkdir(exist_ok=True)
    description=strings['microphone']+': '+strings['tagline']+'. '+strings['privacy']
    (folder/'InfoPlist.strings').write_text('"NSMicrophoneUsageDescription" = '+json.dumps(description,ensure_ascii=False)+';\n',encoding='utf-8')
PY
xcrun clang++ -std=c++17 -O3 -mmacosx-version-min=14.0 -I "$WHISPER/include" -I "$WHISPER/ggml/include" -c "$SOURCE/WhisperBridge.cpp" -o "$ROOT/work/WhisperBridge.o"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path "$ROOT/work/swift-cache" -import-objc-header "$SOURCE/WhisperBridge.h" \
  "$SOURCE/main.swift" "$SOURCE/SpeechVocabulary.swift" "$SOURCE/DeveloperPassword.swift" "$SOURCE/LanguagePolicy.swift" "$SOURCE/InternationalUI.swift" "$SOURCE/InternationalChecks.swift" "$ROOT/work/WhisperBridge.o" \
  "$BUILD/src/libwhisper.a" "$BUILD/ggml/src/libggml.a" "$BUILD/ggml/src/libggml-base.a" "$BUILD/ggml/src/libggml-cpu.a" "$BUILD/ggml/src/ggml-metal/libggml-metal.a" "$BUILD/ggml/src/ggml-blas/libggml-blas.a" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework Carbon -framework ApplicationServices -framework ServiceManagement -framework Accelerate -framework Metal -framework MetalKit -framework Foundation -lc++ -o "$APP/Contents/MacOS/Golos"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/Golos" --self-test
