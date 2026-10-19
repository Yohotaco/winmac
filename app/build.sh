#!/bin/bash
# Compila o WinMac.app e instala em /Applications
set -e
cd "$(dirname "$0")"
APP=build/WinMac.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library WinMac.swift -o "$APP/Contents/MacOS/WinMac"
swift makeicon.swift build/WinMac.iconset && iconutil -c icns build/WinMac.iconset -o "$APP/Contents/Resources/WinMac.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>WinMac</string>
<key>CFBundleDisplayName</key><string>WinMac</string>
<key>CFBundleIdentifier</key><string>local.winmac.app</string>
<key>CFBundleExecutable</key><string>WinMac</string>
<key>CFBundleIconFile</key><string>WinMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
mkdir -p "$HOME/winmac/Bottles" && cp ../winmac "$HOME/winmac/winmac" && chmod +x "$HOME/winmac/winmac"
mkdir -p "$HOME/winmac/tools" && cp ../tools/steamwebhelper-wrap.exe "$HOME/winmac/tools/"
rm -rf /Applications/WinMac.app && cp -R "$APP" /Applications/
echo "Instalado em /Applications/WinMac.app"
