#pragma once

#include <stdint.h>
#include <windef.h>
#include <shellapi.h>

struct IWICImagingFactory;

#define ArrayCount(a) (sizeof(a) / sizeof((a)[0]))
#define DeferLoop(begin, end) for(int _i_ = ((begin), 0); !_i_; _i_ += 1, (end))
#define EachIndex(it, count)  (uint32_t it = 0; it < (count); it += 1)
#define EachCount(it, count)  (int it = 0; it < (count); it += 1)

#ifndef DWMWA_CLOAK
#define DWMWA_CLOAK 13
#endif

#ifndef DWMWA_TRANSITIONS_FORCEDISABLED
#define DWMWA_TRANSITIONS_FORCEDISABLED 3
#endif

struct betterss_renderer;
struct capture_state;
struct selection_state;
struct nv_capture;

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
    size_t Committed;
    size_t Reserved;
    size_t Used;
};

#define ARENA_COMMIT_CHUNK (64 * 1024)

static inline int ArenaInit(memory_arena *Arena, size_t ReserveSize) {
    Arena->Memory = (uint8_t *)VirtualAlloc(0, ReserveSize, MEM_RESERVE, PAGE_READWRITE);
    Arena->Reserved = ReserveSize;
    Arena->Committed = 0;
    Arena->Used = 0;
    return Arena->Memory != 0;
}

static inline void *ArenaAlloc(memory_arena *Arena, size_t Size) {
    size_t Aligned = (Size + 15) & ~15;
    size_t NewUsed = Arena->Used + Aligned;
    if(NewUsed > Arena->Reserved) return 0;
    if(NewUsed > Arena->Committed) {
        size_t CommitTarget = (NewUsed + ARENA_COMMIT_CHUNK - 1) & ~(ARENA_COMMIT_CHUNK - 1);
        if(CommitTarget > Arena->Reserved) CommitTarget = Arena->Reserved;
        if(!VirtualAlloc(Arena->Memory + Arena->Committed, CommitTarget - Arena->Committed, MEM_COMMIT, PAGE_READWRITE)) return 0;
        Arena->Committed = CommitTarget;
    }
    void *Result = Arena->Memory + Arena->Used;
    Arena->Used = NewUsed;
    return Result;
}

static inline void ArenaReset(memory_arena *Arena) {
    Arena->Used = 0;
}

static inline void ArenaRelease(memory_arena *Arena) {
    if(Arena->Memory) VirtualFree(Arena->Memory, 0, MEM_RELEASE);
    *Arena = {};
}

#define PushArray(arena, T, count) (T *)ArenaAlloc((arena), sizeof(T) * (count))
#define PushStruct(arena, T)       PushArray(arena, T, 1)

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
    nv_capture *Nvapi;
    int IsCapturing;
    
    memory_arena CaptureArena;

    hotkey_binding CaptureHotkey;
    hotkey_binding SaveHotkey;

    NOTIFYICONDATAW TrayIcon;
    HHOOK KeyboardHook;
    HWND HotkeyDialog;
    int HotkeyDialogSlot;
    hotkey_binding HotkeyDialogPending;
    int HotkeyDialogHasPending;
    int HotkeyDialogConflict;
    int CaptureMode; // 0 = clipboard, 1 = save file

    HCURSOR CursorArrow;
    HCURSOR CursorCross;
    HCURSOR CursorSizeAll;

    IWICImagingFactory *WICFactory;

    window_entry *WindowEntries;
    int WindowEntryCount;
    window_entry *LastSnapEntry;
    int LastMouseX;
    int LastMouseY;
    int SnapEnabled;
    UINT SnapHeldMods;
    UINT LiveMods;
};
