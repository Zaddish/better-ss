#pragma once

#include <stdint.h>
#include <windef.h>
#include <shellapi.h>

#define BETTERSS_VERSION "0.1"

#define Assert(x) do { if(!(x)) __debugbreak(); } while(0)
#define AssertHR(hr) Assert(SUCCEEDED(hr))
#define ArrayCount(a) (sizeof(a) / sizeof((a)[0]))

#ifndef DWMWA_CLOAK
#define DWMWA_CLOAK 13
#endif

#ifndef DWMWA_TRANSITIONS_FORCEDISABLED
#define DWMWA_TRANSITIONS_FORCEDISABLED 3
#endif

struct betterss_renderer;
struct capture_state;
struct selection_state;

struct betterss_state
{
    HWND Window;
    betterss_renderer *Renderer;
    capture_state *Capture;
    selection_state *Selection;
    int IsCapturing;
    
    // settings
    UINT HotkeyMods;
    UINT HotkeyVK;
    UINT SaveHotkeyMods;
    UINT SaveHotkeyVK;
    
    // internal
    NOTIFYICONDATAW TrayIcon;
    HHOOK KeyboardHook;
    HWND HotkeyDialog;
    int IsCapturingHotkey;
    int ConfiguringSaveHotkey; // 0 = standard capture hotkey, 1 = save file hotkey
    int CaptureMode; // 0 = clipboard, 1 = save file
};
