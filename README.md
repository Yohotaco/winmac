# WinMac

Um launcher simples e gratuito para rodar jogos Windows da Steam no macOS usando o [Wine](https://www.winehq.org/).

O WinMac é um app SwiftUI com uma lista de bottles, um botão para abrir a Steam e uma grade com as capas dos jogos instalados. Também vem com o comando de terminal `winmac`.

> O WinMac não tem nenhum código do CrossOver e não tem relação com a CodeWeavers. Ele só abre o Wine open source em prefixos (bottles) comuns. Ele **lê** bottles já existentes do CrossOver, porque eles são prefixos Wine normais.

## Requisitos

- macOS 14 ou mais novo (Apple Silicon precisa do Rosetta 2)
- Ferramentas de linha de comando do Xcode, para compilar o app (`xcode-select --install`)
- [Wine Staging para macOS](https://github.com/Gcenx/macOS_Wine_builds/releases) instalado em `/Applications/Wine Staging.app`

## Instalação

```bash
git clone https://github.com/Yohotaco/winmac.git ~/winmac-src
mkdir -p ~/winmac/Bottles
cp ~/winmac-src/winmac ~/winmac/winmac && chmod +x ~/winmac/winmac
ln -sf ~/winmac/winmac /opt/homebrew/bin/winmac
~/winmac-src/app/build.sh   # instala /Applications/WinMac.app
```

## Uso

| Comando | O que faz |
|---|---|
| `winmac list` | Lista os bottles e os jogos da Steam |
| `winmac steam [bottle]` | Abre a Steam |
| `winmac play <appid\|nome>` | Abre um jogo pela Steam |
| `winmac run <exe> [bottle]` | Roda qualquer `.exe` |
| `winmac migrate [bottle]` | Move um bottle do CrossOver para `~/winmac/Bottles` e deixa um atalho no lugar antigo |
| `winmac kill [bottle]` | Fecha tudo que está rodando no bottle |

Os bottles ficam em `~/winmac/Bottles/<nome>`. Se a pasta não existir, o WinMac procura em `~/Library/Application Support/CrossOver/Bottles/<nome>`.

## Limitações

- Não tem D3DMetal: jogos DirectX 11/12 podem rodar mais lentos que no CrossOver, ou nem abrir.
- Jogos com anti-cheat em modo kernel (EA Javelin, Vanguard, etc.) não funcionam.
- Não use o mesmo bottle no CrossOver e no WinMac ao mesmo tempo.

## Licença

MIT
