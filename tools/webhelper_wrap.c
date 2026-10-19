// Embrulho do steamwebhelper.exe: chama o original (steamwebhelper_real.exe) com opções extras do Chromium.
#include <windows.h>
#include <wchar.h>
#include <stdio.h>
int wmain(void) {
    wchar_t self[MAX_PATH], real[MAX_PATH], extra[2048] = L"", cmd[32768];
    GetModuleFileNameW(NULL, self, MAX_PATH);
    wcscpy(real, self);
    wchar_t *dot = wcsrchr(real, L'.'); wcscpy(dot, L"_real.exe");
    // opções extras lidas de winmac_flags.txt ao lado do exe (uma linha)
    wchar_t flagsPath[MAX_PATH]; wcscpy(flagsPath, self); wcscpy(wcsrchr(flagsPath, L'\\') + 1, L"winmac_flags.txt");
    FILE *f = _wfopen(flagsPath, L"r, ccs=UTF-8");
    if (f) { fgetws(extra, 2048, f); fclose(f); extra[wcscspn(extra, L"\r\n")] = 0; }
    // argumentos originais (sem o nome do programa)
    wchar_t *args = GetCommandLineW();
    if (*args == L'"') { args = wcschr(args + 1, L'"'); args = args ? args + 1 : L""; }
    else { while (*args && *args != L' ') args++; }
    swprintf(cmd, 32768, L"\"%ls\"%ls %ls", real, args, extra);
    STARTUPINFOW si = { sizeof si }; PROCESS_INFORMATION pi;
    if (!CreateProcessW(real, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) return 1;
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0; GetExitCodeProcess(pi.hProcess, &code);
    return (int)code;
}
