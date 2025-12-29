@echo off
setlocal enabledelayedexpansion

:: BetterSS Build Script

where /q cl || (
    echo ERROR: cl not found - run from Visual Studio Developer Command Prompt
    exit /b 1
)

where /q fxc || (
    echo ERROR: fxc not found - Windows SDK required
    exit /b 1
)

if not exist build mkdir build

pushd src

:: Compile shaders
echo Compiling shaders...
fxc /nologo /T vs_5_0 /E VSMain /O3 /WX /Fh betterss_vs.h /Vn BetterSSVSBytes betterss_overlay.hlsl
if errorlevel 1 (
    echo ERROR: Vertex shader compilation failed
    popd
    exit /b 1
)

fxc /nologo /T ps_5_0 /E PSMain /O3 /WX /Fh betterss_ps.h /Vn BetterSSPSBytes betterss_overlay.hlsl
if errorlevel 1 (
    echo ERROR: Pixel shader compilation failed
    popd
    exit /b 1
)

fxc /nologo /T vs_5_0 /E VSMain /O3 /WX /Fh betterss_line_vs.h /Vn BetterSSLineVSBytes betterss_line.hlsl
if errorlevel 1 (
    echo ERROR: Line vertex shader compilation failed
    popd
    exit /b 1
)

fxc /nologo /T ps_5_0 /E PSMain /O3 /WX /Fh betterss_line_ps.h /Vn BetterSSLinePSBytes betterss_line.hlsl
if errorlevel 1 (
    echo ERROR: Line pixel shader compilation failed
    popd
    exit /b 1
)

popd

:: Compiler flags
set CFLAGS=/nologo /W3 /WX /GS- /Gs999999 /Gm- /GR- /EHsc /Oi

:: Linker flags
set LDFLAGS=/incremental:no /opt:icf /opt:ref /subsystem:windows /entry:WinMainCRTStartup /nodefaultlib kernel32.lib user32.lib gdi32.lib dwmapi.lib d3d11.lib dxgi.lib dxguid.lib ole32.lib shell32.lib advapi32.lib comdlg32.lib windowscodecs.lib

:: Debug vs Release
if "%1"=="debug" (
    echo Building DEBUG...
    set CFLAGS=%CFLAGS% /Od /Z7 /D_DEBUG
    set LDFLAGS=%LDFLAGS% /debug
    set OUT=build\betterss_debug.exe
) else (
    echo Building RELEASE...
    set CFLAGS=%CFLAGS% /O2 /DNDEBUG
    set OUT=build\betterss.exe
)

:: Compile
cl %CFLAGS% /Fe%OUT% src\betterss.cpp /link %LDFLAGS%
if errorlevel 1 (
    echo ERROR: Compilation failed
    exit /b 1
)

:: Clean up obj files
del /q *.obj 2>nul

echo Build complete: %OUT%
exit /b 0
