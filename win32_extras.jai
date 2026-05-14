User32   :: #system_library "user32";
Kernel32 :: #system_library "kernel32";
Gdi32    :: #system_library "gdi32";
Advapi32 :: #system_library "Advapi32";
Shell32  :: #system_library "shell32";
Comdlg32 :: #system_library "comdlg32";
Dwmapi   :: #system_library "Dwmapi";
Ole32    :: #system_library "ole32";

WM_USER       :: 0x0400;
WM_HOTKEY     :: 0x0312;

MF_STRING        :: 0x00000000;
MF_CHECKED       :: 0x00000008;
MF_GRAYED        :: 0x00000001;
MF_SEPARATOR     :: 0x00000800;

TPM_RIGHTBUTTON  :: 0x0002;

NIF_MESSAGE :: 0x00000001;
NIF_ICON    :: 0x00000002;
NIF_TIP     :: 0x00000004;
NIF_INFO    :: 0x00000010;

NIM_ADD    :: 0x00000000;
NIM_MODIFY :: 0x00000001;
NIM_DELETE :: 0x00000002;

NIIF_NONE    :: 0x00000000;
NIIF_INFO    :: 0x00000001;
NIIF_WARNING :: 0x00000002;
NIIF_ERROR   :: 0x00000003;
NIIF_NOSOUND :: 0x00000010;

MOD_ALT     :: 0x0001;
MOD_CONTROL :: 0x0002;
MOD_SHIFT   :: 0x0004;
MOD_WIN     :: 0x0008;

MAPVK_VK_TO_VSC :: 0;

WH_KEYBOARD_LL :: 13;

KBDLLHOOKSTRUCT :: struct {
    vkCode:      u32;
    scanCode:    u32;
    flags:       u32;
    time:        u32;
    dwExtraInfo: u64;
}

HHOOK :: HANDLE;

PAINTSTRUCT :: struct {
    hdc:         HDC;
    fErase:      BOOL;
    rcPaint:     RECT;
    fRestore:    BOOL;
    fIncUpdate:  BOOL;
    rgbReserved: [32] u8;
}

FW_SEMIBOLD    :: 600;
DEFAULT_CHARSET       :: 1;
OUT_DEFAULT_PRECIS    :: 0;
CLIP_DEFAULT_PRECIS   :: 0;
CLEARTYPE_QUALITY     :: 5;
DEFAULT_PITCH         :: 0;

DT_CENTER      :: 0x00000001;
DT_VCENTER     :: 0x00000004;
DT_SINGLELINE  :: 0x00000020;
DT_LEFT        :: 0x00000000;
DT_TOP         :: 0x00000000;
DT_NOCLIP      :: 0x00000100;

TRANSPARENT    :: 1;

HKEY_CURRENT_USER :: cast(HKEY)(0x80000001);

KEY_READ  :: 0x20019;
KEY_WRITE :: 0x20006;

REG_BINARY :: 3;

ERROR_SUCCESS :: 0;


OFN_OVERWRITEPROMPT :: 0x00000002;

SID_IDENTIFIER_AUTHORITY :: struct {
    Value: [6] u8;
}

SECURITY_NT_AUTHORITY_VALUE :: SID_IDENTIFIER_AUTHORITY.{.[0, 0, 0, 0, 0, 5]};

SECURITY_BUILTIN_DOMAIN_RID :: 0x00000020;
DOMAIN_ALIAS_RID_ADMINS     :: 0x00000220;

// DisplayConfig
QDC_ONLY_ACTIVE_PATHS :: 0x00000002;

DISPLAYCONFIG_PATH_MODE_IDX_INVALID :: 0xFFFFFFFF;

DISPLAYCONFIG_MODE_INFO_TYPE :: enum s32 {
    SOURCE :: 1;
    TARGET :: 2;
    DESKTOP_IMAGE :: 3;
}

DISPLAYCONFIG_RATIONAL :: struct { Numerator: u32; Denominator: u32; }

POINTL :: struct { x: s32; y: s32; }

DISPLAYCONFIG_PATH_SOURCE_INFO :: struct {
    adapterId:   LUID;
    id:          u32;
    modeInfoIdx: u32;
    statusFlags: u32;
}

DISPLAYCONFIG_PATH_TARGET_INFO :: struct {
    adapterId:               LUID;
    id:                      u32;
    modeInfoIdx:             u32;
    outputTechnology:        u32;
    rotation:                u32;
    scaling:                 u32;
    refreshRate:             DISPLAYCONFIG_RATIONAL;
    scanLineOrdering:        u32;
    targetAvailable:         BOOL;
    statusFlags:             u32;
}

DISPLAYCONFIG_PATH_INFO :: struct {
    sourceInfo: DISPLAYCONFIG_PATH_SOURCE_INFO;
    targetInfo: DISPLAYCONFIG_PATH_TARGET_INFO;
    flags:      u32;
}

DISPLAYCONFIG_2DREGION :: struct { cx: u32; cy: u32; }

DISPLAYCONFIG_SOURCE_MODE :: struct {
    width:       u32;
    height:      u32;
    pixelFormat: u32;
    position:    POINTL;
}

DISPLAYCONFIG_VIDEO_SIGNAL_INFO :: struct {
    pixelRate:         u64;
    hSyncFreq:         DISPLAYCONFIG_RATIONAL;
    vSyncFreq:         DISPLAYCONFIG_RATIONAL;
    activeSize:        DISPLAYCONFIG_2DREGION;
    totalSize:         DISPLAYCONFIG_2DREGION;
    videoStandard_and_vSyncFreqDivider: u32;
    scanLineOrdering:  u32;
}

DISPLAYCONFIG_TARGET_MODE :: struct {
    targetVideoSignalInfo: DISPLAYCONFIG_VIDEO_SIGNAL_INFO;
}

DISPLAYCONFIG_DESKTOP_IMAGE_INFO :: struct {
    PathSourceSize: POINTL;
    DesktopImageRegion: RECT;
    DesktopImageClip:   RECT;
}

DISPLAYCONFIG_MODE_INFO_union :: union {
    targetMode:       DISPLAYCONFIG_TARGET_MODE;
    sourceMode:       DISPLAYCONFIG_SOURCE_MODE;
    desktopImageInfo: DISPLAYCONFIG_DESKTOP_IMAGE_INFO;
}

DISPLAYCONFIG_MODE_INFO :: struct {
    infoType:   DISPLAYCONFIG_MODE_INFO_TYPE;
    id:         u32;
    adapterId:  LUID;
    using mode: DISPLAYCONFIG_MODE_INFO_union;
}

HOOKPROC :: #type (nCode: s32, wParam: WPARAM, lParam: LPARAM) -> LRESULT #c_call;

// tray icon data
NOTIFYICONDATAW :: struct {
    cbSize:           u32;
    hWnd:             HWND;
    uID:              u32;
    uFlags:           u32;
    uCallbackMessage: u32;
    hIcon:            HICON;
    szTip:            [128] u16;
    dwState:          u32;
    dwStateMask:      u32;
    szInfo:           [256] u16;
    uVersion_or_uTimeout: u32;
    szInfoTitle:      [64] u16;
    dwInfoFlags:      u32;
    guidItem:         GUID;
    hBalloonIcon:     HICON;
}


// DWM window attribute indices
DWMWA_TRANSITIONS_FORCEDISABLED :: 3;
DWMWA_EXTENDED_FRAME_BOUNDS     :: 9;
DWMWA_CLOAK                     :: 13;
DWMWA_CLOAKED                   :: 14;

// CoInit flags
COINIT_APARTMENTTHREADED :: 0x2;

// CLSCTX
CLSCTX_INPROC_SERVER :: 0x1;

// User32
PostMessageW   :: (hwnd: HWND, msg: u32, wParam: WPARAM, lParam: LPARAM) -> BOOL #foreign User32;
GetMessageW    :: (msg: *MSG, hwnd: HWND, filter_min: u32, filter_max: u32) -> s32 #foreign User32;
GetWindowLongPtrW  :: (hwnd: HWND, index: s32) -> s64 #foreign User32;
GetWindowTextLengthW :: (hwnd: HWND) -> s32 #foreign User32;
IsWindowVisible  :: (hwnd: HWND) -> BOOL #foreign User32;
EnumWindows    :: (lpEnumFunc: EnumWindowsProc, lParam: LPARAM) -> BOOL #foreign User32;
EnumWindowsProc :: #type (hwnd: HWND, lParam: LPARAM) -> BOOL #c_call;
SetForegroundWindow :: (hwnd: HWND) -> BOOL #foreign User32;
BringWindowToTop    :: (hwnd: HWND) -> BOOL #foreign User32;
SetFocus       :: (hwnd: HWND) -> HWND #foreign User32;
InvalidateRect :: (hwnd: HWND, rect: *RECT, erase: BOOL) -> BOOL #foreign User32;
BeginPaint     :: (hwnd: HWND, ps: *PAINTSTRUCT) -> HDC #foreign User32;
EndPaint       :: (hwnd: HWND, ps: *PAINTSTRUCT) -> BOOL #foreign User32;
FillRect       :: (hdc: HDC, rect: *RECT, brush: HBRUSH) -> s32 #foreign User32;
DrawTextW      :: (hdc: HDC, text: *u16, count: s32, rect: *RECT, format: u32) -> s32 #foreign User32;
MapVirtualKeyW :: (code: u32, map_type: u32) -> u32 #foreign User32;
GetKeyNameTextW :: (lparam: s32, buffer: *u16, size: s32) -> s32 #foreign User32;
SetWindowsHookExW :: (idHook: s32, lpfn: HOOKPROC, hmod: HINSTANCE, threadId: u32) -> HHOOK #foreign User32;
UnhookWindowsHookEx :: (hhk: HHOOK) -> BOOL #foreign User32;
CallNextHookEx :: (hhk: HHOOK, nCode: s32, wParam: WPARAM, lParam: LPARAM) -> LRESULT #foreign User32;

// Menu
CreatePopupMenu :: () -> HMENU #foreign User32;
DestroyMenu   :: (menu: HMENU) -> BOOL #foreign User32;
AppendMenuW   :: (menu: HMENU, flags: u32, idNewItem: u64, lpNewItem: *u16) -> BOOL #foreign User32;
TrackPopupMenu:: (menu: HMENU, flags: u32, x: s32, y: s32, reserved: s32, hwnd: HWND, rect: *RECT) -> BOOL #foreign User32;

// GDI
CreateFontW   :: (height: s32, width: s32, escapement: s32, orientation: s32, weight: s32, italic: u32, underline: u32, strikeout: u32, charset: u32, out_precision: u32, clip_precision: u32, quality: u32, pitch_family: u32, face: *u16) -> HGDIOBJ #foreign Gdi32;
GetTextExtentPoint32W :: (hdc: HDC, s: *u16, count: s32, size: *SIZE) -> BOOL #foreign Gdi32;
SetTextColor  :: (hdc: HDC, color: u32) -> u32 #foreign Gdi32;
SetBkMode     :: (hdc: HDC, mode: s32) -> s32 #foreign Gdi32;
GdiFlush      :: () -> BOOL #foreign Gdi32;
CreateDIBSection :: (hdc: HDC, info: *BITMAPINFO, usage: u32, bits: **void, section: HANDLE, offset: u32) -> HBITMAP #foreign Gdi32;
MulDiv        :: (n: s32, num: s32, den: s32) -> s32 #foreign Kernel32;

// Kernel32
GlobalFree    :: (hMem: HGLOBAL) -> HGLOBAL #foreign Kernel32;
// advapi32
RegCreateKeyExW :: (hKey: HKEY, name: *u16, reserved: u32, class: *u16, options: u32, sam: u32, attrs: *void, result: *HKEY, disp: *u32) -> s32 #foreign Advapi32;
RegOpenKeyExW   :: (hKey: HKEY, name: *u16, options: u32, sam: u32, result: *HKEY) -> s32 #foreign Advapi32;
RegSetValueExW  :: (hKey: HKEY, name: *u16, reserved: u32, type: u32, data: *u8, count: u32) -> s32 #foreign Advapi32;
RegQueryValueExW :: (hKey: HKEY, name: *u16, reserved: *u32, type: *u32, data: *u8, count: *u32) -> s32 #foreign Advapi32;
RegDeleteValueW :: (hKey: HKEY, name: *u16) -> s32 #foreign Advapi32;
RegCloseKey     :: (hKey: HKEY) -> s32 #foreign Advapi32;

// Security
AllocateAndInitializeSid :: (auth: *SID_IDENTIFIER_AUTHORITY, sub_count: u8, r1: u32, r2: u32, r3: u32, r4: u32, r5: u32, r6: u32, r7: u32, r8: u32, sid: **void) -> BOOL #foreign Advapi32;
CheckTokenMembership :: (token: HANDLE, sid: *void, is_member: *BOOL) -> BOOL #foreign Advapi32;
FreeSid              :: (sid: *void) -> *void #foreign Advapi32;

// Shell
Shell_NotifyIconW :: (message: u32, data: *NOTIFYICONDATAW) -> BOOL #foreign Shell32;

// DisplayConfig (user32)
GetDisplayConfigBufferSizes :: (flags: u32, path_count: *u32, mode_count: *u32) -> s32 #foreign User32;
QueryDisplayConfig          :: (flags: u32, path_count: *u32, paths: *DISPLAYCONFIG_PATH_INFO, mode_count: *u32, modes: *DISPLAYCONFIG_MODE_INFO, topology: *void) -> s32 #foreign User32;

// DWM
DwmFlush :: () -> HRESULT #foreign Dwmapi;
DwmSetWindowAttribute :: (hwnd: HWND, attribute: u32, pvAttribute: *void, cbAttribute: u32) -> HRESULT #foreign Dwmapi;
DwmGetWindowAttribute :: (hwnd: HWND, attribute: u32, pvAttribute: *void, cbAttribute: u32) -> HRESULT #foreign Dwmapi;

// OLE / COM
CoInitializeEx  :: (reserved: *void, flags: u32) -> HRESULT #foreign Ole32;
CoUninitialize  :: () #foreign Ole32;
CoCreateInstance :: (rclsid: *GUID, outer: *IUnknown, clsctx: u32, iid: *IID, ppv: **void) -> HRESULT #foreign Ole32;

// MAKEINTRESOURCE macro
MAKEINTRESOURCEW :: inline (id: s32) -> *u16 { return cast(*u16) cast,no_check(u64) id; }
MAKEINTRESOURCE_S16 :: inline (id: s32) -> *s16 { return cast(*s16) cast,no_check(u64) id; }

// LOWORD/HIWORD/GET_*_LPARAM: every narrowing cast is no_check because these
// are bit field extractions from a WPARAM/LPARAM, not range validating conversions
LOWORD :: inline (w: $T) -> u32 { return cast,no_check(u32)(cast,no_check(u64) w) & 0xFFFF; }
HIWORD :: inline (w: $T) -> u32 { return cast,no_check(u32)((cast,no_check(u64) w) >> 16) & 0xFFFF; }
GET_WHEEL_DELTA_WPARAM :: inline (w: WPARAM) -> s16 { return cast,no_check(s16) cast,no_check(u16)((cast,no_check(u64) w) >> 16); }
GET_X_LPARAM :: inline (l: LPARAM) -> s32 { return cast,no_check(s32) cast,no_check(s16) cast,no_check(u16)(cast,no_check(u64) l); }
GET_Y_LPARAM :: inline (l: LPARAM) -> s32 { return cast,no_check(s32) cast,no_check(s16) cast,no_check(u16)((cast,no_check(u64) l) >> 16); }

// standard cursor/icon IDs

IDI_APPLICATION :: 32512;

IMAGE_BITMAP    :: 0;
IMAGE_ICON      :: 1;
IMAGE_CURSOR    :: 2;
LR_DEFAULTCOLOR :: 0x0000;
LR_SHARED       :: 0x8000;
LoadImageW :: (hInst: HINSTANCE, name: *u16, type: u32, cx: s32, cy: s32, flags: u32) -> HANDLE #foreign User32;

Get_Dpi_For_Monitor_Fn :: #type (hmonitor: HMONITOR, dpi_type: u32, dpi_x: *u32, dpi_y: *u32) -> HRESULT #c_call;

dpi_resolver_tried:   bool;
dpi_resolver_shcore:  HMODULE;
dpi_resolver_fn:      Get_Dpi_For_Monitor_Fn;

dpi_for_point :: (x: s32, y: s32) -> s32 {
    if !dpi_resolver_tried {
        dpi_resolver_tried = true;
        dpi_resolver_shcore = LoadLibraryA("shcore.dll");
        if dpi_resolver_shcore {
            dpi_resolver_fn = cast(Get_Dpi_For_Monitor_Fn) GetProcAddress(dpi_resolver_shcore, "GetDpiForMonitor");
        }
    }

    if dpi_resolver_fn {
        pt: POINT;
        pt.x = x;
        pt.y = y;
        if overlay_window ClientToScreen(overlay_window, *pt);
        mon := MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
        if mon {
            dx: u32;
            dy: u32;
            if dpi_resolver_fn(mon, xx MDT_EFFECTIVE_DPI, *dx, *dy) == 0 && dy > 0 {
                return cast(s32) dy;
            }
        }
    }

    dc := GetDC(null);
    result: s32 = 96;
    if dc {
        result = GetDeviceCaps(dc, LOGPIXELSY);
        ReleaseDC(null, dc);
    }
    return result;
}

font_height_for_point :: inline (x: s32, y: s32, point_size: s32) -> s32 {
    return MulDiv(point_size, dpi_for_point(x, y), 72);
}

// use this as a background brush
COLOR_WINDOW_BRUSH :: cast(HBRUSH) cast,no_check(u64) (5 + 1);


// subset for IWICImagingFactory -> IWICBitmapEncoder PNG save

WICBitmapEncoderNoCache :: 2;

// Baked at compile time from the canonical UUID strings; zero runtime parsing.
CLSID_WIC_IMAGING_FACTORY       :: #run uid("cacaf262-9370-4615-a13b-9f5539da4c0a");
IID_WIC_IMAGING_FACTORY         :: #run uid("ec5ec8a9-c395-4314-9c77-54d7a935ff70");
GUID_CONTAINER_FORMAT_PNG       :: #run uid("1b7cfaf4-713f-473c-bbcd-6137425faeaf");
GUID_WIC_PIXEL_FORMAT_32BPPBGRA :: #run uid("6fddc324-4e03-4bfe-b185-3d77768dc90f");

// interface types

IStream       :: struct { #as using iunknown: IUnknown; }
IPropertyBag2 :: struct { #as using iunknown: IUnknown; }

IWICImagingFactory :: struct {
    #as using iunknown: IUnknown;
    #place iunknown; iwicimagingfactory_vtable: *IWICImagingFactory_VTable;
}
IWICStream :: struct {
    #as using iunknown: IUnknown;
    #place iunknown; iwicstream_vtable: *IWICStream_VTable;
}
IWICBitmapEncoder :: struct {
    #as using iunknown: IUnknown;
    #place iunknown; iwicbitmapencoder_vtable: *IWICBitmapEncoder_VTable;
}
IWICBitmapFrameEncode :: struct {
    #as using iunknown: IUnknown;
    #place iunknown; iwicbitmapframeencode_vtable: *IWICBitmapFrameEncode_VTable;
}

// vtables

IWICImagingFactory_VTable :: struct #type_info_none {
    using iunknown: IUnknown_VTable;
    CreateDecoderFromFilename:   *void;
    CreateDecoderFromStream:     *void;
    CreateDecoderFromFileHandle: *void;
    CreateComponentInfo:         *void;
    CreateDecoder:               *void;
    CreateEncoder: (this: *IWICImagingFactory, guidContainerFormat: *GUID, pguidVendor: *GUID, ppIEncoder: **IWICBitmapEncoder) -> HRESULT #cpp_method;
    CreatePalette:               *void;
    CreateFormatConverter:       *void;
    CreateBitmapScaler:          *void;
    CreateBitmapClipper:         *void;
    CreateBitmapFlipRotator:     *void;
    CreateStream: (this: *IWICImagingFactory, ppIWICStream: **IWICStream) -> HRESULT #cpp_method;
}

IWICStream_VTable :: struct #type_info_none {
    using iunknown: IUnknown_VTable;
    Read:         *void;
    Write:        *void;
    Seek:         *void;
    SetSize:      *void;
    CopyTo:       *void;
    Commit:       *void;
    Revert:       *void;
    LockRegion:   *void;
    UnlockRegion: *void;
    Stat:         *void;
    Clone:        *void;
    InitializeFromIStream:       *void;
    InitializeFromFilename: (this: *IWICStream, wzFileName: *u16, dwDesiredAccess: u32) -> HRESULT #cpp_method;
    InitializeFromMemory:        *void;
    InitializeFromIStreamRegion: *void;
}

IWICBitmapEncoder_VTable :: struct #type_info_none {
    using iunknown: IUnknown_VTable;
    Initialize: (this: *IWICBitmapEncoder, pIStream: *IStream, cacheOption: u32) -> HRESULT #cpp_method;
    GetContainerFormat:     *void;
    GetEncoderInfo:         *void;
    SetColorContexts:       *void;
    SetPalette:             *void;
    SetThumbnail:           *void;
    SetPreview:             *void;
    CreateNewFrame: (this: *IWICBitmapEncoder, ppIFrameEncode: **IWICBitmapFrameEncode, ppIEncoderOptions: **IPropertyBag2) -> HRESULT #cpp_method;
    Commit: (this: *IWICBitmapEncoder) -> HRESULT #cpp_method;
    GetMetadataQueryWriter: *void;
}

IWICBitmapFrameEncode_VTable :: struct #type_info_none {
    using iunknown: IUnknown_VTable;
    Initialize:      (this: *IWICBitmapFrameEncode, pIEncoderOptions: *IPropertyBag2) -> HRESULT #cpp_method;
    SetSize:         (this: *IWICBitmapFrameEncode, width: u32, height: u32) -> HRESULT #cpp_method;
    SetResolution:   *void;
    SetPixelFormat:  (this: *IWICBitmapFrameEncode, pPixelFormat: *GUID) -> HRESULT #cpp_method;
    SetColorContexts:*void;
    SetPalette:      *void;
    SetThumbnail:    *void;
    WritePixels:     (this: *IWICBitmapFrameEncode, lineCount: u32, cbStride: u32, cbBufferSize: u32, pbPixels: *u8) -> HRESULT #cpp_method;
    WriteSource:     *void;
    Commit:          (this: *IWICBitmapFrameEncode) -> HRESULT #cpp_method;
    GetMetadataQueryWriter: *void;
}

// method wrappers

IWICImagingFactory_CreateStream  :: inline (this: *IWICImagingFactory, ppIWICStream: **IWICStream)                                                  -> HRESULT { return this.iwicimagingfactory_vtable.CreateStream (this, ppIWICStream); }
IWICImagingFactory_CreateEncoder :: inline (this: *IWICImagingFactory, guidContainerFormat: *GUID, pguidVendor: *GUID, ppIEncoder: **IWICBitmapEncoder) -> HRESULT { return this.iwicimagingfactory_vtable.CreateEncoder(this, guidContainerFormat, pguidVendor, ppIEncoder); }

IWICStream_InitializeFromFilename :: inline (this: *IWICStream, wzFileName: *u16, dwDesiredAccess: u32) -> HRESULT { return this.iwicstream_vtable.InitializeFromFilename(this, wzFileName, dwDesiredAccess); }

IWICBitmapEncoder_Initialize    :: inline (this: *IWICBitmapEncoder, pIStream: *IStream, cacheOption: u32) -> HRESULT { return this.iwicbitmapencoder_vtable.Initialize(this, pIStream, cacheOption); }
IWICBitmapEncoder_CreateNewFrame:: inline (this: *IWICBitmapEncoder, ppIFrameEncode: **IWICBitmapFrameEncode, ppIEncoderOptions: **IPropertyBag2) -> HRESULT { return this.iwicbitmapencoder_vtable.CreateNewFrame(this, ppIFrameEncode, ppIEncoderOptions); }
IWICBitmapEncoder_Commit        :: inline (this: *IWICBitmapEncoder) -> HRESULT { return this.iwicbitmapencoder_vtable.Commit(this); }

IWICBitmapFrameEncode_Initialize     :: inline (this: *IWICBitmapFrameEncode, pIEncoderOptions: *IPropertyBag2) -> HRESULT { return this.iwicbitmapframeencode_vtable.Initialize(this, pIEncoderOptions); }
IWICBitmapFrameEncode_SetSize        :: inline (this: *IWICBitmapFrameEncode, width: u32, height: u32) -> HRESULT { return this.iwicbitmapframeencode_vtable.SetSize(this, width, height); }
IWICBitmapFrameEncode_SetPixelFormat :: inline (this: *IWICBitmapFrameEncode, requested_format: GUID) -> bool {
    actual_format := requested_format;
    if FAILED(this.iwicbitmapframeencode_vtable.SetPixelFormat(this, *actual_format)) return false;
    return !memcmp(*actual_format, *requested_format, size_of(GUID));
}
IWICBitmapFrameEncode_WritePixels    :: inline (this: *IWICBitmapFrameEncode, lineCount: u32, cbStride: u32, cbBufferSize: u32, pbPixels: *u8) -> HRESULT { return this.iwicbitmapframeencode_vtable.WritePixels(this, lineCount, cbStride, cbBufferSize, pbPixels); }
IWICBitmapFrameEncode_Commit         :: inline (this: *IWICBitmapFrameEncode) -> HRESULT { return this.iwicbitmapframeencode_vtable.Commit(this); }
