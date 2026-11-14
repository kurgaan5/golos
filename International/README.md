# DictaNest — Offline Speech to Text

International test build, 1.8.0 beta 1, by Okulovsky. Based on stable Golos 1.x;
no archived Golos 2.0 code, input method, relogin requirement or source installation.

Native macOS 14+ Apple Silicon app; Windows 10+ x64 and Windows 11 ARM64 builds.
Whisper large-v3-turbo q5_0 and Silero VAD are bundled, with no API key or runtime
network dependency. Model hashes are verified by the Windows packaging script.

- Independent speech and interface language settings; 20 interface catalogs,
  34 spoken-language options, right-to-left Arabic/Persian/Urdu interfaces.
- Primary-language mode is the default. Optional auto mode checks only the chosen
  pair, waits for enough audio and locks the decision for the entire recording.
- The international default has no vocabulary prompt: even a short list of English
  names caused missing Russian sentence prefixes in a regression fixture. Users
  can add their own spellings in normal Settings, for the next recording.
- Script filtering keeps the selected language and Latin names. It cannot identify
  an incorrect English word inside another language that also uses Latin script.
- Pinned input destination, append-only confirmed text, no blind paste replay,
  capture isolation, decoder-loop/rate/token/confidence guards, local history.
- Dedicated preferences/history/instance identity. Do not run Golos and DictaNest
  together with the same global shortcut. No automatic migration of private data.

Mac build: set `GOLOS_DEPENDENCY_DIR` to a Golos dependency directory containing
`work/whisper.cpp-1.8.2`, `work/whisper-build` static libraries and the two verified
model files, then run `zsh build.sh`. Output: `dist/DictaNest.app`.
Windows build on the target architecture: `pwsh scripts/build-windows.ps1 -Arch x64`
or `-Arch arm64`, with Visual Studio C++, CMake, Python and .NET SDK 10 installed.
The script creates ZIP/Setup.exe packages and exercises the complete installer.

The interface starts in English and offers an explicit system-language option.
Technical Details and exceptional messages are English. Chinese is Simplified.
Translations have not received independent native-speaker review.

CI produces candidates for testing; it does not publish a stable release. Passing
unit/audio/render tests does not establish real microphone, shortcut, Accessibility,
SmartScreen/Gatekeeper or editor compatibility. Follow REGRESSION_CHECKLIST.md and
record PASS / FAIL / NOT TESTED honestly. Required live tests must pass on each
released platform. Older stable Golos installers are not replaced.
