#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

// NOTE(zaddish): if CRT is shit later on if this becomes fucked, then just remove it
// for now im lazy and we can just use the CRT, just make sure you fix up the MSVC bs that comes with strncpy_s etc
#include <windows.h>
#include <stdio.h>
#include <string.h>

// helpers

static FILETIME GetLastWriteTime(const char *Path) {
    FILETIME Result = {};
    WIN32_FILE_ATTRIBUTE_DATA Data;
    if(GetFileAttributesExA(Path, GetFileExInfoStandard, &Data)) {
        Result = Data.ftLastWriteTime;
    }
    return(Result);
}

static int FileExists(const char *Path) {
    DWORD Attr = GetFileAttributesA(Path);
    return (Attr != INVALID_FILE_ATTRIBUTES && !(Attr & FILE_ATTRIBUTE_DIRECTORY));
}

static int IsFileNewer(const char *A, const char *B) {
    FILETIME TimeA = GetLastWriteTime(A);
    FILETIME TimeB = GetLastWriteTime(B);
    return CompareFileTime(&TimeA, &TimeB) > 0;
}

struct process_handle {
    HANDLE Process;
    HANDLE Thread;
};

static process_handle LaunchProcess(const char *Cmd, STARTUPINFOA *Si) {
    process_handle Result = {};
    char CmdBuf[4096];
    strncpy_s(CmdBuf, sizeof(CmdBuf), Cmd, _TRUNCATE);
    CmdBuf[sizeof(CmdBuf) - 1] = 0;

    BOOL Inherit = (Si->dwFlags & STARTF_USESTDHANDLES) ? TRUE : FALSE;
    PROCESS_INFORMATION Pi = {};
    if(CreateProcessA(0, CmdBuf, 0, 0, Inherit, 0, 0, 0, Si, &Pi)) {
        Result.Process = Pi.hProcess;
        Result.Thread = Pi.hThread;
    }
    return(Result);
}

static DWORD FinishProcess(process_handle *P) {
    if(!P->Process) return (DWORD)-1;
    WaitForSingleObject(P->Process, INFINITE);
    DWORD ExitCode = 0;
    GetExitCodeProcess(P->Process, &ExitCode);
    CloseHandle(P->Process);
    CloseHandle(P->Thread);
    *P = {};
    return ExitCode;
}

static DWORD RunProcess(const char *Cmd) {
    STARTUPINFOA Si = {};
    Si.cb = sizeof(Si);
    process_handle P = LaunchProcess(Cmd, &Si);
    return FinishProcess(&P);
}

struct captured_output {
    char  Text[4096];
    int   Len;
    DWORD ExitCode;
};

static captured_output RunProcessCapture(const char *Cmd) {
    captured_output Result = {};
    Result.ExitCode = (DWORD)-1;

    SECURITY_ATTRIBUTES Sa = {};
    Sa.nLength = sizeof(Sa);
    Sa.bInheritHandle = TRUE;

    HANDLE ReadPipe, WritePipe;
    if(!CreatePipe(&ReadPipe, &WritePipe, &Sa, 0)) return(Result);
    SetHandleInformation(ReadPipe, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA Si = {};
    Si.cb = sizeof(Si);
    Si.dwFlags = STARTF_USESTDHANDLES;
    Si.hStdOutput = WritePipe;
    Si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    Si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    process_handle P = LaunchProcess(Cmd, &Si);
    CloseHandle(WritePipe);

    if(!P.Process) {
        CloseHandle(ReadPipe);
        return(Result);
    }

    DWORD BytesRead;
    while(Result.Len < (int)(sizeof(Result.Text) - 1)) {
        DWORD ToRead = (DWORD)(sizeof(Result.Text) - 1 - Result.Len);
        if(!ReadFile(ReadPipe, Result.Text + Result.Len, ToRead, &BytesRead, 0) || BytesRead == 0) break;
        Result.Len += (int)BytesRead;
    }
    Result.Text[Result.Len] = 0;

    while(Result.Len > 0 && (Result.Text[Result.Len - 1] == '\n' || Result.Text[Result.Len - 1] == '\r')) {
        Result.Len--;
        Result.Text[Result.Len] = 0;
    }

    CloseHandle(ReadPipe);
    Result.ExitCode = FinishProcess(&P);
    return(Result);
}

static int WriteFileIfChanged(const char *Path, const char *Data, int DataLen) {
    HANDLE Existing = CreateFileA(Path, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, 0, 0);
    if(Existing != INVALID_HANDLE_VALUE) {
        DWORD Size = GetFileSize(Existing, 0);
        if((int)Size == DataLen && DataLen <= 8192) {
            char Buf[8192];
            DWORD Read;
            if(ReadFile(Existing, Buf, Size, &Read, 0) && (int)Read == DataLen) {
                if(memcmp(Buf, Data, DataLen) == 0) {
                    CloseHandle(Existing);
                    return(0);
                }
            }
        }
        CloseHandle(Existing);
    }

    HANDLE File = CreateFileA(Path, GENERIC_WRITE, 0, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if(File == INVALID_HANDLE_VALUE) return -1;
    DWORD Written;
    WriteFile(File, Data, DataLen, &Written, 0);
    CloseHandle(File);
    return 1;
}

static void DeleteObjFiles(void) {
    WIN32_FIND_DATAA Fd;
    HANDLE Find = FindFirstFileA("*.obj", &Fd);
    if(Find != INVALID_HANDLE_VALUE) {
        do { DeleteFileA(Fd.cFileName); } while(FindNextFileA(Find, &Fd));
        FindClose(Find);
    }
}

// self rebuild

static int MaybeSelfRebuild(const char *Argv0, const char *SourcePath, int Argc, char **Argv) {
    char ExePath[MAX_PATH];
    GetModuleFileNameA(0, ExePath, MAX_PATH);

    if(!IsFileNewer(SourcePath, ExePath)) return 0;

    printf("[build] build.cpp changed, recompiling build.exe...\n");

    char TempExe[MAX_PATH];
    snprintf(TempExe, sizeof(TempExe), "%.*s_new.exe", (int)(strlen(ExePath) - 4), ExePath);

    char Cmd[4096];
    snprintf(Cmd, sizeof(Cmd), "cl /nologo /O2 /Fe:\"%s\" \"%s\" /link kernel32.lib advapi32.lib shell32.lib", TempExe, SourcePath);

    DWORD Code = RunProcess(Cmd);
    if(Code != 0) {
        printf("[build] ERROR: self rebuild failed (cl exit %lu)\n", Code);
        return -1;
    }

    DeleteObjFiles();

    if(!MoveFileExA(TempExe, ExePath, MOVEFILE_REPLACE_EXISTING)) {
        char PdbOld[MAX_PATH], PdbNew[MAX_PATH];
        snprintf(PdbOld, sizeof(PdbOld), "%.*s.pdb", (int)(strlen(ExePath) - 4), ExePath);
        snprintf(PdbNew, sizeof(PdbNew), "%.*s_new.pdb", (int)(strlen(ExePath) - 4), ExePath);
        DeleteFileA(PdbOld);
        MoveFileExA(PdbNew, PdbOld, MOVEFILE_REPLACE_EXISTING);

        char OldExeRenamed[MAX_PATH];
        snprintf(OldExeRenamed, sizeof(OldExeRenamed), "%.*s_old.exe", (int)(strlen(ExePath) - 4), ExePath);
        MoveFileExA(ExePath, OldExeRenamed, MOVEFILE_REPLACE_EXISTING);
        MoveFileExA(TempExe, ExePath, MOVEFILE_REPLACE_EXISTING);
        MoveFileExA(OldExeRenamed, 0, MOVEFILE_DELAY_UNTIL_REBOOT);
    }

    char NewCmd[4096];
    int Off = snprintf(NewCmd, sizeof(NewCmd), "\"%s\"", ExePath);
    for(int i = 1; i < Argc; i++) {
        Off += snprintf(NewCmd + Off, sizeof(NewCmd) - Off, " %s", Argv[i]);
    }

    STARTUPINFOA Si = {};
    Si.cb = sizeof(Si);
    process_handle P = LaunchProcess(NewCmd, &Si);
    if(!P.Process) {
        printf("[build] ERROR: failed to re-exec build.exe\n");
        return -1;
    }
    DWORD ReExecCode = FinishProcess(&P);
    return (int)ReExecCode + 1;
}

// git stuff

static int GenerateBuildInfo(const char *OutputPath) {
    captured_output ShortHash = RunProcessCapture("git describe --always --dirty");
    captured_output FullHash  = RunProcessCapture("git rev-parse HEAD");

    const char *Short = (ShortHash.ExitCode == 0 && ShortHash.Len > 0) ? ShortHash.Text : "unknown";
    const char *Full  = (FullHash.ExitCode == 0 && FullHash.Len > 0) ? FullHash.Text : "unknown";

    char Content[4096];
    int ContentLen = snprintf(Content, sizeof(Content),
        "// Generated by build.exe\n"
        "static const char    BuildGitHash[]     = \"%s\";\n"
        "static const wchar_t BuildGitHashW[]    = L\"%s\";\n"
        "static const char    BuildGitHashFull[] = \"%s\";\n",
        Short, Short, Full);

    int Changed = WriteFileIfChanged(OutputPath, Content, ContentLen);
    if(Changed > 0) {
        printf("[build] build_info.h updated (%s)\n", Short);
    } else if(Changed == 0) {
        printf("[build] build_info.h up to date (%s)\n", Short);
    } else {
        printf("[build] ERROR: failed to write build_info.h\n");
        return 0;
    }
    return 1;
}

// shader cache

struct shader_entry {
    const char *Target;
    const char *Entry;
    const char *Output;
    const char *VarName;
    const char *Source;
    const char *Label;
};

static shader_entry Shaders[] = {
    { "vs_5_0", "VSMain", "betterss_vs.h",        "BetterSSVSBytes",        "betterss_overlay.hlsl", "Overlay VS" },
    { "ps_5_0", "PSMain", "betterss_ps.h",        "BetterSSPSBytes",        "betterss_overlay.hlsl", "Overlay PS" },
    { "vs_5_0", "VSMain", "betterss_line_vs.h",   "BetterSSLineVSBytes",    "betterss_line.hlsl",    "Line VS" },
    { "ps_5_0", "PSMain", "betterss_line_ps.h",   "BetterSSLinePSBytes",    "betterss_line.hlsl",    "Line PS" },
    { "ps_5_0", "PSMain", "betterss_composite_ps.h","BetterSSCompositePSBytes","betterss_composite.hlsl","Composite PS" },
};

static int CompileShaders(const char *SrcDir) {
    int Compiled = 0;
    int Failed = 0;

    for(int i = 0; i < (int)(sizeof(Shaders) / sizeof(Shaders[0])); i++) {
        shader_entry *S = &Shaders[i];

        char SourcePath[MAX_PATH], OutputPath[MAX_PATH];
        snprintf(SourcePath, sizeof(SourcePath), "%s\\%s", SrcDir, S->Source);
        snprintf(OutputPath, sizeof(OutputPath), "%s\\%s", SrcDir, S->Output);

        if(FileExists(OutputPath) && !IsFileNewer(SourcePath, OutputPath)) {
            continue;
        }

        printf("[build] compiling %s...\n", S->Label);

        char Cmd[4096];
        snprintf(Cmd, sizeof(Cmd),
            "fxc /nologo /T %s /E %s /O3 /WX /Fh \"%s\" /Vn %s \"%s\"",
            S->Target, S->Entry, OutputPath, S->VarName, SourcePath);

        DWORD Code = RunProcess(Cmd);
        if(Code != 0) {
            printf("[build] ERROR: %s shader compilation failed\n", S->Label);
            Failed = 1;
            break;
        }
        Compiled++;
    }

    if(!Failed) {
        if(Compiled == 0) printf("[build] shaders up to date\n");
        else              printf("[build] %d shader(s) compiled\n", Compiled);
    }

    return !Failed;
}

// main -------

int main(int Argc, char **Argv) {
    char RootDir[MAX_PATH];
    GetModuleFileNameA(0, RootDir, MAX_PATH);
    char *LastSlash = 0;
    for(char *P = RootDir; *P; P++) { if(*P == '\\' || *P == '/') LastSlash = P; }
    if(LastSlash) *LastSlash = 0;
    SetCurrentDirectoryA(RootDir);

    char BuildCppPath[MAX_PATH];
    snprintf(BuildCppPath, sizeof(BuildCppPath), "%s\\build.cpp", RootDir);

    int RebuildResult = MaybeSelfRebuild(Argv[0], BuildCppPath, Argc, Argv);
    if(RebuildResult != 0) {
        return (RebuildResult > 0) ? RebuildResult - 1 : 1;
    }

    int IsDebug = 1;
    int IsRelease = 0;

    for(int i = 1; i < Argc; i++) {
        if(_stricmp(Argv[i], "release") == 0) { IsRelease = 1; IsDebug = 0; }
        if(_stricmp(Argv[i], "debug") == 0)   { IsDebug = 1; IsRelease = 0; }
    }

    printf("[build] %s build\n", IsRelease ? "RELEASE" : "DEBUG");

    CreateDirectoryA("build", 0);

    char SrcDir[MAX_PATH];
    snprintf(SrcDir, sizeof(SrcDir), "%s\\src", RootDir);

    if(!CompileShaders(SrcDir)) return 1;

    char BuildInfoPath[MAX_PATH];
    snprintf(BuildInfoPath, sizeof(BuildInfoPath), "%s\\build_info.h", SrcDir);
    if(!GenerateBuildInfo(BuildInfoPath)) return 1;

    const char *OutName = IsDebug ? "build\\betterss_debug.exe" : "build\\betterss.exe";

    char Cmd[4096];
    int Off = snprintf(Cmd, sizeof(Cmd),
        "cl /nologo /W3 /WX /GS- /Gs999999 /Gm- /GR- /EHsc /Oi "
        "%s "
        "/Fe\"%s\" src\\betterss.cpp "
        "/link /incremental:no /opt:icf /opt:ref /subsystem:windows "
        "/entry:WinMainCRTStartup /nodefaultlib "
        "kernel32.lib user32.lib gdi32.lib dwmapi.lib d3d11.lib dxgi.lib "
        "dxguid.lib ole32.lib shell32.lib advapi32.lib comdlg32.lib windowscodecs.lib",
        IsDebug ? "/Od /Z7 /D_DEBUG" : "/O2 /DNDEBUG",
        OutName);
    if(IsDebug) {
        snprintf(Cmd + Off, sizeof(Cmd) - Off, " /debug");
    }

    printf("[build] compiling betterss...\n");
    DWORD Code = RunProcess(Cmd);

    DeleteObjFiles();

    if(Code != 0) {
        printf("[build] ERROR: cl.exe failed (exit %lu)\n", Code);
        return 1;
    }

    printf("[build] done: %s\n", OutName);
    return 0;
}