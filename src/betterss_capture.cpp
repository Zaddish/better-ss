static int CaptureIsValid(capture_state *Capture) {
    return(Capture->IsInitialized && Capture->Monitors && Capture->MonitorCount > 0);
}

static void ReleaseMonitorDuplication(monitor_duplication *Mon) {
    if(Mon->SRV) {
        Mon->SRV->Release();
        Mon->SRV = 0;
    }
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

static void InitializeCaptureState(capture_state *Capture) {
    if(Capture->IsInitialized) return;
    
    Capture->MonitorCapacity = 8;
    Capture->Monitors = (monitor_duplication *)VirtualAlloc(0, 
        Capture->MonitorCapacity * sizeof(monitor_duplication), 
        MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    
    if(Capture->Monitors) {
        Capture->IsInitialized = 1;
    }
}

static void ReleaseDuplications(capture_state *Capture) {
    for(uint32_t i = 0; i < Capture->MonitorCount; i++) {
        ReleaseMonitorDuplication(&Capture->Monitors[i]);
    }
    Capture->MonitorCount = 0;
    Capture->Device = 0;
}

static void ReleaseCaptureState(capture_state *Capture) {
    ReleaseDuplications(Capture);
    if(Capture->Monitors) {
        VirtualFree(Capture->Monitors, 0, MEM_RELEASE);
        Capture->Monitors = 0;
    }
    Capture->IsInitialized = 0;
    Capture->MonitorCapacity = 0;
}

static int RefreshCaptureState(capture_state *Capture, ID3D11Device *Device) {
    if(!Capture->IsInitialized || !Capture->Monitors) return 0;
    
    ReleaseDuplications(Capture);
    
    Capture->Device = Device;
    
    Capture->VirtualScreen.left = GetSystemMetrics(SM_XVIRTUALSCREEN);
    Capture->VirtualScreen.top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    Capture->VirtualScreen.right = Capture->VirtualScreen.left + GetSystemMetrics(SM_CXVIRTUALSCREEN);
    Capture->VirtualScreen.bottom = Capture->VirtualScreen.top + GetSystemMetrics(SM_CYVIRTUALSCREEN);

    IDXGIDevice *DxgiDevice = 0;
    if(FAILED(Device->QueryInterface(IID_PPV_ARGS(&DxgiDevice)))) {
        return 0;
    }

    IDXGIAdapter *Adapter = 0;
    if(FAILED(DxgiDevice->GetAdapter(&Adapter))) {
        DxgiDevice->Release();
        return 0;
    }

    IDXGIOutput *Output = 0;
    for(UINT OutputIdx = 0; SUCCEEDED(Adapter->EnumOutputs(OutputIdx, &Output)); OutputIdx++) {
        if(Capture->MonitorCount >= Capture->MonitorCapacity) {
            Output->Release();
            break;
        }

        DXGI_OUTPUT_DESC OutputDesc;
        Output->GetDesc(&OutputDesc);

        monitor_duplication *Mon = &Capture->Monitors[Capture->MonitorCount];
        Mon->Bounds = OutputDesc.DesktopCoordinates;
        Mon->Rotation = OutputDesc.Rotation;

        IDXGIOutput5 *Output5 = 0;
        if(SUCCEEDED(Output->QueryInterface(IID_PPV_ARGS(&Output5)))) {
            DXGI_FORMAT Formats[] = { DXGI_FORMAT_B8G8R8A8_UNORM };
            if(SUCCEEDED(Output5->DuplicateOutput1(Device, 0, ArrayCount(Formats), Formats, &Mon->Duplication))) {
                Mon->IsValid = 1;
                Capture->MonitorCount++;
            }
            Output5->Release();
        }

        Output->Release();
    }

    Adapter->Release();
    DxgiDevice->Release();

    return(Capture->MonitorCount > 0 ? 1 : 0);
}

static void ReleaseFrame(monitor_duplication *Mon) {
    if(Mon->HasFrame) {
        if(Mon->SRV) {
            Mon->SRV->Release();
            Mon->SRV = 0;
        }
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

static int CaptureMonitor(monitor_duplication *Mon, ID3D11Device *Device) {
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
            D3D11_SHADER_RESOURCE_VIEW_DESC SRVDesc = {};
            SRVDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
            SRVDesc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
            SRVDesc.Texture2D.MipLevels = 1;
            
            hr = Device->CreateShaderResourceView(Mon->Texture, &SRVDesc, &Mon->SRV);
            if(SUCCEEDED(hr)) {
                Mon->HasFrame = 1;
                return(1);
            }

            Mon->Texture->Release();
            Mon->Texture = 0;
            Mon->Duplication->ReleaseFrame();
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
        int MonResult = CaptureMonitor(&Capture->Monitors[i], Capture->Device);
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
