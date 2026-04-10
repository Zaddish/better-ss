#include "betterss.h"
#include "betterss_d3d11.h"
#include "betterss_nvapi.h"

static int IsRunningElevated(void) {
    int Result = 0;
    SID_IDENTIFIER_AUTHORITY NtAuth = SECURITY_NT_AUTHORITY;
    PSID AdminGroup = 0;
    if(AllocateAndInitializeSid(&NtAuth, 2, SECURITY_BUILTIN_DOMAIN_RID, DOMAIN_ALIAS_RID_ADMINS,
                                0,0,0,0,0,0, &AdminGroup)) {
        BOOL IsMember = FALSE;
        CheckTokenMembership(0, AdminGroup, &IsMember);
        Result = IsMember ? 1 : 0;
        FreeSid(AdminGroup);
    }
    return(Result);
}

static int RefreshNvMonitors(nv_capture *Nv) {
    Nv->MonitorCount = 0;

    UINT32 PathCount = 0, ModeCount = 0;
    if(GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &PathCount, &ModeCount) != ERROR_SUCCESS) return(0);

    DISPLAYCONFIG_PATH_INFO Paths[16] = {};
    DISPLAYCONFIG_MODE_INFO Modes[64] = {};
    if(PathCount > ArrayCount(Paths)) PathCount = (UINT32)ArrayCount(Paths);
    if(ModeCount > ArrayCount(Modes)) ModeCount = (UINT32)ArrayCount(Modes);

    if(QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &PathCount, Paths, &ModeCount, Modes, 0) != ERROR_SUCCESS) return(0);

    Nv->VirtualScreen.left = GetSystemMetrics(SM_XVIRTUALSCREEN);
    Nv->VirtualScreen.top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    Nv->VirtualScreen.right = Nv->VirtualScreen.left + GetSystemMetrics(SM_CXVIRTUALSCREEN);
    Nv->VirtualScreen.bottom = Nv->VirtualScreen.top + GetSystemMetrics(SM_CYVIRTUALSCREEN);

    for(UINT32 P = 0; P < PathCount && Nv->MonitorCount < MAX_MONITORS; P++) {
        DISPLAYCONFIG_PATH_INFO *Path = &Paths[P];
        if(Path->sourceInfo.modeInfoIdx == DISPLAYCONFIG_PATH_MODE_IDX_INVALID) continue;
        if(Path->sourceInfo.modeInfoIdx >= ModeCount) continue;

        DISPLAYCONFIG_MODE_INFO *Mode = &Modes[Path->sourceInfo.modeInfoIdx];
        if(Mode->infoType != DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE) continue;

        nv_monitor *Mon = &Nv->Monitors[Nv->MonitorCount];
        Mon->TargetId = Path->targetInfo.id;
        Mon->Rotation = Path->targetInfo.rotation;

        uint32_t SrcW = Mode->sourceMode.width;
        uint32_t SrcH = Mode->sourceMode.height;
        int Rotated90 = (Mon->Rotation == 2 || Mon->Rotation == 4);
        uint32_t DeskW = Rotated90 ? SrcH : SrcW;
        uint32_t DeskH = Rotated90 ? SrcW : SrcH;

        Mon->Bounds.left = Mode->sourceMode.position.x;
        Mon->Bounds.top = Mode->sourceMode.position.y;
        Mon->Bounds.right = Mon->Bounds.left + (int)DeskW;
        Mon->Bounds.bottom = Mon->Bounds.top + (int)DeskH;
        Nv->MonitorCount++;
    }

    return(Nv->MonitorCount > 0 ? 1 : 0);
}

static int InitNvCapture(nv_capture *Nv, ID3D11Device *Device) {
    *Nv = {};

    if(!IsRunningElevated()) return(0);

    HMODULE Dll = LoadLibraryExA("nvapi64.dll", 0, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if(!Dll) return(0);

    NvQueryInterfaceFn QI = (NvQueryInterfaceFn)GetProcAddress(Dll, "nvapi_QueryInterface");
    if(!QI) { FreeLibrary(Dll); return(0); }

    NvInitializeFn Init = (NvInitializeFn)QI(0x0150E828);
    if(!Init || Init() != 0) { FreeLibrary(Dll); return(0); }

    NvEnumPhysicalGpusFn EnumGPUs = (NvEnumPhysicalGpusFn)QI(0xE5AC921F);
    void *GpuHandles[64] = {};
    uint32_t GpuCount = 0;
    if(!EnumGPUs || EnumGPUs(GpuHandles, &GpuCount) != 0 || GpuCount == 0) { FreeLibrary(Dll); return(0); }

    NvReadScanoutFn ReadFn = (NvReadScanoutFn)QI(0xBCB1C536);
    if(!ReadFn) { FreeLibrary(Dll); return(0); }

    Nv->Dll = Dll;
    Nv->ReadScanout = ReadFn;
    Nv->GpuHandle = GpuHandles[0];

    if(!RefreshNvMonitors(Nv)) { FreeLibrary(Dll); *Nv = {}; return(0); }

    void *TestData = 0;
    nv_read_scanout_params TestParams = {};
    TestParams.Version = sizeof(nv_read_scanout_params) | (1 << 16);
    TestParams.TargetId = Nv->Monitors[0].TargetId;
    TestParams.PhysicalGpu = Nv->GpuHandle;
    TestParams.DataOut = &TestData;

    uint32_t Status = ReadFn(Device, &TestParams);
    if(TestData) VirtualFree(TestData, 0, MEM_RELEASE);

    if(Status != 0) {
        FreeLibrary(Dll);
        *Nv = {};
        return(0);
    }

    Nv->IsAvailable = 1;
    return(1);
}

static void ReleaseNvCapture(nv_capture *Nv) {
    if(Nv->Dll) FreeLibrary(Nv->Dll);
    *Nv = {};
}

// D3DDDIFMT_A2B10G10R10 (format 31): R[9:0] G[19:10] B[29:20] A[31:30] -> B8G8R8A8
static inline uint32_t Convert10Bit(uint32_t V) {
    return ((V >>  2) & 0xFF) << 16
         | ((V >> 12) & 0xFF) <<  8
         | ((V >> 22) & 0xFF)
         | 0xFF000000;
}

static inline uint32_t ConvertPixel(uint32_t V, int Is10Bit) {
    return(Is10Bit ? Convert10Bit(V) : V);
}

// NOTE(zaddish): all monitors return format 31 regardless of actual panel bit depth,
// not sure why, maybe DWM composites at that depth and the driver upscales at scanout?
// if a display is in HDR mode the scanout might be PQ encoded (BT.2100 ST.2084) instead of
// the sRGB ish values i'm assuming here, which would make this conversion look washed out
// no working HDR10 display to test so we can just handle SDR for now
// https://learn.microsoft.com/en-us/windows/win32/direct3darticles/high-dynamic-range
static void ConvertPixels(uint32_t *Dst, uint32_t DstW,
                          uint32_t *Src, uint32_t SrcW, uint32_t SrcH,
                          uint32_t Rotation, int Is10Bit) {
    for(uint32_t SrcY = 0; SrcY < SrcH; SrcY++) {
        for(uint32_t SrcX = 0; SrcX < SrcW; SrcX++) {
            uint32_t DstX, DstY;

            switch(Rotation) {
                case 2:  DstX = SrcH - 1 - SrcY; DstY = SrcX;             break;
                case 3:  DstX = SrcW - 1 - SrcX; DstY = SrcH - 1 - SrcY; break;
                case 4:  DstX = SrcY;             DstY = SrcW - 1 - SrcX;  break;
                default: DstX = SrcX;             DstY = SrcY;             break;
            }

            Dst[DstY * DstW + DstX] = ConvertPixel(Src[SrcY * SrcW + SrcX], Is10Bit);
        }
    }
}

static int NvCaptureAllMonitors(nv_capture *Nv, ID3D11Device *Device) {
    if(!Nv->IsAvailable) return(0);

    int AnySuccess = 0;

    for EachIndex(i, Nv->MonitorCount) {
        nv_monitor *Mon = &Nv->Monitors[i];

        void *RawData = 0;
        nv_read_scanout_params Params = {};
        Params.Version = sizeof(nv_read_scanout_params) | (1 << 16);
        Params.TargetId = Mon->TargetId;
        Params.PhysicalGpu = Nv->GpuHandle;
        Params.DataOut = &RawData;

        uint32_t Status = Nv->ReadScanout(Device, &Params);
        if(Status != 0 || !RawData) continue;

        uint32_t CapturedW = Params.Rect.Right - Params.Rect.Left;
        uint32_t CapturedH = Params.Rect.Bottom - Params.Rect.Top;
        uint32_t DesktopW = (uint32_t)(Mon->Bounds.right - Mon->Bounds.left);
        uint32_t DesktopH = (uint32_t)(Mon->Bounds.bottom - Mon->Bounds.top);
        int Is10Bit = (Params.Format == 31);

        uint32_t *Converted = PushArray(&Nv->ConvertArena, uint32_t, DesktopW * DesktopH);
        if(!Converted) { VirtualFree(RawData, 0, MEM_RELEASE); continue; }

        ConvertPixels(Converted, DesktopW, (uint32_t *)RawData, CapturedW, CapturedH, Mon->Rotation, Is10Bit);
        VirtualFree(RawData, 0, MEM_RELEASE);

        Mon->Pixels = Converted;
        Mon->PixelW = DesktopW;
        Mon->PixelH = DesktopH;
        AnySuccess = 1;
    }

    return(AnySuccess);
}

static void CacheNvBackground(betterss_renderer *R, nv_capture *Nv) {
    GetCachedTexture(R, &R->CachedBackground, R->Width, R->Height,
        D3D11_USAGE_DEFAULT, D3D11_BIND_SHADER_RESOURCE, 0);
    if(!R->CachedBackground.Texture) return;

    int OriginX = Nv->VirtualScreen.left;
    int OriginY = Nv->VirtualScreen.top;

    for EachIndex(i, Nv->MonitorCount) {
        nv_monitor *Mon = &Nv->Monitors[i];
        if(!Mon->Pixels) continue;

        D3D11_BOX Box = {};
        Box.left = (UINT)(Mon->Bounds.left - OriginX);
        Box.top = (UINT)(Mon->Bounds.top - OriginY);
        Box.right = Box.left + Mon->PixelW;
        Box.bottom = Box.top + Mon->PixelH;
        Box.back = 1;

        R->Context->UpdateSubresource(R->CachedBackground.Texture, 0, &Box, Mon->Pixels, Mon->PixelW * 4, 0);
        Mon->Pixels = 0;
    }

    ArenaReset(&Nv->ConvertArena);
}
