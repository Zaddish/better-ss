Nv_Rect :: struct {
    left:   u32;
    top:    u32;
    right:  u32;
    bottom: u32;
}

// NOTE(zaddish): cpp had this as an anonymous bitfield struct but we never set
// any of those bits so just stash it as a zero u64 and #assert below
Nv_Read_Scanout_Params :: struct {
    version:      u32;
    target_id:    u32;
    physical_gpu: *void;
    rect:         Nv_Rect;
    flags:        u64;
    format:       u32;
    _pad:         u32;
    data_out:     **void;
}

#assert(size_of(Nv_Read_Scanout_Params) == 56);

Nv_Query_Interface_Fn    :: #type (id: u32) -> *void #c_call;
Nv_Initialize_Fn         :: #type () -> u32 #c_call;
Nv_Enum_Physical_Gpus_Fn :: #type (handles: *[64] *void, count: *u32) -> u32 #c_call;
Nv_Read_Scanout_Fn       :: #type (device: *ID3D11Device, params: *Nv_Read_Scanout_Params) -> u32 #c_call;

Nv_Monitor :: struct {
    target_id: u32;
    bounds:    RECT;
    rotation:  u32;
    pixels:    *u32;
    pixel_w:   u32;
    pixel_h:   u32;
}

Nv_Capture :: struct {
    is_available: bool;
    dll:          HMODULE;
    read_scanout: Nv_Read_Scanout_Fn;
    gpu_handle:   *void;
    monitors:     [MAX_MONITORS] Nv_Monitor;
    monitor_count: u32;
    virtual_screen: RECT;
    convert_arena: Flat_Pool;
}

is_running_elevated :: () -> bool {
    auth := SECURITY_NT_AUTHORITY_VALUE;
    admin_group: *void;
    if !AllocateAndInitializeSid(*auth, 2, SECURITY_BUILTIN_DOMAIN_RID, DOMAIN_ALIAS_RID_ADMINS,
                                 0, 0, 0, 0, 0, 0, *admin_group) {
        return false;
    }
    defer FreeSid(admin_group);

    is_member: BOOL;
    CheckTokenMembership(null, admin_group, *is_member);
    return is_member == .TRUE;
}

refresh_nv_monitors :: (nv: *Nv_Capture) -> bool {
    nv.monitor_count = 0;

    path_count: u32;
    mode_count: u32;
    if GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, *path_count, *mode_count) != ERROR_SUCCESS {
        return false;
    }

    paths: [16] DISPLAYCONFIG_PATH_INFO;
    modes: [64] DISPLAYCONFIG_MODE_INFO;
    if path_count > paths.count path_count = paths.count;
    if mode_count > modes.count mode_count = modes.count;

    if QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, *path_count, paths.data, *mode_count, modes.data, null) != ERROR_SUCCESS {
        return false;
    }

    nv.virtual_screen.left   = GetSystemMetrics(SM_XVIRTUALSCREEN);
    nv.virtual_screen.top    = GetSystemMetrics(SM_YVIRTUALSCREEN);
    nv.virtual_screen.right  = nv.virtual_screen.left + GetSystemMetrics(SM_CXVIRTUALSCREEN);
    nv.virtual_screen.bottom = nv.virtual_screen.top  + GetSystemMetrics(SM_CYVIRTUALSCREEN);

    for p: 0 .. cast(s64) path_count - 1 {
        if nv.monitor_count >= MAX_MONITORS break;

        path := *paths[p];
        if path.sourceInfo.modeInfoIdx == DISPLAYCONFIG_PATH_MODE_IDX_INVALID continue;
        if path.sourceInfo.modeInfoIdx >= mode_count continue;

        mode := *modes[path.sourceInfo.modeInfoIdx];
        if mode.infoType != .SOURCE continue;

        mon := *nv.monitors[nv.monitor_count];
        mon.target_id = path.targetInfo.id;
        mon.rotation  = path.targetInfo.rotation;

        src_w := mode.sourceMode.width;
        src_h := mode.sourceMode.height;
        rotated_90 := mon.rotation == 2 || mon.rotation == 4;
        desk_w := ifx rotated_90 then src_h else src_w;
        desk_h := ifx rotated_90 then src_w else src_h;

        mon.bounds.left   = mode.sourceMode.position.x;
        mon.bounds.top    = mode.sourceMode.position.y;
        mon.bounds.right  = mon.bounds.left + cast(s32) desk_w;
        mon.bounds.bottom = mon.bounds.top  + cast(s32) desk_h;
        nv.monitor_count += 1;
    }

    return nv.monitor_count > 0;
}

init_nv_capture :: (nv: *Nv_Capture, device: *ID3D11Device) -> bool {
    <<nv = Nv_Capture.{};

    if !is_running_elevated() return false;

    dll := LoadLibraryExA("nvapi64.dll", null, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if !dll return false;

    nv_query_interface := cast(Nv_Query_Interface_Fn) GetProcAddress(dll, "nvapi_QueryInterface");
    if !nv_query_interface {
        user_message_warning("nvapi: nvapi_QueryInterface missing");
        FreeLibrary(dll); return false;
    }

    nv_init := cast(Nv_Initialize_Fn) nv_query_interface(0x0150E828);
    if !nv_init || nv_init() != 0 {
        user_message_warning("nvapi: NvAPI_Initialize failed");
        FreeLibrary(dll); return false;
    }

    nv_enum_gpus := cast(Nv_Enum_Physical_Gpus_Fn) nv_query_interface(0xE5AC921F);
    gpu_handles: [64] *void;
    gpu_count: u32;
    if !nv_enum_gpus || nv_enum_gpus(*gpu_handles, *gpu_count) != 0 || gpu_count == 0 {
        user_message_warning("nvapi: no NVIDIA GPU enumerated");
        FreeLibrary(dll);
        return false;
    }

    read_fn := cast(Nv_Read_Scanout_Fn) nv_query_interface(0xBCB1C536);
    if !read_fn {
        user_message_warning("nvapi: ReadFromBoundFramebuffer unavailable");
        FreeLibrary(dll); return false;
    }

    nv.dll          = dll;
    nv.read_scanout = read_fn;
    nv.gpu_handle   = gpu_handles[0];

    if !refresh_nv_monitors(nv) {
        user_message_warning("nvapi: display topology query failed");
        FreeLibrary(dll);
        <<nv = Nv_Capture.{};
        return false;
    }

    // scanout call to confirm it works on this hardware
    // sorry peoele on radeon
    test_data: *void;
    test_params: Nv_Read_Scanout_Params;
    test_params.version      = size_of(Nv_Read_Scanout_Params) | (1 << 16);
    test_params.target_id    = nv.monitors[0].target_id;
    test_params.physical_gpu = nv.gpu_handle;
    test_params.data_out     = *test_data;

    status := read_fn(device, *test_params);
    if test_data VirtualFree(test_data, 0, MEM_RELEASE);

    if status != 0 {
        user_message_warning("nvapi: scanout test failed (status %)", status);
        FreeLibrary(dll);
        <<nv = Nv_Capture.{};
        return false;
    }

    nv.is_available = true;
    return true;
}

release_nv_capture :: (nv: *Nv_Capture) {
    if nv.dll FreeLibrary(nv.dll);
    fini(*nv.convert_arena);
    <<nv = Nv_Capture.{};
}

// D3DDDIFMT_A2B10G10R10 (format 31): R[9:0] G[19:10] B[29:20] A[31:30] -> B8G8R8A8
// NOTE(zaddish): Jai does not group `<<` before `|` like C++ does here
// if the shift terms are not wrapped then the channel packing comes out wrong
convert_10bit :: inline (v: u32) -> u32 {
    return (((v >>  2) & 0xFF) << 16)
         | (((v >> 12) & 0xFF) <<  8)
         |  ((v >> 22) & 0xFF)
         |  0xFF000000;
}

// NOTE(zaddish): all monitors return format 31 regardless of actual panel bit depth,
// not sure why, maybe DWM composites at that depth and the driver upscales at scanout?
// if a display is in HDR mode the scanout might be PQ encoded (BT.2100 ST.2084) instead of
// the sRGB ish values i'm assuming here, which would make this conversion look washed out
// no working HDR10 display to test so we can just handle SDR for now
// https://learn.microsoft.com/en-us/windows/win32/direct3darticles/high-dynamic-range
//
// rotation and bit depth are constant for the entire frame, so i can just bake them into the
// loop as comptime params
// the inner body over millions of pixels is then branch free!!
// dont have to redecide the rotation map and the conversion on every pixel
convert_pixels_impl :: (dst: *u32, dst_w: u32, src: *u32, src_w: u32, src_h: u32, $rotation: u32, $is_10bit: bool) {
    for src_y: 0 .. src_h - 1 {
        for src_x: 0 .. src_w - 1 {
            dst_x, dst_y: u32;
            #if rotation == 2 {
                dst_x = src_h - 1 - src_y; dst_y = src_x;
            } else #if rotation == 3 {
                dst_x = src_w - 1 - src_x; dst_y = src_h - 1 - src_y;
            } else #if rotation == 4 {
                dst_x = src_y;             dst_y = src_w - 1 - src_x;
            } else {
                dst_x = src_x;             dst_y = src_y;
            }
            v := src[src_y * src_w + src_x];
            #if is_10bit {
                dst[dst_y * dst_w + dst_x] = convert_10bit(v);
            } else {
                dst[dst_y * dst_w + dst_x] = v;
            }
        }
    }
}

convert_pixels_rotation :: (dst: *u32, dst_w: u32, src: *u32, src_w: u32, src_h: u32, rotation: u32, $is_10bit: bool) {
    if rotation == {
        case 2; convert_pixels_impl(dst, dst_w, src, src_w, src_h, 2, is_10bit);
        case 3; convert_pixels_impl(dst, dst_w, src, src_w, src_h, 3, is_10bit);
        case 4; convert_pixels_impl(dst, dst_w, src, src_w, src_h, 4, is_10bit);
        case;   convert_pixels_impl(dst, dst_w, src, src_w, src_h, 0, is_10bit);
    }
}

convert_pixels :: (dst: *u32, dst_w: u32, src: *u32, src_w: u32, src_h: u32, rotation: u32, is_10bit: bool) {
    if is_10bit  convert_pixels_rotation(dst, dst_w, src, src_w, src_h, rotation, true);
    else         convert_pixels_rotation(dst, dst_w, src, src_w, src_h, rotation, false);
}

nv_capture_all_monitors :: (nv: *Nv_Capture, device: *ID3D11Device) -> bool {
    if !nv.is_available return false;

    any_success := false;
    arena_allocator := Allocator.{proc = flat_pool_allocator_proc, data = *nv.convert_arena};

    for * mon: array_view(nv.monitors, 0, nv.monitor_count) {
        raw_data: *void;
        params: Nv_Read_Scanout_Params;
        params.version      = size_of(Nv_Read_Scanout_Params) | (1 << 16);
        params.target_id    = mon.target_id;
        params.physical_gpu = nv.gpu_handle;
        params.data_out     = *raw_data;

        status := nv.read_scanout(device, *params);
        if status != 0 || !raw_data continue;

        captured_w := params.rect.right  - params.rect.left;
        captured_h := params.rect.bottom - params.rect.top;
        desktop_w  := cast(u32) (mon.bounds.right  - mon.bounds.left);
        desktop_h  := cast(u32) (mon.bounds.bottom - mon.bounds.top);
        is_10bit   := params.format == 31;

        converted := cast(*u32) alloc(size_of(u32) * cast(s64) desktop_w * cast(s64) desktop_h,, arena_allocator);
        if !converted {
            VirtualFree(raw_data, 0, MEM_RELEASE);
            continue;
        }

        convert_pixels(converted, desktop_w, cast(*u32) raw_data, captured_w, captured_h, mon.rotation, is_10bit);
        VirtualFree(raw_data, 0, MEM_RELEASE);

        mon.pixels  = converted;
        mon.pixel_w = desktop_w;
        mon.pixel_h = desktop_h;
        any_success = true;
    }

    return any_success;
}

cache_nv_background :: (r: *Betterss_Renderer, nv: *Nv_Capture) {
    get_cached_texture(r, *r.cached_background, r.width, r.height, .DEFAULT, .SHADER_RESOURCE, 0);
    if !r.cached_background.texture return;

    origin_x := nv.virtual_screen.left;
    origin_y := nv.virtual_screen.top;

    for * mon: array_view(nv.monitors, 0, nv.monitor_count) {
        if !mon.pixels continue;

        box: D3D11_BOX;
        box.left   = cast(u32) (mon.bounds.left - origin_x);
        box.top    = cast(u32) (mon.bounds.top  - origin_y);
        box.right  = box.left + mon.pixel_w;
        box.bottom = box.top  + mon.pixel_h;
        box.back   = 1;

        ID3D11DeviceContext_UpdateSubresource(r.ctx, xx r.cached_background.texture, 0, *box, mon.pixels, mon.pixel_w * 4, 0);
        mon.pixels = null;
    }

    reset(*nv.convert_arena);
}
