#!/bin/bash
# Builds the downloadable Espelho: works on any Apple Silicon Mac with macOS 26, with or without
# Homebrew. UxPlay, the GStreamer pieces it uses (with their libraries), adb and the scrcpy server
# all travel inside the app; it is signed with the witchmymac certificate (no hardened runtime, see
# witchmymac-release/sign-app.sh) and packed in a DMG.
#
#   scripts/make-release.sh            -> build/release/Espelho.app and $DIST/Espelho-<version>.dmg
#
# Needs: Xcode, Homebrew with gstreamer, libplist, openssl@3, scrcpy, android-platform-tools
# (only on the Mac that builds), and the witchmymac-release folder (signing + DMG scripts).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
RELEASE_TOOLS=${WITCHMYMAC_RELEASE:-$HOME/Documents/VSCode/witchmymac-release}
DIST=${DIST:-$RELEASE_TOOLS/dist}
source scripts/info-plist.sh

if [ -d /Applications/Xcode.app ] && [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
[ -x "$RELEASE_TOOLS/sign-app.sh" ] || { echo "witchmymac-release não encontrado em $RELEASE_TOOLS" >&2; exit 1; }

# 1. UxPlay (OpenSSL and libplist are linked statically on macOS)
UX=vendor/UxPlay
if [ ! -d "$UX" ]; then
  brew install cmake pkg-config libplist openssl@3 gstreamer
  mkdir -p vendor
  git clone --depth 1 https://github.com/FDH2/UxPlay.git "$UX"
fi
python3 scripts/patch-uxplay.py "$UX/uxplay.cpp"
mkdir -p "$UX/build"
(cd "$UX/build" && cmake .. -DCMAKE_BUILD_TYPE=Release >/dev/null && make -j8 2>&1 | grep -E "error|Built target uxplay")

# 2. Android pieces
command -v scrcpy >/dev/null || brew install scrcpy
command -v adb >/dev/null || brew install --cask android-platform-tools
ADB_BIN=$(realpath "$(command -v adb)")
SCRCPY_SERVER="$(brew --prefix scrcpy)/share/scrcpy/scrcpy-server"
SCRCPY_VERSION=$(scrcpy --version | head -1 | awk '{print $2}')

# 3. App binary
(cd Espelho && swift build -c release 2>&1 | grep -E "error|Build complete")
BIN_DIR="$(cd Espelho && swift build -c release --show-bin-path)"

# 4. Bundle
APP="$ROOT/build/release/Espelho.app"
C="$APP/Contents"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Helpers" "$C/Resources" "$C/Frameworks" "$C/PlugIns/gstreamer"
cp "$BIN_DIR/Espelho" "$C/MacOS/Espelho"
cp -R "$BIN_DIR/Sparkle.framework" "$C/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$C/MacOS/Espelho" 2>/dev/null || true
cp "$ADB_BIN" "$C/Helpers/adb"
cp "$SCRCPY_SERVER" "$C/Resources/scrcpy-server.jar"

# Icon
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Espelho/Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Espelho/Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$C/Resources/AppIcon.icns"
python3 scripts/make-localizations.py >/dev/null
cp -R Espelho/Resources/Localizations/*.lproj "$C/Resources/"

# UxPlay + only the GStreamer plugins it uses, then every library they need.
GST=$(realpath "$(brew --prefix gstreamer)")
PLUGINS="app audioconvert audioresample autodetect coreelements level libav osxaudio playback
         rtp rtpmanager tcp typefindfunctions videoparsersbad volume"
cp "$UX/build/uxplay" "$C/Helpers/uxplay"
cp "$GST/libexec/gstreamer-1.0/gst-plugin-scanner" "$C/Helpers/gst-plugin-scanner"
ARGS=("$C/Helpers/uxplay=$ROOT/$UX/build/uxplay"
      "$C/Helpers/gst-plugin-scanner=$GST/libexec/gstreamer-1.0/gst-plugin-scanner")
for p in $PLUGINS; do
  cp "$GST/lib/gstreamer-1.0/libgst$p.dylib" "$C/PlugIns/gstreamer/"
  ARGS+=("$C/PlugIns/gstreamer/libgst$p.dylib=$GST/lib/gstreamer-1.0/libgst$p.dylib")
done
python3 scripts/bundle-dylibs.py "$C/Frameworks" "${ARGS[@]}"

# Licenses of what travels inside
mkdir -p "$C/Resources/Licenses"
cp LICENSE "$C/Resources/Licenses/Espelho-GPL-3.0.txt"
cp "$UX/LICENSE" "$C/Resources/Licenses/UxPlay-GPL-3.0.txt"
cp THIRD-PARTY.md "$C/Resources/Licenses/THIRD-PARTY.md"

# Info.plist: release copies check witchmymac.com for updates (Sparkle).
write_info_plist "$C/Info.plist"
P=/usr/libexec/PlistBuddy
$P -c "Add :EspelhoScrcpyVersion string $SCRCPY_VERSION" \
   -c "Add :SUFeedURL string https://witchmymac.com/appcast/espelho.xml" \
   -c "Add :SUPublicEDKey string $(cat "$RELEASE_TOOLS/signing/sparkle-ed25519-public.txt")" \
   -c "Add :SUEnableAutomaticChecks bool true" \
   -c "Add :SUScheduledCheckInterval integer 86400" \
   -c "Add :SUAutomaticallyUpdate bool false" "$C/Info.plist"

# 5. Nothing may point outside the app (Homebrew isn't on other Macs).
LEAKS=$(find "$C" -type f -perm -u+x | while read -r f; do
  file -b "$f" | grep -q Mach-O || continue
  otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -E "^/(opt|usr/local)/" | sed "s|^|$f -> |" || true
done)
[ -z "$LEAKS" ] || { echo "dependências fora do app:"; echo "$LEAKS"; exit 1; } >&2

# 6. Sign and pack
"$RELEASE_TOOLS/sign-app.sh" "$APP"
"$RELEASE_TOOLS/make-dmg.sh" "$APP" "Espelho-$ESPELHO_VERSION" "$DIST"
echo "Versão $ESPELHO_VERSION ($ESPELHO_BUILD) pronta."
