#!/bin/bash
# Instala o WinMac sem precisar compilar nada.
# Uso: curl -fsSL https://raw.githubusercontent.com/Yohotaco/winmac/main/install.sh | bash
set -e
REPO="https://github.com/Yohotaco/winmac"
# Arquivos da última versão publicada (a mesma do app), não do main
TAG=$(curl -fsL https://api.github.com/repos/Yohotaco/winmac/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
RAW="https://raw.githubusercontent.com/Yohotaco/winmac/${TAG:-main}"
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
# Sem permissão para /Applications (conta sem administrador ou app antigo de outro usuário):
# instala em ~/Applications, que aparece no Launchpad do mesmo jeito
DEST=/Applications
if ! { rm -rf "$DEST/WinMac.app" && mv "$TMP/WinMac.app" "$DEST/"; } 2>/dev/null; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST" && rm -rf "$DEST/WinMac.app" && mv "$TMP/WinMac.app" "$DEST/"
fi
echo "==> App instalado em $DEST/WinMac.app"

echo "==> Baixando o comando winmac"
mkdir -p "$HOME/winmac/Bottles" "$HOME/winmac/tools" 2>/dev/null && [ -w "$HOME/winmac" ] || {
  echo "Sem permissão na pasta ~/winmac (talvez criada com sudo). Rode isto e depois o instalador de novo:"
  echo "  sudo chown -R \"$USER\" \"$HOME/winmac\""
  exit 1
}
curl -fsL -o "$HOME/winmac/winmac" "$RAW/winmac"
chmod +x "$HOME/winmac/winmac"
curl -fsL -o "$HOME/winmac/tools/steamwebhelper-wrap.exe" "$RAW/tools/steamwebhelper-wrap.exe"
curl -fsL -o "$HOME/winmac/tools/winmac-transparent.dylib" "$RAW/tools/winmac-transparent.dylib"
curl -fsL -o "$HOME/winmac/tools/winmac-dxmt.dylib" "$RAW/tools/winmac-dxmt.dylib"

echo "==> Pronto! Abrindo o WinMac. Clique em \"Instalar Steam\"."
open "$DEST/WinMac.app"
