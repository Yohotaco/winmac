// Embrulho do LosslessScaling.exe. O Lossless Scaling fecha ao abrir no Wine: ele captura a tela com funções
// que só o Windows tem. Quando a Steam abre o Lossless Scaling, este embrulho abre no lugar a janela de
// quadros extras do WinMac (WinMac Quadros), que faz a mesma geração de quadros pelo macOS.
// O Wine consegue abrir programas do Mac pelo CreateProcess (caminho Z:\...): roda "winmac fg" pelo bash.
// O original fica guardado como LosslessScaling_real.exe (o winmac põe e tira o embrulho).
//
// Compilar: x86_64-w64-mingw32-gcc -Os -s -municode -mwindows -o tools/lossless-wrap.exe tools/lossless_wrap.c
#include <windows.h>

// O winmac reconhece o embrulho por esta marca (o original da Steam não tem)
__attribute__((used)) static const char marker[] = "WINMAC_LOSSLESS_WRAP";

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, LPWSTR args, int show) {
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    // argv do Mac: bash -c "exec "$HOME/winmac/winmac" fg"
    wchar_t cmd[] = L"bash -c \"exec \\\"$HOME/winmac/winmac\\\" fg\"";
    if (!CreateProcessW(L"Z:\\bin\\bash", cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        MessageBoxW(NULL, L"O Lossless Scaling não roda no Wine. Abra os quadros extras pelo app WinMac.",
                    L"WinMac", MB_OK | MB_ICONINFORMATION);
        return 1;
    }
    WaitForSingleObject(pi.hProcess, 15000);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;
}
