:: please see build.cpp for builds

@echo off
cd /D "%~dp0"
if not exist build.exe (
    echo bootstrapping build.exe...
    cl /nologo /O2 /Fe:build.exe build.cpp /link kernel32.lib advapi32.lib shell32.lib || exit /b 1
    del /q *.obj 2>nul
)
build.exe %*
