#pragma once

struct nv_rect { uint32_t Left, Top, Right, Bottom; };

struct nv_read_scanout_params
{
    uint32_t Version;
    uint32_t TargetId;
    void    *PhysicalGpu;
    nv_rect  Rect;
    struct {
        uint64_t QueueIndex            : 4;
        uint64_t MpoIndex              : 3;
        uint64_t RightStereoEye        : 1;
        uint64_t LeftAndRightStereoEye : 1;
        uint64_t OsRenderBuffer        : 1;
        uint64_t ScanoutBuffer         : 1;
        uint64_t Warping               : 1;
        uint64_t PerPixelIntensity     : 1;
        uint64_t IntensityRGTexture    : 1;
        uint64_t IntensityBATexture    : 1;
        uint64_t GrayscaleDome         : 1;
        uint64_t GrayscaleEizo         : 1;
        uint64_t Yuv420                : 1;
        uint64_t Yuv422                : 1;
        uint64_t Yuv444                : 1;
        uint64_t Hdr                   : 1;
        uint64_t SmoothScaling         : 1;
        uint64_t Eshift                : 1;
        uint64_t VirtualSplit          : 1;
        uint64_t StreamSource          : 1;
        uint64_t Reserved              : 39;
    } Flags;
    uint32_t Format;
    uint32_t _Pad;
    void   **DataOut;
};

static_assert(sizeof(nv_read_scanout_params) == 56, "NVAPI struct layout mismatch");

typedef void    *(*NvQueryInterfaceFn)(uint32_t);
typedef uint32_t (*NvInitializeFn)();
typedef uint32_t (*NvEnumPhysicalGpusFn)(void *Handles[64], uint32_t *Count);
typedef uint32_t (*NvReadScanoutFn)(ID3D11Device *Device, nv_read_scanout_params *Params);

struct nv_monitor
{
    uint32_t TargetId;
    RECT Bounds;
    uint32_t Rotation;
    uint32_t *Pixels;
    uint32_t PixelW;
    uint32_t PixelH;
};

struct nv_capture
{
    int IsAvailable;
    HMODULE Dll;
    NvReadScanoutFn ReadScanout;
    void *GpuHandle;
    nv_monitor Monitors[MAX_MONITORS];
    uint32_t MonitorCount;
    RECT VirtualScreen;
    memory_arena ConvertArena;
};

static int InitNvCapture(nv_capture *Nv, ID3D11Device *Device);
static void ReleaseNvCapture(nv_capture *Nv);
static int RefreshNvMonitors(nv_capture *Nv);
static int NvCaptureAllMonitors(nv_capture *Nv, ID3D11Device *Device);
static void CacheNvBackground(betterss_renderer *R, nv_capture *Nv);
