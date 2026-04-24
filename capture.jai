MAX_MONITORS :: 8;

Monitor_Duplication :: struct {
    duplication: *IDXGIOutputDuplication;
    texture:     *ID3D11Texture2D;
    srv:         *ID3D11ShaderResourceView;
    bounds:      RECT;
    rotation:    DXGI_MODE_ROTATION;
    is_valid:    bool;
    has_frame:   bool;
}

Capture_State :: struct {
    device:         *ID3D11Device;
    monitors:       [MAX_MONITORS] Monitor_Duplication;
    monitor_count:  u32;
    virtual_screen: RECT;
}

capture_is_valid :: (c: *Capture_State) -> bool {
    return c.monitor_count > 0;
}

release_frame :: (mon: *Monitor_Duplication) {
    if mon.has_frame {
        safe_release_and_reset(*mon.srv);
        safe_release_and_reset(*mon.texture);
        if mon.duplication IDXGIOutputDuplication_ReleaseFrame(mon.duplication);
        mon.has_frame = false;
    }
}

release_monitor_duplication :: (mon: *Monitor_Duplication) {
    release_frame(mon);
    com_release_all(mon);
    mon.is_valid = false;
}

release_duplications :: (c: *Capture_State) {
    for * mon: array_view(c.monitors, 0, c.monitor_count)  release_monitor_duplication(mon);
    c.monitor_count = 0;
    c.device = null;
}

release_all_frames :: (c: *Capture_State) {
    for * mon: array_view(c.monitors, 0, c.monitor_count)  release_frame(mon);
}

refresh_capture_state :: (c: *Capture_State, device: *ID3D11Device) -> bool {
    release_duplications(c);

    c.device = device;

    c.virtual_screen.left   = GetSystemMetrics(SM_XVIRTUALSCREEN);
    c.virtual_screen.top    = GetSystemMetrics(SM_YVIRTUALSCREEN);
    c.virtual_screen.right  = c.virtual_screen.left + GetSystemMetrics(SM_CXVIRTUALSCREEN);
    c.virtual_screen.bottom = c.virtual_screen.top  + GetSystemMetrics(SM_CYVIRTUALSCREEN);

    dxgi_device: *IDXGIDevice;
    if FAILED(IUnknown_QueryInterface(device, *uid(IDXGIDevice_UUID), xx *dxgi_device)) {
        return false;
    }
    defer safe_release(dxgi_device);

    adapter: *IDXGIAdapter;
    if FAILED(IDXGIDevice_GetAdapter(dxgi_device, *adapter)) return false;
    defer safe_release(adapter);

    output_index: u32 = 0;
    while true {
        output: *IDXGIOutput;
        hr := IDXGIAdapter_EnumOutputs(adapter, output_index, *output);
        if FAILED(hr) break;
        output_index += 1;

        if c.monitor_count >= MAX_MONITORS {
            safe_release(output);
            break;
        }

        output_desc: DXGI_OUTPUT_DESC;
        IDXGIOutput_GetDesc(output, *output_desc);

        mon := *c.monitors[c.monitor_count];
        mon.bounds   = output_desc.DesktopCoordinates;
        mon.rotation = output_desc.Rotation;

        output5: *IDXGIOutput5;
        if SUCCEEDED(IUnknown_QueryInterface(output, *uid(IDXGIOutput5_UUID), xx *output5)) {
            formats : [1] DXGI_FORMAT = .[.B8G8R8A8_UNORM];
            hr2 := IDXGIOutput5_DuplicateOutput1(output5, xx device, 0, formats.count, formats.data, *mon.duplication);
            if SUCCEEDED(hr2) {
                mon.is_valid = true;
                c.monitor_count += 1;
            }
            safe_release(output5);
        }

        safe_release(output);
    }

    return c.monitor_count > 0;
}

// returns: 1 = got frame, 0 = no frame, -1 = access lost (caller must refresh)
capture_monitor :: (mon: *Monitor_Duplication, device: *ID3D11Device, timeout_ms: u32) -> s32 {
    if !mon.is_valid || !mon.duplication return 0;

    release_frame(mon);

    resource:   *IDXGIResource;
    frame_info: DXGI_OUTDUPL_FRAME_INFO;

    hr := IDXGIOutputDuplication_AcquireNextFrame(mon.duplication, timeout_ms, *frame_info, *resource);

    if hr == DXGI_ERROR_WAIT_TIMEOUT return 0;
    if hr == DXGI_ERROR_ACCESS_LOST  return -1;
    if FAILED(hr) return 0;

    hr = IUnknown_QueryInterface(resource, *uid(ID3D11Texture2D_UUID), xx *mon.texture);
    safe_release(resource);

    if SUCCEEDED(hr) {
        srv_desc: D3D11_SHADER_RESOURCE_VIEW_DESC;
        srv_desc.Format                    = .B8G8R8A8_UNORM;
        srv_desc.ViewDimension             = .TEXTURE2D;
        srv_desc.Texture2D.MipLevels       = 1;

        hr = ID3D11Device_CreateShaderResourceView(device, xx mon.texture, *srv_desc, *mon.srv);
        if SUCCEEDED(hr) {
            mon.has_frame = true;
            return 1;
        }

        IUnknown_Release(mon.texture);
        mon.texture = null;
        IDXGIOutputDuplication_ReleaseFrame(mon.duplication);
    }

    return 0;
}

capture_all_monitors :: (c: *Capture_State) -> s32 {
    // NOTE(zaddish): thank you gnif from Looking Glass (his comment):
    // https://github.com/gnif/LookingGlass/blob/7f31ecf5e572ecdfa64306be76e49ee537f5fdbf/host/platform/Windows/capture/DXGI/src/dxgi.c#L1077
    // this is a bit of a hack as it causes this thread to block until the next
    // present, by doing this we can allow the mouse updates to accumulate instead
    // of being called to process every single one. The only caveat is we are
    // limited to the refresh rate of the monitor.
    DwmFlush();

    result:      s32 = 0;
    access_lost: bool = false;

    for * mon: array_view(c.monitors, 0, c.monitor_count) {
        mon_result := capture_monitor(mon, c.device, 32);
        if      mon_result ==  1  result = 1;
        else if mon_result == -1  access_lost = true;
    }

    if access_lost return -1;
    return result;
}

#scope_file

Dwmapi_Lib :: #system_library "Dwmapi";
DwmFlush :: () -> HRESULT #foreign Dwmapi_Lib;
