# Sourced by make-espelho-app.sh and make-release.sh: version and Info.plist of Espelho.
ESPELHO_VERSION=1.3.1
ESPELHO_BUILD=6   # CFBundleVersion: what Sparkle compares, must go up every release

# write_info_plist <Info.plist path>   (English; translations in Resources/<lang>.lproj, see
# scripts/make-localizations.py)
write_info_plist() {
  cat > "$1" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Espelho</string>
<key>CFBundleDisplayName</key><string>Espelho</string>
<key>CFBundleIdentifier</key><string>com.matheusfaria.espelho</string>
<key>CFBundleExecutable</key><string>Espelho</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$ESPELHO_BUILD</string>
<key>CFBundleShortVersionString</key><string>$ESPELHO_VERSION</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>es</string><string>pt-BR</string></array>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>So iPhones and iPads find this Mac in Screen Mirroring, and to connect Android devices over Wi‑Fi.</string>
<key>NSBonjourServices</key><array><string>_airplay._tcp</string><string>_raop._tcp</string><string>_adb-tls-pairing._tcp</string><string>_adb-tls-connect._tcp</string></array>
<key>NSHumanReadableCopyright</key><string>© 2026 Matheus Faria · GPL-3.0 · witchmymac.com</string>
</dict></plist>
PL
}
