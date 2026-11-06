#!/bin/bash
# Monta e instala /Applications/Espelho.app: recebe o "Espelhar Tela" do iPhone/iPad.
# O receptor AirPlay é o UxPlay (open source), embutido e controlado pelo app.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

if [ -d /Applications/Xcode.app ] && [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# 1. UxPlay (com os eventos que o app lê)
UX=vendor/UxPlay
if [ ! -d "$UX" ]; then
  brew install cmake pkg-config libplist openssl@3 gstreamer
  mkdir -p vendor
  git clone --depth 1 https://github.com/FDH2/UxPlay.git "$UX"
fi
python3 scripts/patch-uxplay.py "$UX/uxplay.cpp"
mkdir -p "$UX/build"
(cd "$UX/build" && cmake .. >/dev/null && make -j8 2>&1 | grep -E "error|Built target uxplay")

# 2. Android: adb + servidor do scrcpy (embutidos no app)
command -v scrcpy >/dev/null || brew install scrcpy
command -v adb >/dev/null || brew install --cask android-platform-tools
ADB_BIN=$(realpath "$(command -v adb)")
SCRCPY_SERVER="$(brew --prefix scrcpy)/share/scrcpy/scrcpy-server"
SCRCPY_VERSION=$(scrcpy --version | head -1 | awk '{print $2}')

# 3. App
(cd Espelho && swift build -c release 2>&1 | grep -E "error|Compiling Espelho|Build complete")
BIN_DIR="$(cd Espelho && swift build -c release --show-bin-path)"
BIN="$BIN_DIR/Espelho"

# 4. Ícone
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
[ -f Espelho/Resources/icon-1024.png ] || (cd Espelho/Resources && swift make-icon.swift icon-1024.png)
for s in 16 32 128 256 512; do
  sips -z $s $s Espelho/Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Espelho/Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

# 5. Pacote .app
APP="/Applications/Espelho.app"
pkill -x Espelho 2>/dev/null || true
pkill -f "Espelho.app/Contents/MacOS/uxplay" 2>/dev/null || true
pkill -f "Espelho.app/Contents/Helpers/uxplay" 2>/dev/null || true
pkill -f "Espelho iPhone.app" 2>/dev/null || true
rm -rf "$APP" "/Applications/Espelho iPhone.app"
# Ajudantes ficam em Contents/Helpers: fora de MacOS, o macOS não os confunde com o app.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Espelho"
# Sparkle (atualizações; desligadas nesta cópia local, que não tem SUFeedURL).
mkdir -p "$APP/Contents/Frameworks"
cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Espelho" 2>/dev/null || true
cp "$UX/build/uxplay" "$APP/Contents/Helpers/uxplay"
cp "$ADB_BIN" "$APP/Contents/Helpers/adb"
cp "$SCRCPY_SERVER" "$APP/Contents/Resources/scrcpy-server.jar"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

source scripts/info-plist.sh
write_info_plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :EspelhoSourcePath string $ROOT" -c "Add :EspelhoScrcpyVersion string $SCRCPY_VERSION" "$APP/Contents/Info.plist"

codesign --force --deep -s - "$APP" >/dev/null 2>&1
touch "$APP"
echo "Pronto: $APP"
# Reabre o app (por exemplo, depois do botão "Reparar"). ESPELHO_NO_OPEN=1 desativa.
if [ -z "${ESPELHO_NO_OPEN:-}" ]; then
  sleep 1
  open "$APP"
fi
