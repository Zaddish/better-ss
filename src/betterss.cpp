#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <windows.h>
#include <d3d11_1.h>
#include <dxgi1_5.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <commdlg.h>

#pragma comment (lib, "kernel32.lib")
#pragma comment (lib, "user32.lib")
#pragma comment (lib, "gdi32.lib")
#pragma comment (lib, "dwmapi.lib")
#pragma comment (lib, "shell32.lib")
#pragma comment (lib, "advapi32.lib")

#include "betterss.h"
#include "betterss_d3d11.h"
#include "betterss_capture.h"
#include "betterss_selection.h"
#include "betterss_output.h"

#include "betterss_d3d11.cpp"
#include "betterss_capture.cpp"
#include "betterss_selection.cpp"
#include "betterss_output.cpp"

#include "betterss_vs.h"
#include "betterss_ps.h"
#include "betterss_line_vs.h"
#include "betterss_line_ps.h"

extern "C" int _fltused = 0x9875;

#pragma function(memset)
void *memset(void *DestInit, int Source, size_t Size) {
    unsigned char *Dest = (unsigned char *)DestInit;
    while(Size--) *Dest++ = (unsigned char)Source;
    return(DestInit);
}

#pragma function(memcpy)
void *memcpy(void *DestInit, void const *SourceInit, size_t Size) {
    unsigned char *Source = (unsigned char *)SourceInit;
    unsigned char *Dest = (unsigned char *)DestInit;
    while(Size--) *Dest++ = *Source++;
    return(DestInit);
}

static size_t wcslen_internal(const wchar_t *Str) {
    size_t Len = 0;
    while(*Str++) Len++;
    return(Len);
}

static void wcscat_internal(wchar_t *Dest, size_t DestSize, const wchar_t *Src) {
    while(*Dest && DestSize > 0) { Dest++; DestSize--; }
    while(*Src && DestSize > 1) { *Dest++ = *Src++; DestSize--; }
    if(DestSize > 0) *Dest = 0;
}

static void wcscpy_internal(wchar_t *Dest, size_t DestSize, const wchar_t *Src) {
    while(*Src && DestSize > 1) { *Dest++ = *Src++; DestSize--; }
    *Dest = 0;
}

static void UpdateOverlayShader(betterss_state *State);
static int RenderOverlay(betterss_state *State);
static void RegisterCurrentHotkey(betterss_state *State);
static void UpdateTrayTip(betterss_state *State);

#define HOTKEY_ID 1
#define WM_TRAYICON (WM_USER + 1)
#define IDM_QUIT 1001
#define IDM_STARTUP 1002
#define IDM_CHANGEHOTKEY 1003
#define IDM_CHANGESAVEHOTKEY 1004

static const wchar_t *RegistryKeyPath = L"Software\\BetterSS";
static const wchar_t *StartupKeyPath = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

static HWND g_HookTargetWindow = 0;

typedef BOOL WINAPI set_process_dpi_aware(void);
typedef BOOL WINAPI set_process_dpi_awareness_context(DPI_AWARENESS_CONTEXT);
static void PreventWindowsDPIScaling(void) {
    HMODULE User32 = LoadLibraryA("user32.dll");
    if(User32) {
        set_process_dpi_awareness_context *SetDPIAwareness = 
            (set_process_dpi_awareness_context *)GetProcAddress(User32, "SetProcessDpiAwarenessContext");
        if(SetDPIAwareness) {
            SetDPIAwareness(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        }
        else {
            set_process_dpi_aware *SetDPIAware = 
                (set_process_dpi_aware *)GetProcAddress(User32, "SetProcessDPIAware");
            if(SetDPIAware) {
                SetDPIAware();
            }
        }
    }
}

// settings persistence
static void SaveSettings(betterss_state *State) {
    HKEY Key;
    if(RegCreateKeyExW(HKEY_CURRENT_USER, RegistryKeyPath, 0, 0, 0, KEY_WRITE, 0, &Key, 0) == ERROR_SUCCESS) {
        RegSetValueExW(Key, L"HotkeyMods", 0, REG_DWORD, (BYTE*)&State->HotkeyMods, sizeof(State->HotkeyMods));
        RegSetValueExW(Key, L"HotkeyVK", 0, REG_DWORD, (BYTE*)&State->HotkeyVK, sizeof(State->HotkeyVK));
        RegSetValueExW(Key, L"SaveHotkeyMods", 0, REG_DWORD, (BYTE*)&State->SaveHotkeyMods, sizeof(State->SaveHotkeyMods));
        RegSetValueExW(Key, L"SaveHotkeyVK", 0, REG_DWORD, (BYTE*)&State->SaveHotkeyVK, sizeof(State->SaveHotkeyVK));
        RegCloseKey(Key);
    }
}

static void LoadSettings(betterss_state *State) {
    HKEY Key;
    if(RegOpenKeyExW(HKEY_CURRENT_USER, RegistryKeyPath, 0, KEY_READ, &Key) == ERROR_SUCCESS) {
        DWORD Size = sizeof(State->HotkeyMods);
        RegQueryValueExW(Key, L"HotkeyMods", 0, 0, (BYTE*)&State->HotkeyMods, &Size);
        Size = sizeof(State->HotkeyVK);
        RegQueryValueExW(Key, L"HotkeyVK", 0, 0, (BYTE*)&State->HotkeyVK, &Size);
        
        Size = sizeof(State->SaveHotkeyMods);
        if(RegQueryValueExW(Key, L"SaveHotkeyMods", 0, 0, (BYTE*)&State->SaveHotkeyMods, &Size) != ERROR_SUCCESS) {
             State->SaveHotkeyMods = MOD_CONTROL | MOD_SHIFT | MOD_ALT;
             State->SaveHotkeyVK = 'S';
        }
        else {
             Size = sizeof(State->SaveHotkeyVK);
             RegQueryValueExW(Key, L"SaveHotkeyVK", 0, 0, (BYTE*)&State->SaveHotkeyVK, &Size);
        }
        
        RegCloseKey(Key);
    }
    else {
        // default settings
        State->HotkeyMods = MOD_CONTROL | MOD_SHIFT;
        State->HotkeyVK = 'S';
        State->SaveHotkeyMods = MOD_CONTROL | MOD_SHIFT | MOD_ALT;
        State->SaveHotkeyVK = 'S';
    }
}

static int IsStartupEnabled(void) {
    HKEY Key;
    int Result = 0;
    if(RegOpenKeyExW(HKEY_CURRENT_USER, StartupKeyPath, 0, KEY_READ, &Key) == ERROR_SUCCESS) {
        if(RegQueryValueExW(Key, L"BetterSS", 0, 0, 0, 0) == ERROR_SUCCESS) {
            Result = 1;
        }
        RegCloseKey(Key);
    }
    return(Result);
}

static void SetStartupEnabled(int Enable) {
    HKEY Key;
    if(RegOpenKeyExW(HKEY_CURRENT_USER, StartupKeyPath, 0, KEY_WRITE, &Key) == ERROR_SUCCESS) {
        if(Enable) {
            wchar_t ExePath[MAX_PATH];
            GetModuleFileNameW(0, ExePath, MAX_PATH);
            RegSetValueExW(Key, L"BetterSS", 0, REG_SZ, (BYTE*)ExePath, (DWORD)(wcslen(ExePath) + 1) * sizeof(wchar_t));
        }
        else {
            RegDeleteValueW(Key, L"BetterSS");
        }
        RegCloseKey(Key);
    }
}

static void GetHotkeyString(betterss_state *State, wchar_t *Buffer, int BufferLen, int IsSaveHotkey) {
    Buffer[0] = 0;
    UINT Mods = IsSaveHotkey ? State->SaveHotkeyMods : State->HotkeyMods;
    UINT VK = IsSaveHotkey ? State->SaveHotkeyVK : State->HotkeyVK;

    if(Mods & MOD_CONTROL) wcscat_internal(Buffer, BufferLen, L"Ctrl+");
    if(Mods & MOD_SHIFT) wcscat_internal(Buffer, BufferLen, L"Shift+");
    if(Mods & MOD_ALT) wcscat_internal(Buffer, BufferLen, L"Alt+");
    if(Mods & MOD_WIN) wcscat_internal(Buffer, BufferLen, L"Win+");
    
    wchar_t KeyName[32] = {};
    UINT ScanCode = MapVirtualKeyW(VK, MAPVK_VK_TO_VSC);
    GetKeyNameTextW(ScanCode << 16, KeyName, 32);
    if(KeyName[0]) wcscat_internal(Buffer, BufferLen, KeyName);
}

static LRESULT CALLBACK LowLevelKeyboardProc(int Code, WPARAM WParam, LPARAM LParam) {
    if(Code >= 0 && WParam == WM_KEYDOWN) {
        KBDLLHOOKSTRUCT *Kbd = (KBDLLHOOKSTRUCT *)LParam;
        UINT VK = Kbd->vkCode;
        
        if(g_HookTargetWindow) {
            betterss_state *State = (betterss_state *)GetWindowLongPtrW(g_HookTargetWindow, GWLP_USERDATA);
            if(State) {
                if(State->IsCapturingHotkey && State->HotkeyDialog) {
                    if(VK == VK_CONTROL || VK == VK_SHIFT || VK == VK_MENU || VK == VK_LWIN || VK == VK_RWIN ||
                       VK == VK_LCONTROL || VK == VK_RCONTROL || VK == VK_LSHIFT || VK == VK_RSHIFT ||
                       VK == VK_LMENU || VK == VK_RMENU) {
                        return(CallNextHookEx(State->KeyboardHook, Code, WParam, LParam));
                    }
                    
                    UINT Mods = 0;
                    if(GetKeyState(VK_CONTROL) & 0x8000) Mods |= MOD_CONTROL;
                    if(GetKeyState(VK_SHIFT) & 0x8000) Mods |= MOD_SHIFT;
                    if(GetKeyState(VK_MENU) & 0x8000) Mods |= MOD_ALT;
                    if((GetKeyState(VK_LWIN) & 0x8000) || (GetKeyState(VK_RWIN) & 0x8000)) Mods |= MOD_WIN;
                    
                    if(State->ConfiguringSaveHotkey) {
                        State->SaveHotkeyMods = Mods;
                        State->SaveHotkeyVK = VK;
                    }
                    else {
                        State->HotkeyMods = Mods;
                        State->HotkeyVK = VK;
                    }
                    
                    SaveSettings(State);
                    RegisterCurrentHotkey(State);
                    UpdateTrayTip(State);
                    
                    DestroyWindow(State->HotkeyDialog);
                    State->HotkeyDialog = 0;
                    State->IsCapturingHotkey = 0;
                    State->ConfiguringSaveHotkey = 0;
                    
                    return(1);
                }
                
                UINT CurrentMods = 0;
                if(GetKeyState(VK_CONTROL) & 0x8000) CurrentMods |= MOD_CONTROL;
                if(GetKeyState(VK_SHIFT) & 0x8000) CurrentMods |= MOD_SHIFT;
                if(GetKeyState(VK_MENU) & 0x8000) CurrentMods |= MOD_ALT;
                if((GetKeyState(VK_LWIN) & 0x8000) || (GetKeyState(VK_RWIN) & 0x8000)) CurrentMods |= MOD_WIN;

                if(State->IsCapturing && VK == VK_ESCAPE) {
                    PostMessageW(State->Window, WM_KEYDOWN, VK_ESCAPE, 0);
                    return(1);
                }
                
                if(!State->IsCapturing && !State->IsCapturingHotkey) {
                    if(VK == State->HotkeyVK && CurrentMods == State->HotkeyMods) {
                        State->CaptureMode = 0;
                        PostMessageW(State->Window, WM_HOTKEY, HOTKEY_ID, 0);
                        return(1);
                    }
                    else if(VK == State->SaveHotkeyVK && CurrentMods == State->SaveHotkeyMods) {
                        State->CaptureMode = 1;
                        PostMessageW(State->Window, WM_HOTKEY, HOTKEY_ID, 0);
                        return(1);
                    }
                }
                
                return(CallNextHookEx(State->KeyboardHook, Code, WParam, LParam));
            }
        }
    }
    return(CallNextHookEx(0, Code, WParam, LParam));
}

static void RegisterCurrentHotkey(betterss_state *State) {
    if(State->KeyboardHook) {
        UnhookWindowsHookEx(State->KeyboardHook);
        State->KeyboardHook = 0;
    }
    
    State->KeyboardHook = SetWindowsHookExW(WH_KEYBOARD_LL, LowLevelKeyboardProc, 
        GetModuleHandleW(0), 0);
}

// tray icon
static void CreateTrayIcon(betterss_state *State, HINSTANCE Instance) {
    State->TrayIcon.cbSize = sizeof(State->TrayIcon);
    State->TrayIcon.hWnd = State->Window;
    State->TrayIcon.uID = 1;
    State->TrayIcon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    State->TrayIcon.uCallbackMessage = WM_TRAYICON;
    State->TrayIcon.hIcon = LoadIconW(0, MAKEINTRESOURCEW(32512));
    
    wchar_t Tip[128] = L"BetterSS\nCapture: ";
    wchar_t HotkeyStr[64];
    GetHotkeyString(State, HotkeyStr, 64, 0);
    wcscat_internal(Tip, 128, HotkeyStr);
    wcscat_internal(Tip, 128, L"\nSave: ");
    GetHotkeyString(State, HotkeyStr, 64, 1);
    wcscat_internal(Tip, 128, HotkeyStr);
    wcscpy_internal(State->TrayIcon.szTip, 128, Tip);
    
    Shell_NotifyIconW(NIM_ADD, &State->TrayIcon);
}

static void UpdateTrayTip(betterss_state *State) {
    wchar_t Tip[128] = L"BetterSS\nCapture: ";
    wchar_t HotkeyStr[64];
    GetHotkeyString(State, HotkeyStr, 64, 0);
    wcscat_internal(Tip, 128, HotkeyStr);
    wcscat_internal(Tip, 128, L"\nSave: ");
    GetHotkeyString(State, HotkeyStr, 64, 1);
    wcscat_internal(Tip, 128, HotkeyStr);
    wcscpy_internal(State->TrayIcon.szTip, 128, Tip);
    Shell_NotifyIconW(NIM_MODIFY, &State->TrayIcon);
}

static void RemoveTrayIcon(betterss_state *State) {
    Shell_NotifyIconW(NIM_DELETE, &State->TrayIcon);
}

static void ShowTrayMenu(betterss_state *State) {
    HMENU Menu = CreatePopupMenu();
    
    wchar_t HotkeyStr[64];
    GetHotkeyString(State, HotkeyStr, 64, 0);
    wchar_t MenuItem[128] = L"Capture Hotkey (";
    wcscat_internal(MenuItem, 128, HotkeyStr);
    wcscat_internal(MenuItem, 128, L")...");
    AppendMenuW(Menu, MF_STRING, IDM_CHANGEHOTKEY, MenuItem);
    
    GetHotkeyString(State, HotkeyStr, 64, 1);
    wcscpy_internal(MenuItem, 128, L"Save Hotkey (");
    wcscat_internal(MenuItem, 128, HotkeyStr);
    wcscat_internal(MenuItem, 128, L")...");
    AppendMenuW(Menu, MF_STRING, IDM_CHANGESAVEHOTKEY, MenuItem);
    
    int StartupChecked = IsStartupEnabled();
    AppendMenuW(Menu, MF_STRING | (StartupChecked ? MF_CHECKED : 0), IDM_STARTUP, L"Start with Windows");
    
    AppendMenuW(Menu, MF_SEPARATOR, 0, 0);
    AppendMenuW(Menu, MF_STRING, IDM_QUIT, L"Quit");
    
    POINT Pt;
    GetCursorPos(&Pt);
    SetForegroundWindow(State->Window);
    SetCursor(LoadCursorW(0, MAKEINTRESOURCEW(32512)));
    TrackPopupMenu(Menu, TPM_RIGHTBUTTON, Pt.x, Pt.y, 0, State->Window, 0);
    PostMessageW(State->Window, WM_NULL, 0, 0);
    DestroyMenu(Menu);
}

// hotkey capture dialog
static LRESULT CALLBACK HotkeyDialogProc(HWND Window, UINT Message, WPARAM WParam, LPARAM LParam) {
    switch(Message) {
        case WM_KILLFOCUS:
        case WM_CLOSE: {
            if(g_HookTargetWindow) {
                betterss_state *State = (betterss_state *)GetWindowLongPtrW(g_HookTargetWindow, GWLP_USERDATA);
                if(State) {
                    State->IsCapturingHotkey = 0;
                    State->ConfiguringSaveHotkey = 0;
                    State->HotkeyDialog = 0;
                }
            }
            DestroyWindow(Window);
        } break;
        
        case WM_PAINT: {
            PAINTSTRUCT Ps;
            HDC Dc = BeginPaint(Window, &Ps);
            RECT Rect;
            GetClientRect(Window, &Rect);
            FillRect(Dc, &Rect, (HBRUSH)(COLOR_WINDOW + 1));
            SetBkMode(Dc, TRANSPARENT);
            
            // should probably say which hotkey we are setting but for now generic message is fine
            DrawTextW(Dc, L"Press any key combination...", -1, &Rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
            EndPaint(Window, &Ps);
        } break;
        
        default:
            return(DefWindowProcW(Window, Message, WParam, LParam));
    }
    return(0);
}

static void ShowHotkeyDialog(betterss_state *State, HINSTANCE Instance, int ConfiguringSave) {
    if(State->HotkeyDialog) return;
    
    WNDCLASSEXW Wc = {};
    Wc.cbSize = sizeof(Wc);
    Wc.lpfnWndProc = HotkeyDialogProc;
    Wc.hInstance = Instance;
    Wc.hCursor = LoadCursorW(0, MAKEINTRESOURCEW(32512));
    Wc.lpszClassName = L"BetterSSHotkeyDialog";
    RegisterClassExW(&Wc);
    
    int Width = 350;
    int Height = 120;
    int X = (GetSystemMetrics(SM_CXSCREEN) - Width) / 2;
    int Y = (GetSystemMetrics(SM_CYSCREEN) - Height) / 2;
    
    const wchar_t *Title = ConfiguringSave ? L"Set Save Hotkey" : L"Set Capture Hotkey";
    
    State->HotkeyDialog = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, 
        L"BetterSSHotkeyDialog", Title,
        WS_POPUP | WS_BORDER | WS_CAPTION,
        X, Y, Width, Height, 0, 0, Instance, 0);
    
    if(State->HotkeyDialog) {
        State->IsCapturingHotkey = 1;
        State->ConfiguringSaveHotkey = ConfiguringSave;
        ShowWindow(State->HotkeyDialog, SW_SHOW);
        SetForegroundWindow(State->HotkeyDialog);
        SetFocus(State->HotkeyDialog);
    }
}

static HWND CreateOverlayWindow(betterss_state *State, HINSTANCE Instance, WNDPROC WndProc) {
    WNDCLASSEXW WindowClass = {};
    WindowClass.cbSize = sizeof(WindowClass);
    WindowClass.style = CS_HREDRAW | CS_VREDRAW;
    WindowClass.lpfnWndProc = WndProc;
    WindowClass.hInstance = Instance;
    WindowClass.hCursor = LoadCursorW(0, MAKEINTRESOURCEW(32512));
    WindowClass.lpszClassName = L"BetterSSOverlay";
    RegisterClassExW(&WindowClass);

    int X = GetSystemMetrics(SM_XVIRTUALSCREEN);
    int Y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int Width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    int Height = GetSystemMetrics(SM_CYVIRTUALSCREEN);

    DWORD ExStyle = WS_EX_TOPMOST | WS_EX_TOOLWINDOW;
    DWORD Style = WS_POPUP;

    HWND Window = CreateWindowExW(ExStyle, WindowClass.lpszClassName, L"BetterSS",
        Style, X, Y, Width, Height, 0, 0, Instance, State); // Pass State as param

    if(Window) {
        BOOL DisableTransitions = TRUE;
        DwmSetWindowAttribute(Window, DWMWA_TRANSITIONS_FORCEDISABLED, 
            &DisableTransitions, sizeof(DisableTransitions));
    }

    return(Window);
}

static void CloakWindow(HWND Window, BOOL Cloak) {
    DwmSetWindowAttribute(Window, DWMWA_CLOAK, &Cloak, sizeof(Cloak));
}

static void ShowOverlay(betterss_state *State) {
    // maybe we can re acquire the renderer if lost
    if(!RendererIsValid(State->Renderer)) {
        *State->Renderer = AcquireRenderer(State->Window);
        if(!RendererIsValid(State->Renderer)) return;
        
        State->Renderer->Device->CreateVertexShader(
            BetterSSVSBytes, sizeof(BetterSSVSBytes), 0, &State->Renderer->VertexShader);
        State->Renderer->Device->CreatePixelShader(
            BetterSSPSBytes, sizeof(BetterSSPSBytes), 0, &State->Renderer->OverlayShader);
        
        InitializeLineRenderer(State->Renderer, 
            BetterSSLineVSBytes, sizeof(BetterSSLineVSBytes),
            BetterSSLinePSBytes, sizeof(BetterSSLinePSBytes));
        
        // Need fresh capture if renderer was recreated
        ReleaseDuplications(State->Capture);
    }

    // Ensure we have valid capture state
    if(!CaptureIsValid(State->Capture)) {
        if(!RefreshCaptureState(State->Capture, State->Renderer->Device)) {
            return;
        }
    }

    // try to capture frames
    int CaptureResult = CaptureAllMonitors(State->Capture);
    
    // on access lost, refresh duplications and retry once
    if(CaptureResult == -1) {
        ReleaseDuplications(State->Capture);
        if(!RefreshCaptureState(State->Capture, State->Renderer->Device)) {
            return;
        }
        CaptureResult = CaptureAllMonitors(State->Capture);
    }
    
    // if still no frames, fuck you
    if(CaptureResult <= 0) {
        return;
    }

    ArenaReset(&State->CaptureArena);
    SelectionReset(State->Selection);
    AnnotationInit(State->Selection, &State->CaptureArena);
    
    UpdateOverlayShader(State);
    if(!RenderOverlay(State)) {
        return;
    }

    CloakWindow(State->Window, FALSE);
    ShowWindow(State->Window, SW_SHOW);
    SetForegroundWindow(State->Window);
    BringWindowToTop(State->Window);
    SetCapture(State->Window);

    SetCursor(LoadCursorW(0, MAKEINTRESOURCEW(32515)));

    State->IsCapturing = 1;
    State->Selection->IsSelecting = 1;
}

static void HideOverlay(betterss_state *State) {
    ReleaseCapture();
    CloakWindow(State->Window, TRUE);
    ShowWindow(State->Window, SW_HIDE);

    ReleaseAllFrames(State->Capture);
    AnnotationClear(State->Selection);
    SelectionReset(State->Selection);

    SetCursor(LoadCursorW(0, MAKEINTRESOURCEW(32512)));

    State->IsCapturing = 0;
}

static void UpdateOverlayConstBuffer(betterss_renderer *R, RECT SelectRect, RECT MonitorBounds, 
    int VirtScreenLeft, int VirtScreenTop, DXGI_MODE_ROTATION Rotation) {
    int MonW = MonitorBounds.right - MonitorBounds.left;
    int MonH = MonitorBounds.bottom - MonitorBounds.top;
    int MonOffsetX = MonitorBounds.left - VirtScreenLeft;
    int MonOffsetY = MonitorBounds.top - VirtScreenTop;

    float SelLeft = (float)(SelectRect.left - MonOffsetX) / (float)MonW;
    float SelTop = (float)(SelectRect.top - MonOffsetY) / (float)MonH;
    float SelWidth = (float)(SelectRect.right - SelectRect.left) / (float)MonW;
    float SelHeight = (float)(SelectRect.bottom - SelectRect.top) / (float)MonH;

    overlay_const_buffer Constants = {};
    Constants.SelectionRect[0] = SelLeft;
    Constants.SelectionRect[1] = SelTop;
    Constants.SelectionRect[2] = SelWidth;
    Constants.SelectionRect[3] = SelHeight;
    Constants.DimFactor = 0.4f;
    Constants.TexelSize[0] = 1.0f / (float)MonW;
    Constants.TexelSize[1] = 1.0f / (float)MonH;
    Constants.Rotation = (float)Rotation;

    D3D11_MAPPED_SUBRESOURCE Mapped;
    if(SUCCEEDED(R->Context->Map(R->ConstantBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &Mapped))) {
        memcpy(Mapped.pData, &Constants, sizeof(Constants));
        R->Context->Unmap(R->ConstantBuffer, 0);
    }
}

static void UpdateOverlayShader(betterss_state *State) {
    if(!State->Renderer || !State->Selection || !State->Capture) return;

    RECT SelectRect = SelectionGetRect(State->Selection);
    RECT DefaultBounds = {0, 0, (LONG)State->Renderer->Width, (LONG)State->Renderer->Height};
    UpdateOverlayConstBuffer(State->Renderer, SelectRect, DefaultBounds, 
        State->Capture->VirtualScreen.left, State->Capture->VirtualScreen.top, 
        DXGI_MODE_ROTATION_IDENTITY);
}

static int RenderOverlay(betterss_state *State) {
    betterss_renderer *R = State->Renderer;
    if(!R || !R->Context || !R->RenderTarget) return(0);

    R->Context->OMSetRenderTargets(1, &R->RenderTarget, 0);

    D3D11_VIEWPORT Viewport = {};
    Viewport.Width = (float)R->Width;
    Viewport.Height = (float)R->Height;
    Viewport.MaxDepth = 1.0f;
    R->Context->RSSetViewports(1, &Viewport);

    float ClearColor[4] = {0.2f, 0.2f, 0.2f, 1.0f};
    R->Context->ClearRenderTargetView(R->RenderTarget, ClearColor);

    if(!R->VertexShader || !R->OverlayShader) {
        return RendererPresent(R);
    }

    R->Context->VSSetShader(R->VertexShader, 0, 0);
    R->Context->PSSetShader(R->OverlayShader, 0, 0);
    R->Context->PSSetConstantBuffers(0, 1, &R->ConstantBuffer);
    R->Context->PSSetSamplers(0, 1, &R->Sampler);

    if(!State->Capture || !State->Capture->Monitors || State->Capture->MonitorCount == 0) {
        return RendererPresent(R);
    }

    RECT SelectRect = {0};
    if(State->Selection) {
        SelectRect = SelectionGetRect(State->Selection);
    }

    int VirtLeft = State->Capture->VirtualScreen.left;
    int VirtTop = State->Capture->VirtualScreen.top;

    for(uint32_t i = 0; i < State->Capture->MonitorCount; i++) {
        monitor_duplication *Mon = &State->Capture->Monitors[i];
        if(!Mon->HasFrame || !Mon->Texture || !Mon->SRV) continue;

        int MonW = Mon->Bounds.right - Mon->Bounds.left;
        int MonH = Mon->Bounds.bottom - Mon->Bounds.top;
        int OffsetX = Mon->Bounds.left - VirtLeft;
        int OffsetY = Mon->Bounds.top - VirtTop;

        D3D11_VIEWPORT MonViewport = {};
        MonViewport.TopLeftX = (float)OffsetX;
        MonViewport.TopLeftY = (float)OffsetY;
        MonViewport.Width = (float)MonW;
        MonViewport.Height = (float)MonH;
        MonViewport.MaxDepth = 1.0f;
        R->Context->RSSetViewports(1, &MonViewport);

        UpdateOverlayConstBuffer(R, SelectRect, Mon->Bounds, VirtLeft, VirtTop, Mon->Rotation);
        
        R->Context->PSSetShaderResources(0, 1, &Mon->SRV);
        R->Context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        R->Context->Draw(3, 0);
    }

    Viewport.Width = (float)R->Width;
    Viewport.Height = (float)R->Height;
    Viewport.MaxDepth = 1.0f;
    R->Context->RSSetViewports(1, &Viewport);
    
    RenderAnnotationLines(R, State->Selection, 0, 0, R->Width, R->Height);

    return RendererPresent(R);
}

static LRESULT CALLBACK WindowProc(HWND Window, UINT Message, WPARAM WParam, LPARAM LParam) {
    betterss_state *State = (betterss_state *)GetWindowLongPtrW(Window, GWLP_USERDATA);
    
    if(Message == WM_NCCREATE) {
        CREATESTRUCTW *CreateStruct = (CREATESTRUCTW *)LParam;
        State = (betterss_state *)CreateStruct->lpCreateParams;
        SetWindowLongPtrW(Window, GWLP_USERDATA, (LONG_PTR)State);
        return(DefWindowProcW(Window, Message, WParam, LParam));
    }
    
    if(!State) return(DefWindowProcW(Window, Message, WParam, LParam));

    switch(Message) {
        case WM_HOTKEY: {
            if(!State->IsCapturing && !State->IsCapturingHotkey) {
                ShowOverlay(State);
            }
        } break;

        case WM_TRAYICON: {
            if(LOWORD(LParam) == WM_RBUTTONUP || LOWORD(LParam) == WM_CONTEXTMENU) {
                ShowTrayMenu(State);
            }
            else if(LOWORD(LParam) == WM_LBUTTONDBLCLK) {
                if(!State->IsCapturing) {
                    ShowOverlay(State);
                }
            }
        } break;

        case WM_COMMAND: {
            switch(LOWORD(WParam)) {
                case IDM_QUIT: {
                    PostQuitMessage(0);
                } break;
                
                case IDM_STARTUP: {
                    SetStartupEnabled(!IsStartupEnabled());
                } break;
                
                case IDM_CHANGEHOTKEY: {
                    ShowHotkeyDialog(State, GetModuleHandleW(0), 0);
                } break;
                
                case IDM_CHANGESAVEHOTKEY: {
                    ShowHotkeyDialog(State, GetModuleHandleW(0), 1);
                } break;
            }
        } break;

        case WM_LBUTTONDOWN: {
            if(State->IsCapturing && State->Selection && !State->Selection->IsAnnotating) {
                int X = (short)LOWORD(LParam);
                int Y = (short)HIWORD(LParam);
                SelectionBegin(State->Selection, X, Y);
            }
        } break;

        case WM_MOUSEMOVE: {
            if(State->IsCapturing && State->Selection) {
                int X = (short)LOWORD(LParam);
                int Y = (short)HIWORD(LParam);
                
                if(State->Selection->IsDragging) {
                    SelectionUpdate(State->Selection, X, Y);
                    UpdateOverlayShader(State);
                    if(!RenderOverlay(State)) { HideOverlay(State); }
                }
                else if(State->Selection->IsAnnotating) {
                    AnnotationUpdate(State->Selection, X, Y);
                    if(!RenderOverlay(State)) { HideOverlay(State); }
                }
            }
        } break;

        case WM_LBUTTONUP: {
            if(State->IsCapturing && State->Selection && State->Selection->IsDragging) {
                SelectionEnd(State->Selection);
                RECT SelectRect = SelectionGetRect(State->Selection);
                if((SelectRect.right - SelectRect.left) > 1 && 
                   (SelectRect.bottom - SelectRect.top) > 1) {
                    if(State->CaptureMode == 1) { // Save file
                        OPENFILENAMEW Ofn = {};
                        wchar_t File[MAX_PATH] = L"screenshot.png";
                        
                        Ofn.lStructSize = sizeof(Ofn);
                        Ofn.hwndOwner = Window;
                        Ofn.lpstrFile = File;
                        Ofn.nMaxFile = ArrayCount(File);
                        Ofn.lpstrFilter = L"PNG Files\0*.png\0All Files\0*.*\0";
                        Ofn.nFilterIndex = 1;
                        Ofn.lpstrFileTitle = 0;
                        Ofn.nMaxFileTitle = 0;
                        Ofn.lpstrInitialDir = 0;
                        Ofn.Flags = OFN_OVERWRITEPROMPT | OFN_NOCHANGEDIR;
                        Ofn.lpstrDefExt = L"png";
                        
                        if(GetSaveFileNameW(&Ofn)) {
                            SaveSelectionToFile(State->Renderer, State->Capture, SelectRect, File, State->Selection);
                        }
                    }
                    else {
                        CopySelectionToClipboard(State->Renderer, State->Capture, SelectRect, State->Selection);
                    }
                }
                HideOverlay(State);
            }
        } break;

        case WM_RBUTTONDOWN: {
            if(State->IsCapturing && State->Selection) {
                int X = (short)LOWORD(LParam);
                int Y = (short)HIWORD(LParam);
                AnnotationBegin(State->Selection, &State->CaptureArena, X, Y);
                SetCursor(LoadCursorW(0, MAKEINTRESOURCEW(32516)));
            }
        } break;

        case WM_RBUTTONUP: {
            if(State->IsCapturing && State->Selection && State->Selection->IsAnnotating) {
                AnnotationEnd(State->Selection);
                SetCursor(LoadCursorW(0, MAKEINTRESOURCEW(32515)));
            }
        } break;

        case WM_MBUTTONDOWN: {
            if(State->IsCapturing && State->Selection) {
                AnnotationUndo(State->Selection);
                if(!RenderOverlay(State)) { HideOverlay(State); }
            }
        } break;

        case WM_SETCURSOR: {
            if(State->IsCapturing) {
                if(State->Selection && State->Selection->IsAnnotating) {
                    SetCursor(LoadCursorW(0, MAKEINTRESOURCEW(32516)));
                }
                else {
                    SetCursor(LoadCursorW(0, MAKEINTRESOURCEW(32515)));
                }
                return(TRUE);
            }
        } break;

        case WM_KEYDOWN: {
            if(State->IsCapturing) {
                if(WParam == VK_ESCAPE) {
                    SelectionCancel(State->Selection);
                    HideOverlay(State);
                }
                else if(WParam == 'Z' && (GetKeyState(VK_CONTROL) & 0x8000)) {
                    AnnotationUndo(State->Selection);
                    if(!RenderOverlay(State)) { HideOverlay(State); }
                }
            }
        } break;

        case WM_DESTROY: {
            RemoveTrayIcon(State);
            PostQuitMessage(0);
        } break;

        default: {
            return(DefWindowProcW(Window, Message, WParam, LParam));
        }
    }

    return(0);
}

void WinMainCRTStartup(void) {
    CoInitializeEx(0, COINIT_APARTMENTTHREADED);
    PreventWindowsDPIScaling();
    
    // Allocate state
    betterss_state *State = (betterss_state *)VirtualAlloc(0, sizeof(betterss_state), 
        MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if(!State) ExitProcess(1);
    
    size_t ArenaSize = 16 * 1024 * 1024;
    State->CaptureArena.Memory = (uint8_t *)VirtualAlloc(0, ArenaSize,
        MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    State->CaptureArena.Size = ArenaSize;
    State->CaptureArena.Used = 0;
    if(!State->CaptureArena.Memory) ExitProcess(1);
    
    LoadSettings(State);

    HINSTANCE Instance = GetModuleHandleW(0);
    HWND Window = CreateOverlayWindow(State, Instance, WindowProc);
    if(!Window) ExitProcess(1);

    State->Window = Window;
    g_HookTargetWindow = Window;

    State->Renderer = (betterss_renderer *)VirtualAlloc(0, sizeof(betterss_renderer), 
        MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    State->Capture = (capture_state *)VirtualAlloc(0, sizeof(capture_state), 
        MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    State->Selection = (selection_state *)VirtualAlloc(0, sizeof(selection_state), 
        MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);

    *State->Renderer = AcquireRenderer(Window);
    if(!RendererIsValid(State->Renderer)) ExitProcess(2);

    State->Renderer->Device->CreateVertexShader(
        BetterSSVSBytes, sizeof(BetterSSVSBytes), 0, &State->Renderer->VertexShader);
    State->Renderer->Device->CreatePixelShader(
        BetterSSPSBytes, sizeof(BetterSSPSBytes), 0, &State->Renderer->OverlayShader);

    InitializeLineRenderer(State->Renderer, 
        BetterSSLineVSBytes, sizeof(BetterSSLineVSBytes),
        BetterSSLinePSBytes, sizeof(BetterSSLinePSBytes));

    InitializeCaptureState(State->Capture);
    if(!RefreshCaptureState(State->Capture, State->Renderer->Device)) ExitProcess(3);

    CloakWindow(Window, TRUE);
    ShowWindow(Window, SW_HIDE);

    CreateTrayIcon(State, Instance);
    RegisterCurrentHotkey(State);

    for(;;) {
        MSG Message;
        if(!GetMessageW(&Message, 0, 0, 0)) break;
        TranslateMessage(&Message);
        DispatchMessageW(&Message);
    }

    if(State->KeyboardHook) {
        UnhookWindowsHookEx(State->KeyboardHook);
        State->KeyboardHook = 0;
    }
    RemoveTrayIcon(State);
    ReleaseCaptureState(State->Capture);
    ReleaseRenderer(State->Renderer);
    
    if(State->CaptureArena.Memory) {
        VirtualFree(State->CaptureArena.Memory, 0, MEM_RELEASE);
    }

    ExitProcess(0);
}