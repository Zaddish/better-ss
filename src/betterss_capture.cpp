static int CaptureIsValid(capture_state *Capture) {
    return(Capture->Monitors && Capture->MonitorCount > 0);
}

static void ReleaseMonitorDuplication(monitor_duplication *Mon) {
    if(Mon->Texture) {
        Mon->Texture->Release();
        Mon->Texture = 0;
    }
    if(Mon->Duplication) {
        Mon->Duplication->Release();
        Mon->Duplication = 0;
    }
    Mon->IsValid = 0;
    Mon->HasFrame = 0;
}

static void ReleaseCaptureState(capture_state *Capture) {
    for(uint32_t i = 0; i < Capture->MonitorCount; i++) {
        ReleaseMonitorDuplication(&Capture->Monitors[i]);
    }
    if(Capture->Monitors) {
        VirtualFree(Capture->Monitors, 0, MEM_RELEASE);
    }
    *Capture = {};
}

static capture_state AcquireCaptureState(ID3D11Device *Device) {
    capture_state Result = {};
    Result.Device = Device;

    Result.VirtualScreen.left = GetSystemMetrics(SM_XVIRTUALSCREEN);
    Result.VirtualScreen.top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    Result.VirtualScreen.right = Result.VirtualScreen.left + GetSystemMetrics(SM_CXVIRTUALSCREEN);
    Result.VirtualScreen.bottom = Result.VirtualScreen.top + GetSystemMetrics(SM_CYVIRTUALSCREEN);

    Result.MonitorCapacity = 16;
    Result.Monitors = (monitor_duplication *)VirtualAlloc(0, 
        Result.MonitorCapacity * sizeof(monitor_duplication), 
        MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);

    if(!Result.Monitors) return(Result);

    IDXGIDevice *DxgiDevice = 0;
    if(FAILED(Device->QueryInterface(IID_PPV_ARGS(&DxgiDevice)))) {
        return(Result);
    }

    IDXGIAdapter *Adapter = 0;
    if(FAILED(DxgiDevice->GetAdapter(&Adapter))) {
        DxgiDevice->Release();
        return(Result);
    }

    IDXGIOutput *Output = 0;
    for(UINT OutputIdx = 0; SUCCEEDED(Adapter->EnumOutputs(OutputIdx, &Output)); OutputIdx++) {
        if(Result.MonitorCount >= Result.MonitorCapacity) {
            Output->Release();
            break;
        }

        DXGI_OUTPUT_DESC OutputDesc;
        Output->GetDesc(&OutputDesc);

        IDXGIOutput1 *Output1 = 0;
        if(SUCCEEDED(Output->QueryInterface(IID_PPV_ARGS(&Output1)))) {
            monitor_duplication *Mon = &Result.Monitors[Result.MonitorCount];
            Mon->Bounds = OutputDesc.DesktopCoordinates;
            Mon->Rotation = OutputDesc.Rotation;

            if(SUCCEEDED(Output1->DuplicateOutput(Device, &Mon->Duplication))) {
                Mon->IsValid = 1;
                Result.MonitorCount++;
            }

            Output1->Release();
        }

        Output->Release();
    }

    Adapter->Release();
    DxgiDevice->Release();

    return(Result);
}

static void ReleaseFrame(monitor_duplication *Mon) {
    if(Mon->HasFrame) {
        if(Mon->Texture) {
            Mon->Texture->Release();
            Mon->Texture = 0;
        }
        Mon->Duplication->ReleaseFrame();
        Mon->HasFrame = 0;
    }
}

static void ReleaseAllFrames(capture_state *Capture) {
    for(uint32_t i = 0; i < Capture->MonitorCount; i++) {
        ReleaseFrame(&Capture->Monitors[i]);
    }
}

static int CaptureMonitor(monitor_duplication *Mon) {
    if(!Mon->IsValid || !Mon->Duplication) return(0);

    ReleaseFrame(Mon);

    IDXGIResource *Resource = 0;
    DXGI_OUTDUPL_FRAME_INFO FrameInfo;

    HRESULT hr = Mon->Duplication->AcquireNextFrame(16, &FrameInfo, &Resource);

    if(hr == DXGI_ERROR_WAIT_TIMEOUT) { return(0); }

    if(SUCCEEDED(hr)) {
        hr = Resource->QueryInterface(IID_PPV_ARGS(&Mon->Texture));
        Resource->Release();

        if(SUCCEEDED(hr)) {
            Mon->HasFrame = 1;
            return(1);
        }
    }
    else if(hr == DXGI_ERROR_ACCESS_LOST) {
        return(-1); // Signal lost access
    }

    return(0);
}

static int CaptureAllMonitors(capture_state *Capture) {
    int Result = 0;
    int AccessLost = 0;

    for(uint32_t i = 0; i < Capture->MonitorCount; i++) {
        int MonResult = CaptureMonitor(&Capture->Monitors[i]);
        if(MonResult == 1) {
            Result = 1;
        }
        else if(MonResult == -1) {
            AccessLost = 1;
        }
    }

    if(AccessLost) return(-1);

    // if we didn't capture anything, but didn't lose access, it might just be timeout?
    // however, since we release frames before capture, we really want at least one successful capture  
    // to show anything
    return(Result);
}
