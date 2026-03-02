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

call :compile_shader vs_5_0 VSMain betterss_vs.h BetterSSVSBytes betterss_overlay.hlsl "Overlay VS" || (popd & exit /b 1)
call :compile_shader ps_5_0 PSMain betterss_ps.h BetterSSPSBytes betterss_overlay.hlsl "Overlay PS" || (popd & exit /b 1)
call :compile_shader vs_5_0 VSMain betterss_line_vs.h BetterSSLineVSBytes betterss_line.hlsl "Line VS" || (popd & exit /b 1)
call :compile_shader ps_5_0 PSMain betterss_line_ps.h BetterSSLinePSBytes betterss_line.hlsl "Line PS" || (popd & exit /b 1)
call :compile_shader ps_5_0 PSMain betterss_composite_ps.h BetterSSCompositePSBytes betterss_composite.hlsl "Composite PS" || (popd & exit /b 1)

popd

set CFLAGS=/nologo /W3 /WX /GS- /Gs999999 /Gm- /GR- /EHsc /Oi
set LDFLAGS=/incremental:no /opt:icf /opt:ref /subsystem:windows /entry:WinMainCRTStartup /nodefaultlib kernel32.lib user32.lib gdi32.lib dwmapi.lib d3d11.lib dxgi.lib dxguid.lib ole32.lib shell32.lib advapi32.lib comdlg32.lib windowscodecs.lib

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

cl %CFLAGS% /Fe%OUT% src\betterss.cpp /link %LDFLAGS%
if errorlevel 1 (
    echo ERROR: Compilation failed
    exit /b 1
)

del /q *.obj 2>nul

echo Build complete: %OUT%
exit /b 0

:: %1=target %2=entry %3=output %4=varname %5=source %6=label
:compile_shader
if not exist "%3" goto :do_compile
call :get_filetime "%cd%\%5" SRC_T
call :get_filetime "%cd%\%3" OUT_T
if "!SRC_T!" leq "!OUT_T!" exit /b 0
:do_compile
echo Compiling %~6...
fxc /nologo /T %1 /E %2 /O3 /WX /Fh %3 /Vn %4 %5
if errorlevel 1 (
    echo ERROR: %~6 shader compilation failed
    exit /b 1
)
exit /b 0

:get_filetime
set "F=%~1"
set "F=%F:\=\\%"
for /f "skip=1" %%A in ('wmic datafile where "name='%F%'" get lastmodified') do (
    set "%2=%%A"
    goto :eof
)
exit /b 0
