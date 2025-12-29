/* BetterSS - Desktop Capture Types */

#pragma once

struct monitor_duplication
{
    IDXGIOutputDuplication *Duplication;
    ID3D11Texture2D *Texture;
    RECT Bounds;
    DXGI_MODE_ROTATION Rotation;
    int IsValid;
    int HasFrame;
};

struct capture_state
{
    ID3D11Device *Device;
    monitor_duplication *Monitors;
    uint32_t MonitorCount;
    uint32_t MonitorCapacity;
    RECT VirtualScreen;
};

static int CaptureIsValid(capture_state *Capture);
static capture_state AcquireCaptureState(ID3D11Device *Device);
static void ReleaseCaptureState(capture_state *Capture);
static int CaptureAllMonitors(capture_state *Capture);
static void ReleaseAllFrames(capture_state *Capture);
