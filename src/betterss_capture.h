/* BetterSS - Desktop Capture Types */

#pragma once

struct monitor_duplication
{
    IDXGIOutputDuplication *Duplication;
    ID3D11Texture2D *Texture;
    ID3D11ShaderResourceView *SRV;
    RECT Bounds;
    DXGI_MODE_ROTATION Rotation;
    int IsValid;
    int HasFrame;
};

#define MAX_MONITORS 8

struct capture_state
{
    ID3D11Device *Device;
    monitor_duplication Monitors[MAX_MONITORS];
    uint32_t MonitorCount;
    RECT VirtualScreen;
};

static int CaptureIsValid(capture_state *Capture);
static int RefreshCaptureState(capture_state *Capture, ID3D11Device *Device);
static void ReleaseDuplications(capture_state *Capture);
static void ReleaseCaptureState(capture_state *Capture);
static int CaptureAllMonitors(capture_state *Capture);
static void ReleaseAllFrames(capture_state *Capture);
