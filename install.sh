#!/bin/bash
# Instala o WinMac sem precisar compilar nada.
# Uso: curl -fsSL https://raw.githubusercontent.com/Yohotaco/winmac/main/install.sh | bash
set -e
REPO="https://github.com/Yohotaco/winmac"
RAW="https://raw.githubusercontent.com/Yohotaco/winmac/main"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> Instalando o WinMac"

# O Wine roda em modo Intel; nos Macs com chip Apple ele precisa do Rosetta 2
if [ "$(uname -m)" = "arm64" ] && ! pgrep -q oahd; then
  echo "==> Instalando o Rosetta 2 (pode pedir sua senha)"
  softwareupdate --install-rosetta --agree-to-license
fi

echo "==> Baixando o app"
curl -fL# -o "$TMP/WinMac.zip" "$REPO/releases/latest/download/WinMac.zip"
ditto -x -k "$TMP/WinMac.zip" "$TMP"
rm -rf /Applications/WinMac.app
mv "$TMP/WinMac.app" /Applications/

echo "==> Baixando o comando winmac"
mkdir -p "$HOME/winmac/Bottles" "$HOME/winmac/tools"
curl -fsL -o "$HOME/winmac/winmac" "$RAW/winmac"
chmod +x "$HOME/winmac/winmac"
curl -fsL -o "$HOME/winmac/tools/steamwebhelper-wrap.exe" "$RAW/tools/steamwebhelper-wrap.exe"
curl -fsL -o "$HOME/winmac/tools/winmac-transparent.dylib" "$RAW/tools/winmac-transparent.dylib"
curl -fsL -o "$HOME/winmac/tools/winmac-dxmt.dylib" "$RAW/tools/winmac-dxmt.dylib"

echo "==> Pronto! Abrindo o WinMac. Clique em \"Instalar Steam\"."
open /Applications/WinMac.app
