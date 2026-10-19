# WinMac

Um launcher simples e gratuito para rodar jogos Windows da Steam no macOS usando o [Wine](https://www.winehq.org/).

O WinMac é um app SwiftUI com uma lista de bottles, um botão para abrir a Steam e uma grade com as capas dos jogos instalados. Também vem com o comando de terminal `winmac`.

> O WinMac não tem nenhum código do CrossOver e não tem relação com a CodeWeavers. Ele só abre o Wine open source em prefixos (bottles) comuns. Ele **lê** bottles já existentes do CrossOver, porque eles são prefixos Wine normais.

## Instalação (fácil, sem compilar)

Abra o Terminal e cole:

```bash
curl -fsSL https://raw.githubusercontent.com/Yohotaco/winmac/main/install.sh | bash
```

O WinMac abre sozinho no final. Clique em **Instalar Steam**: o app baixa o [Wine Staging](https://github.com/Gcenx/macOS_Wine_builds/releases), o DXVK e o instalador oficial da Steam direto da Valve. Depois é só clicar em **Abrir Steam** e entrar na sua conta.

Requisitos: macOS 14 ou mais novo, internet e uns 2 GB livres (fora os jogos). Nos Macs com chip Apple, o instalador também instala o Rosetta 2.

## Instalação (compilando)

Precisa das ferramentas de linha de comando do Xcode (`xcode-select --install`).

```bash
git clone https://github.com/Yohotaco/winmac.git ~/winmac-src
~/winmac-src/app/build.sh   # instala /Applications/WinMac.app e ~/winmac/winmac
```

Se aparecer `this SDK is not supported by the compiler`, as ferramentas da Apple estão desencontradas. O `build.sh` tenta outro SDK sozinho; se não houver nenhum compatível, use a instalação fácil acima ou reinstale as ferramentas: `sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`.

Para usar o comando no terminal: `ln -sf ~/winmac/winmac /opt/homebrew/bin/winmac`

## Uso

| Comando | O que faz |
|---|---|
| `winmac setup [bottle]` | Instala o Wine e a Steam oficial num bottle novo |
| `winmac list` | Lista os bottles e os jogos da Steam |
| `winmac steam [bottle]` | Abre a Steam |
| `winmac play <appid\|nome>` | Abre um jogo pela Steam |
| `winmac run <exe> [bottle]` | Roda qualquer `.exe` |
| `winmac migrate [bottle]` | Move um bottle do CrossOver para `~/winmac/Bottles` e deixa um atalho no lugar antigo |
| `winmac kill [bottle]` | Fecha tudo que está rodando no bottle |

Os bottles ficam em `~/winmac/Bottles/<nome>`. Se a pasta não existir, o WinMac procura em `~/Library/Application Support/CrossOver/Bottles/<nome>`.

## Limitações

- DirectX 10/11 roda pelo [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS), que o WinMac instala sozinho em cada bottle. DirectX 12 não é suportado (não tem D3DMetal).
- Bottles vindos do CrossOver: o WinMac guarda as DLLs de GPU específicas do CrossOver em `~/winmac/crossover-dlls/`, porque elas derrubam o Wine comum.
- Jogos com anti-cheat em modo kernel (EA Javelin, Vanguard, etc.) não funcionam.
- Não use o mesmo bottle no CrossOver e no WinMac ao mesmo tempo.

## Como a tela preta da Steam foi resolvida

No Wine do macOS, o navegador interno da Steam (`steamwebhelper.exe`) desenha pela GPU, e a janela fica preta. O WinMac troca esse arquivo por um embrulho pequeno ([`tools/webhelper_wrap.c`](tools/webhelper_wrap.c)) que abre o original (`steamwebhelper_real.exe`) com opções do Chromium para desenhar por software:

```
--disable-gpu --disable-gpu-compositing --in-process-gpu --disable-features=CalculateNativeWinOcclusion --disable-direct-composition
```

A Steam é aberta com `-noverifyfiles` para não desfazer o embrulho. Se uma atualização da Steam trocar o arquivo, o `winmac` reaplica o embrulho na próxima vez que abrir a Steam.

Para recompilar o embrulho: `x86_64-w64-mingw32-gcc -O2 -municode -o tools/steamwebhelper-wrap.exe tools/webhelper_wrap.c`

## Licença

MIT
