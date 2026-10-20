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

## Steam do Mac e Steam do CrossOver

- **Steam do Mac:** se você tem a Steam nativa do macOS, os jogos dela aparecem no WinMac na seção **Steam do Mac** e abrem pela própria Steam do Mac, na versão nativa (os saves continuam os mesmos). O login da Steam do WinMac é separado: entre uma vez na conta (o QR code do app Steam no celular é o jeito mais rápido); depois a Steam Cloud traz os saves dos jogos.
- **Steam do CrossOver:** ao clicar em **Instalar Steam**, se existir uma Steam num bottle do CrossOver, o WinMac traz esse bottle (jogos, saves e login) em vez de instalar outra. Também dá para rodar `winmac import`.

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

Para recompilar o embrulho: `x86_64-w64-mingw32-gcc -O2 -municode -mwindows -o tools/steamwebhelper-wrap.exe tools/webhelper_wrap.c`

## Jogos "overlay" com fundo transparente

Alguns jogos (como *How to Train Your Cock* / *Como Treinar o Seu Pinto*) ficam por cima da área de trabalho com o fundo transparente. No Windows eles usam `DwmExtendFrameIntoClientArea`, que o Wine do macOS não implementa, e o fundo fica preto.

O WinMac resolve com [`tools/transparent.m`](tools/transparent.m), um módulo do macOS carregado nos processos do Wine (`DYLD_INSERT_LIBRARIES`). Só nesses jogos, ele:

- deixa a janela Cocoa e a camada Metal não opacas (fundo transparente);
- coloca a janela acima de todos os apps e em todos os Spaces, inclusive sobre apps em tela cheia. Para isso o processo do jogo vira um app "acessório", sem ícone no Dock nem no Cmd+Tab;
- deixa os cliques atravessarem as partes transparentes: ele lê o alfa do pixel embaixo do mouse no último quadro desenhado. Se não conseguir ler, deixa o clique passar, para nunca prender a tela.

O `winmac` detecta os jogos Unity que usam `DwmExtendFrameIntoClientArea` e só ativa o módulo neles. Se a Steam já estava aberta antes de instalar um jogo desses, feche e abra a Steam pelo WinMac de novo.

Para recompilar o módulo: `clang -arch x86_64 -dynamiclib -fobjc-arc -framework Foundation -framework QuartzCore -framework Metal -o tools/winmac-transparent.dylib tools/transparent.m && codesign -s - -f tools/winmac-transparent.dylib`

## Licença

MIT
