// winmac-progman.exe — a "área de trabalho" do Windows que o Wine do macOS não tem.
// Programas de papel de parede animado (ex.: Wallpaper Engine) procuram a janela "Progman" do Explorer,
// mandam a mensagem 0x052C e desenham dentro da "WorkerW" que fica atrás dos ícones. Sem a Progman eles
// esperam para sempre. Este programa cria essas janelas, invisíveis; quem aparece é a janela que o
// winmac-dxmt.dylib cria para o Wallpaper Engine no nível do papel de parede do macOS.
#include <windows.h>

static HWND progman, icons, worker;

// Como no Windows 10 depois da mensagem 0x052C: uma WorkerW com os ícones (SHELLDLL_DefView) e,
// logo abaixo dela, a WorkerW vazia onde o papel de parede é desenhado.
static void make_worker(HINSTANCE inst) {
    // Recria a cada 0x052C: se um Wallpaper Engine anterior foi fechado à força, as WorkerW velhas
    // fazem o próximo esperar para sempre
    if (worker) { HWND w = worker, i = icons; worker = icons = NULL; DestroyWindow(w); DestroyWindow(i); }
    int w = GetSystemMetrics(SM_CXSCREEN), h = GetSystemMetrics(SM_CYSCREEN);
    worker = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"WorkerW", L"WinMac Wallpaper",
                             WS_POPUP | WS_CLIPCHILDREN, 0, 0, w, h, NULL, NULL, inst, NULL);
    icons = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"WorkerW", L"", WS_POPUP, 0, 0, w, h, NULL, NULL, inst, NULL);
    HWND defview = CreateWindowExW(0, L"SHELLDLL_DefView", L"", WS_CHILD, 0, 0, w, h, icons, NULL, inst, NULL);
    CreateWindowExW(0, L"SysListView32", L"FolderView", WS_CHILD, 0, 0, w, h, defview, NULL, inst, NULL);
    // Ordem de cima para baixo: ícones, papel de parede, Progman
    SetWindowPos(worker, icons, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    SetWindowPos(progman, worker, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

static LRESULT CALLBACK proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == 0x052C && hwnd == progman) {
        make_worker((HINSTANCE)GetWindowLongPtrW(hwnd, GWLP_HINSTANCE));
        return 0;
    }
    // As WorkerW nunca aparecem: no Mac viraria uma janela preta por cima de tudo. O Wallpaper Engine
    // desenha numa janela própria no nível do papel de parede (ver dxmt_shim.m).
    if (msg == WM_WINDOWPOSCHANGING && (hwnd == worker || hwnd == icons)) {
        ((WINDOWPOS *)lp)->flags &= ~SWP_SHOWWINDOW;
        return 0;
    }
    if (msg == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, LPWSTR cmd, int show) {
    // Uma só cópia por bottle
    if (FindWindowW(L"Progman", NULL)) return 0;
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = proc; wc.hInstance = inst; wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    const wchar_t *names[] = {L"Progman", L"WorkerW", L"SHELLDLL_DefView", L"SysListView32"};
    for (int i = 0; i < 4; i++) { wc.lpszClassName = names[i]; RegisterClassW(&wc); }

    int w = GetSystemMetrics(SM_CXSCREEN), h = GetSystemMetrics(SM_CYSCREEN);
    // Progman invisível (só recebe a mensagem 0x052C)
    progman = CreateWindowExW(WS_EX_TOOLWINDOW, L"Progman", L"Program Manager", WS_POPUP,
                              0, 0, w, h, NULL, NULL, inst, NULL);
    make_worker(inst);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    return 0;
}
