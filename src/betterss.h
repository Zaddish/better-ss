#pragma once

#include <stdint.h>
#include <windef.h>
#include <shellapi.h>

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

// will expand if shit gets cooked with this
#define MAX_WINDOW_ENTRIES 512

struct window_entry
{
    HWND Hwnd;
    RECT SnapBounds;
};

struct memory_arena
{
    uint8_t *Memory;
    size_t Size;
    size_t Used;
};

static inline void *ArenaAlloc(memory_arena *Arena, size_t Size) {
    size_t Aligned = (Size + 15) & ~15;
    if(Arena->Used + Aligned > Arena->Size) {
        return 0;
    }
    void *Result = Arena->Memory + Arena->Used;
    Arena->Used += Aligned;
    return Result;
}

static inline void ArenaReset(memory_arena *Arena) {
    Arena->Used = 0;
}

struct hotkey_binding {
    UINT Mods;
    UINT VK;
};

struct betterss_state
{
    HWND Window;
    betterss_renderer *Renderer;
    capture_state *Capture;
    selection_state *Selection;
    int IsCapturing;
    
    memory_arena CaptureArena;

    hotkey_binding CaptureHotkey;
    hotkey_binding SaveHotkey;

    NOTIFYICONDATAW TrayIcon;
    HHOOK KeyboardHook;
    HWND HotkeyDialog;
    int IsCapturingHotkey;
    int ConfiguringSaveHotkey; // 0 = standard capture hotkey, 1 = save file hotkey
    int CaptureMode; // 0 = clipboard, 1 = save file

    HCURSOR CursorArrow;
    HCURSOR CursorCross;
    HCURSOR CursorSizeAll;

    void *WICFactory;

    window_entry *WindowEntries;
    int WindowEntryCount;
    window_entry *LastSnapEntry;
    int LastMouseX;
    int LastMouseY;
    int SnapEnabled;
    UINT SnapHeldMods;
    UINT LiveMods;
};
