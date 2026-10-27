#!/bin/bash
# Compila o WinMac.app e instala em /Applications
set -e
cd "$(dirname "$0")"
APP=build/WinMac.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Sem compilador que funcione: instala o app já pronto (mesmo resultado do install.sh)
use_prebuilt() {
  echo "Não deu para compilar aqui ($1). Instalando o WinMac já pronto..."
  curl -fsSL https://raw.githubusercontent.com/Yohotaco/winmac/main/install.sh | bash
  exit $?
}

# Escolhe um SDK que o compilador instalado aceita. Às vezes as Command Line Tools trazem
# um SDK mais novo que o compilador ("this SDK is not supported by the compiler") ou sem o
# plugin de macros do SwiftUI ("plugin for module 'SwiftUIMacros' not found"); o teste usa @State.
printf 'import SwiftUI\nstruct T: View { @State var x = false; var body: some View { Text("") } }\n' > build/sdktest.swift
SDK=""
for s in "" $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk "$(xcode-select -p)"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk 2>/dev/null | sort -rV); do
  if swiftc ${s:+-sdk "$s"} -typecheck build/sdktest.swift 2>/dev/null; then SDK="$s"; break; fi
done
if [ -z "$SDK" ] && ! swiftc -typecheck build/sdktest.swift 2>/dev/null; then
  use_prebuilt "nenhum SDK compatível com o compilador Swift"
fi
[ -n "$SDK" ] && echo "Usando SDK: $SDK"
SWIFTC=(swiftc ${SDK:+-sdk "$SDK"})

# Binário universal (Apple Silicon + Intel) que roda do macOS 14 em diante
for arch in arm64 x86_64; do
  "${SWIFTC[@]}" -O -parse-as-library -target $arch-apple-macos14.0 WinMac.swift -o build/WinMac-$arch ||
    use_prebuilt "erro do compilador Swift"
done
lipo -create build/WinMac-arm64 build/WinMac-x86_64 -output "$APP/Contents/MacOS/WinMac"
"${SWIFTC[@]}" makeicon.swift -o build/makeicon && build/makeicon build/WinMac.iconset && iconutil -c icns build/WinMac.iconset -o "$APP/Contents/Resources/WinMac.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>WinMac</string>
<key>CFBundleShortVersionString</key><string>$(cat ../VERSION 2>/dev/null || echo 0)</string>
<key>CFBundleDisplayName</key><string>WinMac</string>
<key>CFBundleIdentifier</key><string>local.winmac.app</string>
<key>CFBundleExecutable</key><string>WinMac</string>
<key>CFBundleIconFile</key><string>WinMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
[ "$1" = "--no-install" ] && { echo "Compilado em $(pwd)/$APP"; exit 0; }
mkdir -p "$HOME/winmac/Bottles" && cp ../winmac "$HOME/winmac/winmac" && chmod +x "$HOME/winmac/winmac"
mkdir -p "$HOME/winmac/tools" && cp ../tools/steamwebhelper-wrap.exe ../tools/winmac-transparent.dylib ../tools/winmac-dxmt.dylib "$HOME/winmac/tools/"
rm -rf /Applications/WinMac.app && cp -R "$APP" /Applications/
echo "Instalado em /Applications/WinMac.app"
