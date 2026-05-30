MODE_LABEL_COUNT :: ANNOTATION_MODE_COUNT;

Overlay_Const_Buffer :: struct {
    selection_rect: [4] float;
    dim_factor:     float;
    texel_size:     [2] float;
    rotation:       float;
}

Line_Const_Buffer :: struct {
    screen_size: [2] float;
    line_width:  float;
    padding:     float;
    line_color:  [4] float;
}

Composite_Const_Buffer :: struct {
    uv_scale: [2] float;
    padding:  [2] float;
}

Line_Vertex :: struct {
    position: [2] float;
}

UI_Vertex :: struct {
    position: [2] float;
    color:    [4] float;
}

UI_Const_Buffer :: struct {
    screen_size: [2] float;
    padding:     [2] float;
}

Cached_Texture :: struct {
    texture: *ID3D11Texture2D;
    rtv:     *ID3D11RenderTargetView;
    srv:     *ID3D11ShaderResourceView;
    width:   u32;
    height:  u32;
}

Mode_Label :: struct {
    texture: *ID3D11Texture2D;
    srv:     *ID3D11ShaderResourceView;
    width:   s32;
    height:  s32;
}

// every texture in here is born when a capture starts and dies when it ends, the
// same lifetime as capture_arena.  grouping them gives one teardown point
// (release_session_textures) that mirrors reset(arena), instead of a release call
// per field to remember to keep in sync
// i feel like this is better, but we'll have to see once i need to touch it again
Session_Textures :: struct {
    cached_staging:    Cached_Texture;
    cached_render:     Cached_Texture;
    cached_background: Cached_Texture;
    highlight_texture: Cached_Texture;
    scene_copy:        Cached_Texture;
}

Betterss_Renderer :: struct {
    device:        *ID3D11Device;
    ctx:           *ID3D11DeviceContext;
    swap_chain:    *IDXGISwapChain1;
    render_target: *ID3D11RenderTargetView;
    // set once at the end of a full, checked bring up. when true, every device
    // lifetime shader/buffer/state/sampler below is guaranteed non null, so the
    // render path trusts them instead of null checking each handle every use
    ready:         bool;

    vertex_shader:   *ID3D11VertexShader;
    overlay_shader:  *ID3D11PixelShader;
    constant_buffer: *ID3D11Buffer;
    sampler:         *ID3D11SamplerState;

    width:  u32;
    height: u32;

    line_vertex_shader: *ID3D11VertexShader;
    line_pixel_shader:  *ID3D11PixelShader;
    line_const_buffer:  *ID3D11Buffer;
    line_vertex_buffer: *ID3D11Buffer;
    line_input_layout:  *ID3D11InputLayout;
    line_vertex_buffer_capacity: u32;

    using session: Session_Textures;

    no_cull_state: *ID3D11RasterizerState;

    composite_shader:         *ID3D11PixelShader;
    composite_constant_buffer: *ID3D11Buffer;

    label_cache: Label_Cache;
    alpha_blend: *ID3D11BlendState;

    sdf_pixel_shader:   *ID3D11PixelShader;
    sdf_point_buffer:   *ID3D11Buffer;
    sdf_point_srv:      *ID3D11ShaderResourceView;
    sdf_point_capacity: u32;

    ui_vertex_shader:  *ID3D11VertexShader;
    ui_pixel_shader:   *ID3D11PixelShader;
    ui_input_layout:   *ID3D11InputLayout;
    ui_vertex_buffer:  *ID3D11Buffer;
    ui_const_buffer:   *ID3D11Buffer;
    ui_vertex_buffer_capacity: u32;
}

#scope_file
compile_shader :: (path: string, entry: string, target: string) -> [] u8 {
    source, ok := read_entire_file(path);
    assert(ok, "Failed to read shader file: %", path);

    flags := D3DCOMPILE.OPTIMIZATION_LEVEL3 | D3DCOMPILE.WARNINGS_ARE_ERRORS;
    defines: [] string;
    bytecode, errors, hr := D3DCompile(source, path, defines, null, entry, target, xx flags, 0);
    if FAILED(hr) assert(false, "Shader compile failed [%]: %", path, errors);

    result: [] u8;
    result.data  = bytecode.data;
    result.count = bytecode.count;
    return result;
}
#scope_export

OVERLAY_VS      :: #run compile_shader(tprint("%shaders/overlay.hlsl",   #filepath), "VSMain", "vs_5_0");
OVERLAY_PS      :: #run compile_shader(tprint("%shaders/overlay.hlsl",   #filepath), "PSMain", "ps_5_0");
LINE_VS         :: #run compile_shader(tprint("%shaders/line.hlsl",      #filepath), "VSMain", "vs_5_0");
LINE_PS         :: #run compile_shader(tprint("%shaders/line.hlsl",      #filepath), "PSMain", "ps_5_0");
COMPOSITE_PS    :: #run compile_shader(tprint("%shaders/composite.hlsl", #filepath), "PSMain", "ps_5_0");
UI_VS           :: #run compile_shader(tprint("%shaders/ui.hlsl",        #filepath), "VSMain", "vs_5_0");
UI_PS           :: #run compile_shader(tprint("%shaders/ui.hlsl",        #filepath), "PSMain", "ps_5_0");
SDF_PS          :: #run compile_shader(tprint("%shaders/line_sdf.hlsl",  #filepath), "PSMain", "ps_5_0");

// baked GDI / HLSL strings
// see bake_wide / bake_cstr in main
W_SEGOE_UI   :: #run bake_wide("Segoe UI");
CSTR_POSITION :: #run bake_cstr("POSITION");
CSTR_COLOR    :: #run bake_cstr("COLOR");
MODE_LABELS : [MODE_LABEL_COUNT] string : .[
    "LINE",
    "HIGHLIGHT",
    "CENSOR",
];

create_dynamic_buffer :: (device: *ID3D11Device, out: **ID3D11Buffer, byte_width: u32, bind_flags: D3D11_BIND_FLAG) {
    desc: D3D11_BUFFER_DESC;
    desc.ByteWidth      = byte_width;
    desc.Usage          = .DYNAMIC;
    desc.BindFlags      = bind_flags;
    desc.CPUAccessFlags = .WRITE;
    ID3D11Device_CreateBuffer(device, *desc, null, out);
}

update_constant_buffer :: (ctx: *ID3D11DeviceContext, buffer: *ID3D11Buffer, data: *void, size: s64) {
    mapped: D3D11_MAPPED_SUBRESOURCE;
    if SUCCEEDED(ID3D11DeviceContext_Map(ctx, xx buffer, 0, .WRITE_DISCARD, 0, *mapped)) {
        memcpy(mapped.pData, data, size);
        ID3D11DeviceContext_Unmap(ctx, xx buffer, 0);
    }
}

ceil_pow2 :: (v: u32) -> u32 {
    x := v - 1;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    return x + 1;
}

renderer_is_valid :: (r: *Betterss_Renderer) -> bool {
    return r.device != null && r.swap_chain != null && r.render_target != null;
}

acquire_dxgi_factory :: (device: *ID3D11Device) -> *IDXGIFactory2 {
    if !device return null;

    dxgi_device: *IDXGIDevice;
    if FAILED(IUnknown_QueryInterface(device, *uid(IDXGIDevice_UUID), xx *dxgi_device)) return null;
    defer safe_release(dxgi_device);

    adapter: *IDXGIAdapter;
    if FAILED(IDXGIDevice_GetAdapter(dxgi_device, *adapter)) return null;
    defer safe_release(adapter);

    factory: *IDXGIFactory2;
    IDXGIObject_GetParent(adapter, *uid(IDXGIFactory2_UUID), xx *factory);
    return factory;
}

acquire_swap_chain :: (device: *ID3D11Device, window: HWND) -> *IDXGISwapChain1 {
    if !device return null;

    factory := acquire_dxgi_factory(device);
    if !factory return null;
    defer safe_release(factory);

    desc: DXGI_SWAP_CHAIN_DESC1;
    desc.Format           = .B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage      = .RENDER_TARGET_OUTPUT;
    desc.BufferCount      = 2;
    desc.SwapEffect       = .FLIP_DISCARD;
    desc.Scaling          = .NONE;
    desc.AlphaMode        = .IGNORE;

    result: *IDXGISwapChain1;
    if SUCCEEDED(IDXGIFactory2_CreateSwapChainForHwnd(factory, xx device, window, *desc, null, null, *result)) {
        IDXGIFactory_MakeWindowAssociation(xx factory, window, xx (DXGI_MWA.NO_ALT_ENTER | DXGI_MWA.NO_WINDOW_CHANGES));
    }
    return result;
}

release_cached_texture :: (c: *Cached_Texture) {
    safe_release_and_reset(*c.rtv);
    safe_release_and_reset(*c.srv);
    safe_release_and_reset(*c.texture);
    c.width  = 0;
    c.height = 0;
}

// teardown for the whole session texture group by walking Session_Textures at
// comptime, so a texture added to that struct is released here automatically with
// no release call to remember
// this is so cool!
generate_session_release_body :: (info: *Type_Info_Struct) -> string {
    b: String_Builder;
    for member: info.members {
        print_to_builder(*b, "release_cached_texture(*r.session.%);\n", member.name);
    }
    return builder_to_string(*b);
}

release_session_textures :: (r: *Betterss_Renderer) {
    #insert #run generate_session_release_body(type_info(Session_Textures));
}

release_render_target :: (r: *Betterss_Renderer) {
    safe_release_and_reset(*r.render_target);
}

renderer_resize :: (r: *Betterss_Renderer, w: u32, h: u32) {
    if w == 0 || h == 0 return;
    if w == r.width && h == r.height return;

    ID3D11DeviceContext_ClearState(r.ctx);
    release_render_target(r);
    ID3D11DeviceContext_Flush(r.ctx);

    hr := IDXGISwapChain_ResizeBuffers(xx r.swap_chain, 0, w, h, .UNKNOWN, 0);
    if FAILED(hr) { release_renderer(r); return; }

    back_buffer: *ID3D11Texture2D;
    hr = IDXGISwapChain_GetBuffer(xx r.swap_chain, 0, *uid(ID3D11Texture2D_UUID), xx *back_buffer);
    if FAILED(hr) { release_renderer(r); return; }
    defer safe_release(back_buffer);

    hr = ID3D11Device_CreateRenderTargetView(r.device, xx back_buffer, null, *r.render_target);
    if FAILED(hr) { release_renderer(r); return; }

    r.width  = w;
    r.height = h;
}

release_renderer :: (r: *Betterss_Renderer) {
    release_session_textures(r);

    label_cache_release(*r.label_cache);

    com_release_all(r);

    <<r = Betterss_Renderer.{};
}

acquire_renderer :: (window: HWND) -> Betterss_Renderer {
    result: Betterss_Renderer;

    flags := D3D11_CREATE_DEVICE_FLAG.BGRA_SUPPORT | .SINGLETHREADED;
    levels : [1] D3D_FEATURE_LEVEL = .[._11_0];

    hr := D3D11CreateDevice(null, .HARDWARE, null, flags, levels.data, cast(u32) levels.count, D3D11_SDK_VERSION, *result.device, null, *result.ctx);
    if FAILED(hr) {
        hr = D3D11CreateDevice(null, .WARP, null, flags, levels.data, cast(u32) levels.count, D3D11_SDK_VERSION, *result.device, null, *result.ctx);
    }

    if SUCCEEDED(hr) {
        result.swap_chain = acquire_swap_chain(result.device, window);
        if result.swap_chain {
            create_dynamic_buffer(result.device, *result.constant_buffer, size_of(Overlay_Const_Buffer), .CONSTANT_BUFFER);

            sampler_desc: D3D11_SAMPLER_DESC;
            sampler_desc.Filter   = .MIN_MAG_MIP_LINEAR;
            sampler_desc.AddressU = .CLAMP;
            sampler_desc.AddressV = .CLAMP;
            sampler_desc.AddressW = .CLAMP;
            ID3D11Device_CreateSamplerState(result.device, *sampler_desc, *result.sampler);

            client_rect: RECT;
            GetClientRect(window, *client_rect);
            renderer_resize(*result, cast(u32) client_rect.right, cast(u32) client_rect.bottom);
        }
    }

    if !renderer_is_valid(*result) release_renderer(*result);
    return result;
}

renderer_present :: (r: *Betterss_Renderer) -> bool {
    hr := IDXGISwapChain_Present(xx r.swap_chain, 0, 0);
    if hr == xx DXGI_ERROR_DEVICE_RESET || hr == xx DXGI_ERROR_DEVICE_REMOVED {
        #if !IS_RELEASE OutputDebugStringA("D3D11: device removed during Present\n");
        release_renderer(r);
        return false;
    }
    return true;
}

initialize_line_renderer :: (r: *Betterss_Renderer) -> bool {
    ID3D11Device_CreateVertexShader(r.device, LINE_VS.data, xx LINE_VS.count, null, *r.line_vertex_shader);
    ID3D11Device_CreatePixelShader (r.device, LINE_PS.data, xx LINE_PS.count, null, *r.line_pixel_shader);
    ID3D11Device_CreatePixelShader (r.device, COMPOSITE_PS.data, xx COMPOSITE_PS.count, null, *r.composite_shader);

    input_desc: [1] D3D11_INPUT_ELEMENT_DESC;
    input_desc[0].SemanticName         = CSTR_POSITION.data;
    input_desc[0].SemanticIndex        = 0;
    input_desc[0].Format               = .R32G32_FLOAT;
    input_desc[0].InputSlot            = 0;
    input_desc[0].AlignedByteOffset    = 0;
    input_desc[0].InputSlotClass       = .VERTEX_DATA;
    input_desc[0].InstanceDataStepRate = 0;

    ID3D11Device_CreateInputLayout(r.device, input_desc.data, input_desc.count, LINE_VS.data, xx LINE_VS.count, *r.line_input_layout);

    create_dynamic_buffer(r.device, *r.line_const_buffer,        size_of(Line_Const_Buffer),      .CONSTANT_BUFFER);
    create_dynamic_buffer(r.device, *r.composite_constant_buffer, size_of(Composite_Const_Buffer), .CONSTANT_BUFFER);

    r.line_vertex_buffer_capacity = 4096;
    create_dynamic_buffer(r.device, *r.line_vertex_buffer, r.line_vertex_buffer_capacity * size_of(Line_Vertex), .VERTEX_BUFFER);

    ID3D11Device_CreatePixelShader(r.device, SDF_PS.data, xx SDF_PS.count, null, *r.sdf_pixel_shader);

    raster_desc: D3D11_RASTERIZER_DESC;
    raster_desc.FillMode        = .SOLID;
    raster_desc.CullMode        = .NONE;
    raster_desc.DepthClipEnable = xx BOOL.TRUE;
    ID3D11Device_CreateRasterizerState(r.device, *raster_desc, *r.no_cull_state);

    return r.line_vertex_shader != null && r.line_pixel_shader != null && r.composite_shader != null
        && r.line_input_layout != null && r.line_const_buffer != null && r.composite_constant_buffer != null
        && r.line_vertex_buffer != null && r.sdf_pixel_shader != null && r.no_cull_state != null;
}

initialize_ui_renderer :: (r: *Betterss_Renderer) -> bool {
    ID3D11Device_CreateVertexShader(r.device, UI_VS.data, xx UI_VS.count, null, *r.ui_vertex_shader);
    ID3D11Device_CreatePixelShader (r.device, UI_PS.data, xx UI_PS.count, null, *r.ui_pixel_shader);

    input_desc: [2] D3D11_INPUT_ELEMENT_DESC;
    input_desc[0].SemanticName         = CSTR_POSITION.data;
    input_desc[0].Format               = .R32G32_FLOAT;
    input_desc[0].AlignedByteOffset    = 0;
    input_desc[0].InputSlotClass       = .VERTEX_DATA;
    input_desc[1].SemanticName         = CSTR_COLOR.data;
    input_desc[1].Format               = .R32G32B32A32_FLOAT;
    input_desc[1].AlignedByteOffset    = 8;
    input_desc[1].InputSlotClass       = .VERTEX_DATA;

    ID3D11Device_CreateInputLayout(r.device, input_desc.data, input_desc.count, UI_VS.data, xx UI_VS.count, *r.ui_input_layout);

    create_dynamic_buffer(r.device, *r.ui_const_buffer, size_of(UI_Const_Buffer), .CONSTANT_BUFFER);

    r.ui_vertex_buffer_capacity = 8192;
    create_dynamic_buffer(r.device, *r.ui_vertex_buffer, r.ui_vertex_buffer_capacity * size_of(UI_Vertex), .VERTEX_BUFFER);

    return r.ui_vertex_shader != null && r.ui_pixel_shader != null && r.ui_input_layout != null
        && r.ui_const_buffer != null && r.ui_vertex_buffer != null;
}

render_ui_geometry :: (r: *Betterss_Renderer, vertices: *UI_Vertex, vertex_count: s32) {
    if vertex_count <= 0 return;

    if cast(u32) vertex_count > r.ui_vertex_buffer_capacity {
        safe_release_and_reset(*r.ui_vertex_buffer);
        r.ui_vertex_buffer_capacity = ceil_pow2(cast(u32) vertex_count * 2);
        create_dynamic_buffer(r.device, *r.ui_vertex_buffer, r.ui_vertex_buffer_capacity * size_of(UI_Vertex), .VERTEX_BUFFER);
    }
    if !r.ui_vertex_buffer return;

    mapped: D3D11_MAPPED_SUBRESOURCE;
    if !SUCCEEDED(ID3D11DeviceContext_Map(r.ctx, xx r.ui_vertex_buffer, 0, .WRITE_DISCARD, 0, *mapped)) return;
    memcpy(mapped.pData, vertices, cast(s64) vertex_count * size_of(UI_Vertex));
    ID3D11DeviceContext_Unmap(r.ctx, xx r.ui_vertex_buffer, 0);

    constants: UI_Const_Buffer;
    constants.screen_size = .[cast(float) r.width, cast(float) r.height];
    update_constant_buffer(r.ctx, r.ui_const_buffer, *constants, size_of(UI_Const_Buffer));

    ID3D11DeviceContext_OMSetRenderTargets(r.ctx, 1, *r.render_target, null);

    viewport: D3D11_VIEWPORT;
    viewport.Width    = cast(float) r.width;
    viewport.Height   = cast(float) r.height;
    viewport.MaxDepth = 1.0;
    ID3D11DeviceContext_RSSetViewports(r.ctx, 1, *viewport);

    stride : u32 = size_of(UI_Vertex);
    offset : u32 = 0;
    ID3D11DeviceContext_IASetVertexBuffers    (r.ctx, 0, 1, *r.ui_vertex_buffer, *stride, *offset);
    ID3D11DeviceContext_IASetInputLayout      (r.ctx, r.ui_input_layout);
    ID3D11DeviceContext_IASetPrimitiveTopology(r.ctx, .TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader           (r.ctx, r.ui_vertex_shader, null, 0);
    ID3D11DeviceContext_PSSetShader           (r.ctx, r.ui_pixel_shader, null, 0);
    ID3D11DeviceContext_VSSetConstantBuffers  (r.ctx, 0, 1, *r.ui_const_buffer);
    ID3D11DeviceContext_RSSetState            (r.ctx, r.no_cull_state);

    blend_factor: [4] float = .[0, 0, 0, 0];
    ID3D11DeviceContext_OMSetBlendState(r.ctx, r.alpha_blend, *blend_factor, 0xFFFFFFFF);
    ID3D11DeviceContext_Draw(r.ctx, cast(u32) vertex_count, 0);

    null_blend: *ID3D11BlendState;
    ID3D11DeviceContext_OMSetBlendState(r.ctx, null_blend, *blend_factor, 0xFFFFFFFF);
}

get_cached_texture :: (r: *Betterss_Renderer, cache: *Cached_Texture, w: u32, h: u32, usage: D3D11_USAGE, bind_flags: D3D11_BIND_FLAG, cpu_access: D3D11_CPU_ACCESS_FLAG) -> *ID3D11Texture2D {
    if cache.texture && cache.width >= w && cache.height >= h return cache.texture;

    release_cached_texture(cache);

    desc: D3D11_TEXTURE2D_DESC;
    desc.Width            = w;
    desc.Height           = h;
    desc.MipLevels        = 1;
    desc.ArraySize        = 1;
    desc.Format           = .B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage            = usage;
    desc.BindFlags        = bind_flags;
    desc.CPUAccessFlags   = cpu_access;

    ID3D11Device_CreateTexture2D(r.device, *desc, null, *cache.texture);

    if cache.texture {
        if bind_flags & .RENDER_TARGET {
            ID3D11Device_CreateRenderTargetView(r.device, xx cache.texture, null, *cache.rtv);
        }
        if bind_flags & .SHADER_RESOURCE {
            ID3D11Device_CreateShaderResourceView(r.device, xx cache.texture, null, *cache.srv);
        }
        cache.width  = w;
        cache.height = h;
    }

    return cache.texture;
}

emit_rect_quad :: (vertices: *Line_Vertex, vi: *s32, left: float, top: float, right: float, bottom: float) {
    i := <<vi;
    vertices[i].position = .[left,  top];    i += 1;
    vertices[i].position = .[right, top];    i += 1;
    vertices[i].position = .[left,  bottom]; i += 1;
    vertices[i].position = .[right, top];    i += 1;
    vertices[i].position = .[right, bottom]; i += 1;
    vertices[i].position = .[left,  bottom]; i += 1;
    <<vi = i;
}

pt_x :: inline (entry: *Annotation_Entry, j: s32, ox: s32) -> float { return cast(float) (entry.points[j].x + ox); }
pt_y :: inline (entry: *Annotation_Entry, j: s32, oy: s32) -> float { return cast(float) (entry.points[j].y + oy); }

emit_strip :: (vertices: *Line_Vertex, vi: *s32, entry: *Annotation_Entry, offset_x: s32, offset_y: s32, half_w: float) {
    count := entry.point_count;
    if count < 2 return;

    prev_lx, prev_ly, prev_rx, prev_ry: float;

    for j: 0 .. count - 1 {
        px := pt_x(entry, j, offset_x);
        py := pt_y(entry, j, offset_y);

        nx: float = 0;
        ny: float = 0;
        if j > 0 {
            dx := px - pt_x(entry, j-1, offset_x);
            dy := py - pt_y(entry, j-1, offset_y);
            d := sqrt(dx*dx + dy*dy);
            if d > 0.0001 { nx += -dy/d; ny += dx/d; }
        }
        if j < count - 1 {
            dx := pt_x(entry, j+1, offset_x) - px;
            dy := pt_y(entry, j+1, offset_y) - py;
            d := sqrt(dx*dx + dy*dy);
            if d > 0.0001 { nx += -dy/d; ny += dx/d; }
        }
        nd := sqrt(nx*nx + ny*ny);
        if nd < 0.0001 continue;
        nx /= nd; ny /= nd;

        lx := px + nx * half_w;
        ly := py + ny * half_w;
        rx := px - nx * half_w;
        ry := py - ny * half_w;

        if j > 0 {
            i := <<vi;
            vertices[i].position = .[prev_lx, prev_ly]; i += 1;
            vertices[i].position = .[prev_rx, prev_ry]; i += 1;
            vertices[i].position = .[lx, ly];           i += 1;
            vertices[i].position = .[lx, ly];           i += 1;
            vertices[i].position = .[prev_rx, prev_ry]; i += 1;
            vertices[i].position = .[rx, ry];           i += 1;
            <<vi = i;
        }

        prev_lx = lx; prev_ly = ly;
        prev_rx = rx; prev_ry = ry;
    }
}

emit_line_segments :: (vertices: *Line_Vertex, vi: *s32, entry: *Annotation_Entry, offset_x: s32, offset_y: s32, line_width: float) {
    emit_strip(vertices, vi, entry, offset_x, offset_y, line_width * 0.5);
}

emit_highlight_segments :: (vertices: *Line_Vertex, vi: *s32, entry: *Annotation_Entry, offset_x: s32, offset_y: s32, half_height: float) {
    emit_strip(vertices, vi, entry, offset_x, offset_y, half_height);
}

update_line_constants :: (r: *Betterss_Renderer, target_w: s32, target_h: s32, cr: float, cg: float, cb: float, ca: float) {
    constants: Line_Const_Buffer;
    constants.screen_size = .[cast(float) target_w, cast(float) target_h];
    constants.line_color  = .[cr, cg, cb, ca];
    update_constant_buffer(r.ctx, r.line_const_buffer, *constants, size_of(Line_Const_Buffer));
}

Annotation_Draw :: struct {
    start_vertex: s32;
    vertex_count: s32;
    color:        Vector3;
}

MAX_DRAW_BATCHES :: 256;

render_annotations :: (r: *Betterss_Renderer, sel: *Selection_State, offset_x: s32, offset_y: s32, target_w: s32, target_h: s32) {
    if !sel || sel.annotation_count == 0 return;

    highlight_half_h_default : float = 20.0;

    annotations: [] Annotation_Entry;
    annotations.data  = sel.annotations;
    annotations.count = sel.annotation_count;

    max_vertices: s32 = 0;
    has_sdf_lines := false;
    for * entry: annotations {
        if #complete entry.type == {
            case .LINE;       if entry.point_count > 0 has_sdf_lines = true;
            case .HIGHLIGHT;  if entry.point_count > 1 max_vertices += entry.point_count * 8 * 6;
            case .RECT;       max_vertices += 6;
        }
    }
    if max_vertices == 0 && !has_sdf_lines return;

    vertices: *Line_Vertex;
    vertex_index: s32 = 0;
    mapped: D3D11_MAPPED_SUBRESOURCE;

    if max_vertices > 0 {
        if max_vertices > cast(s32) r.line_vertex_buffer_capacity {
            safe_release_and_reset(*r.line_vertex_buffer);
            r.line_vertex_buffer_capacity = ceil_pow2(cast(u32) max_vertices * 2);
            create_dynamic_buffer(r.device, *r.line_vertex_buffer, r.line_vertex_buffer_capacity * size_of(Line_Vertex), .VERTEX_BUFFER);
        }
        if !r.line_vertex_buffer return;
        if !SUCCEEDED(ID3D11DeviceContext_Map(r.ctx, xx r.line_vertex_buffer, 0, .WRITE_DISCARD, 0, *mapped)) return;
        vertices = cast(*Line_Vertex) mapped.pData;
    }

    opaque_draws:    [MAX_DRAW_BATCHES] Annotation_Draw;
    opaque_draw_count: s32 = 0;
    highlight_draws: [MAX_DRAW_BATCHES] Annotation_Draw;
    highlight_draw_count: s32 = 0;

    // rects + highlights go into the vertex buffer
    for * entry: annotations {
        if entry.type == .RECT {
            start := vertex_index;
            left   := cast(float) (entry.x0 + offset_x);
            top    := cast(float) (entry.y0 + offset_y);
            right  := cast(float) (entry.x1 + offset_x);
            bottom := cast(float) (entry.y1 + offset_y);
            if left > right  { t := left; left = right;  right = t; }
            if top  > bottom { t := top;  top  = bottom; bottom = t; }
            emit_rect_quad(vertices, *vertex_index, left, top, right, bottom);
            if vertex_index > start && opaque_draw_count < MAX_DRAW_BATCHES {
                opaque_draws[opaque_draw_count] = .{start, vertex_index - start, entry.color};
                opaque_draw_count += 1;
            }
        } else if entry.type == .HIGHLIGHT && entry.point_count > 1 {
            start := vertex_index;
            half_h := ifx entry.line_width > 0 then entry.line_width else highlight_half_h_default;
            emit_highlight_segments(vertices, *vertex_index, entry, offset_x, offset_y, half_h);
            if vertex_index > start && highlight_draw_count < MAX_DRAW_BATCHES {
                highlight_draws[highlight_draw_count] = .{start, vertex_index - start, entry.color};
                highlight_draw_count += 1;
            }
        }
    }

    if vertices ID3D11DeviceContext_Unmap(r.ctx, xx r.line_vertex_buffer, 0);

    // rect draws via the old line shader
    stride : u32 = size_of(Line_Vertex);
    buf_offset : u32 = 0;
    ID3D11DeviceContext_IASetVertexBuffers(r.ctx, 0, 1, *r.line_vertex_buffer, *stride, *buf_offset);
    ID3D11DeviceContext_IASetInputLayout(r.ctx, r.line_input_layout);
    ID3D11DeviceContext_IASetPrimitiveTopology(r.ctx, .TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(r.ctx, r.line_vertex_shader, null, 0);
    ID3D11DeviceContext_PSSetShader(r.ctx, r.line_pixel_shader,  null, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(r.ctx, 0, 1, *r.line_const_buffer);
    ID3D11DeviceContext_PSSetConstantBuffers(r.ctx, 0, 1, *r.line_const_buffer);

    ID3D11DeviceContext_RSSetState(r.ctx, r.no_cull_state);

    for i: 0 .. opaque_draw_count - 1 {
        d := opaque_draws[i];
        update_line_constants(r, target_w, target_h, d.color.x, d.color.y, d.color.z, 1.0);
        ID3D11DeviceContext_Draw(r.ctx, cast(u32) d.vertex_count, cast(u32) d.start_vertex);
    }

    if highlight_draw_count > 0 {
        prev_rtv: *ID3D11RenderTargetView;
        ID3D11DeviceContext_OMGetRenderTargets(r.ctx, 1, *prev_rtv, null);

        get_cached_texture(r, *r.highlight_texture, cast(u32) target_w, cast(u32) target_h, .DEFAULT, .RENDER_TARGET | .SHADER_RESOURCE, 0);

        if r.highlight_texture.rtv && r.highlight_texture.srv {
            clear_color : [4] float : .[1.0, 1.0, 1.0, 1.0];
            ID3D11DeviceContext_ClearRenderTargetView(r.ctx, r.highlight_texture.rtv, *clear_color);
            ID3D11DeviceContext_OMSetRenderTargets(r.ctx, 1, *r.highlight_texture.rtv, null);

            for i: 0 .. highlight_draw_count - 1 {
                d := highlight_draws[i];
                update_line_constants(r, target_w, target_h, d.color.x, d.color.y, d.color.z, 1.0);
                ID3D11DeviceContext_Draw(r.ctx, cast(u32) d.vertex_count, cast(u32) d.start_vertex);
            }

            ID3D11DeviceContext_OMSetRenderTargets(r.ctx, 1, *prev_rtv, null);

            get_cached_texture(r, *r.scene_copy, cast(u32) target_w, cast(u32) target_h, .DEFAULT, .SHADER_RESOURCE, 0);

            if r.scene_copy.texture && r.scene_copy.srv {
                rt_resource: *ID3D11Resource;
                ID3D11View_GetResource(xx prev_rtv, *rt_resource);
                if rt_resource {
                    // copy current RT so the composite shader can read the scene
                    copy_box: D3D11_BOX;
                    copy_box.right  = cast(u32) target_w;
                    copy_box.bottom = cast(u32) target_h;
                    copy_box.back   = 1;
                    ID3D11DeviceContext_CopySubresourceRegion(r.ctx, xx r.scene_copy.texture, 0, 0, 0, 0, rt_resource, 0, *copy_box);
                    safe_release(rt_resource);
                }

                comp_constants: Composite_Const_Buffer;
                comp_constants.uv_scale = .[
                    cast(float) target_w / cast(float) r.highlight_texture.width,
                    cast(float) target_h / cast(float) r.highlight_texture.height,
                ];
                update_constant_buffer(r.ctx, r.composite_constant_buffer, *comp_constants, size_of(Composite_Const_Buffer));

                ID3D11DeviceContext_IASetInputLayout(r.ctx, null);
                ID3D11DeviceContext_VSSetShader(r.ctx, r.vertex_shader, null, 0);
                ID3D11DeviceContext_PSSetShader(r.ctx, r.composite_shader, null, 0);
                srvs : [2] *ID3D11ShaderResourceView = .[r.scene_copy.srv, r.highlight_texture.srv];
                ID3D11DeviceContext_PSSetShaderResources(r.ctx, 0, 2, srvs.data);
                ID3D11DeviceContext_PSSetSamplers        (r.ctx, 0, 1, *r.sampler);
                ID3D11DeviceContext_PSSetConstantBuffers (r.ctx, 0, 1, *r.composite_constant_buffer);

                ID3D11DeviceContext_Draw(r.ctx, 3, 0);

                null_srvs : [2] *ID3D11ShaderResourceView;
                ID3D11DeviceContext_PSSetShaderResources(r.ctx, 0, 2, null_srvs.data);
            }
        }

        safe_release(prev_rtv);
    }

    ID3D11DeviceContext_RSSetState(r.ctx, null);

    // SDF lines
    if has_sdf_lines {
        sdf_stride : u32 = size_of(Line_Vertex);
        sdf_offset : u32 = 0;
        ID3D11DeviceContext_IASetVertexBuffers(r.ctx, 0, 1, *r.line_vertex_buffer, *sdf_stride, *sdf_offset);
        ID3D11DeviceContext_IASetInputLayout(r.ctx, r.line_input_layout);
        ID3D11DeviceContext_IASetPrimitiveTopology(r.ctx, .TRIANGLELIST);
        ID3D11DeviceContext_VSSetShader(r.ctx, r.line_vertex_shader, null, 0);
        ID3D11DeviceContext_PSSetShader(r.ctx, r.sdf_pixel_shader, null, 0);
        ID3D11DeviceContext_VSSetConstantBuffers(r.ctx, 0, 1, *r.line_const_buffer);
        ID3D11DeviceContext_PSSetConstantBuffers(r.ctx, 0, 1, *r.line_const_buffer);
        ID3D11DeviceContext_RSSetState(r.ctx, r.no_cull_state);
        blend_factor: [4] float;
        ID3D11DeviceContext_OMSetBlendState(r.ctx, r.alpha_blend, *blend_factor, 0xFFFFFFFF);

        for * entry: annotations {
            if entry.type == .LINE && entry.point_count > 0 {
                sdf_draw(r, entry.points.data, entry.point_count, offset_x, offset_y,
                         entry.line_width * 0.5, entry.color, 1.0, target_w, target_h);
            }
        }

        ID3D11DeviceContext_OMSetBlendState(r.ctx, null, *blend_factor, 0xFFFFFFFF);
        ID3D11DeviceContext_RSSetState(r.ctx, null);
        null_srv: *ID3D11ShaderResourceView;
        ID3D11DeviceContext_PSSetShaderResources(r.ctx, 0, 1, *null_srv);
    }
}

bake_mode_label :: (device: *ID3D11Device, text: *u16, font_height: s32) -> Mode_Label {
    result: Mode_Label;
    if !device return result;

    dc := CreateCompatibleDC(null);
    if !dc return result;
    defer DeleteDC(dc);

    font := CreateFontW(-font_height, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0,
                        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                        DEFAULT_PITCH, W_SEGOE_UI.data);
    old_font := SelectObject(dc, font);

    len: s32 = 0;
    while text[len] != 0 len += 1;

    text_size: SIZE;
    GetTextExtentPoint32W(dc, text, len, *text_size);

    tex_w := text_size.cx;
    tex_h := text_size.cy;
    if tex_w <= 0 || tex_h <= 0 {
        SelectObject(dc, old_font);
        DeleteObject(font);
        return result;
    }

    bmi: BITMAPINFO;
    bmi.bmiHeader.biSize        = size_of(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth       = tex_w;
    bmi.bmiHeader.biHeight      = -tex_h;
    bmi.bmiHeader.biPlanes      = 1;
    bmi.bmiHeader.biBitCount    = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    bits: *u32;
    bitmap := CreateDIBSection(dc, *bmi, DIB_RGB_COLORS, xx *bits, null, 0);
    if !bitmap || !bits {
        SelectObject(dc, old_font);
        DeleteObject(font);
        return result;
    }

    old_bitmap := SelectObject(dc, bitmap);
    SetTextColor(dc, 0x00FFFFFF); // RGB(255,255,255)
    SetBkMode(dc, TRANSPARENT);

    draw_rect := RECT.{0, 0, tex_w, tex_h};
    DrawTextW(dc, text, len, *draw_rect, DT_LEFT | DT_TOP | DT_NOCLIP);
    GdiFlush();

    // bleach subpixel fringes; DIB alpha is 0 so without this the blend goes additive
    // and the blue fringe shows through also `cast(u32) a << 24` is
    // parsed as `cast(u32) (a << 24)`; a is u8 and jai doesmt promote before shift,
    // so you have to widen to u32 first
    total := tex_w * tex_h;
    for i: 0 .. total - 1 {
        pixel := bits[i];
        c0 : u8 = cast(u8) (pixel         & 0xFF);
        c1 : u8 = cast(u8) ((pixel >>  8) & 0xFF);
        c2 : u8 = cast(u8) ((pixel >> 16) & 0xFF);
        a  : u8 = ifx c0 > c1 then (ifx c0 > c2 then c0 else c2) else (ifx c1 > c2 then c1 else c2);
        ua : u32 = a;
        bits[i] = (ua << 24) | (ua << 16) | (ua << 8) | ua;
    }

    tex_desc: D3D11_TEXTURE2D_DESC;
    tex_desc.Width            = cast(u32) tex_w;
    tex_desc.Height           = cast(u32) tex_h;
    tex_desc.MipLevels        = 1;
    tex_desc.ArraySize        = 1;
    tex_desc.Format           = .B8G8R8A8_UNORM;
    tex_desc.SampleDesc.Count = 1;
    tex_desc.Usage            = .IMMUTABLE;
    tex_desc.BindFlags        = .SHADER_RESOURCE;

    init_data: D3D11_SUBRESOURCE_DATA;
    init_data.pSysMem     = bits;
    init_data.SysMemPitch = cast(u32) (tex_w * 4);

    ID3D11Device_CreateTexture2D(device, *tex_desc, *init_data, *result.texture);
    if result.texture {
        ID3D11Device_CreateShaderResourceView(device, xx result.texture, null, *result.srv);
        result.width  = tex_w;
        result.height = tex_h;
    }

    SelectObject(dc, old_bitmap);
    SelectObject(dc, old_font);
    DeleteObject(bitmap);
    DeleteObject(font);
    return result;
}

sdf_draw :: (r: *Betterss_Renderer, points: *Line_Point, count: s32, offset_x: s32, offset_y: s32, radius: float, color: Vector3, alpha: float, screen_w: s32, screen_h: s32) {
    if count < 1 return;

    if cast(u32) count > r.sdf_point_capacity {
        safe_release_and_reset(*r.sdf_point_srv);
        safe_release_and_reset(*r.sdf_point_buffer);
        r.sdf_point_capacity = ceil_pow2(max(cast(u32) count, 256));
        desc: D3D11_BUFFER_DESC;
        desc.ByteWidth           = r.sdf_point_capacity * 8;
        desc.Usage               = .DYNAMIC;
        desc.BindFlags           = .SHADER_RESOURCE;
        desc.CPUAccessFlags      = .WRITE;
        desc.MiscFlags           = .BUFFER_STRUCTURED;
        desc.StructureByteStride = 8;
        ID3D11Device_CreateBuffer(r.device, *desc, null, *r.sdf_point_buffer);
        srv_desc: D3D11_SHADER_RESOURCE_VIEW_DESC;
        srv_desc.Format        = .UNKNOWN;
        srv_desc.ViewDimension = .BUFFER;
        srv_desc.Buffer.NumElements = r.sdf_point_capacity;
        ID3D11Device_CreateShaderResourceView(r.device, xx r.sdf_point_buffer, *srv_desc, *r.sdf_point_srv);
    }
    if !r.sdf_point_buffer return;

    mapped: D3D11_MAPPED_SUBRESOURCE;
    if !SUCCEEDED(ID3D11DeviceContext_Map(r.ctx, xx r.sdf_point_buffer, 0, .WRITE_DISCARD, 0, *mapped)) return;
    dst := cast(*[2] float) mapped.pData;
    min_x :=  99999.0;
    min_y :=  99999.0;
    max_x := -99999.0;
    max_y := -99999.0;
    for i: 0 .. count - 1 {
        px := cast(float) (points[i].x + offset_x);
        py := cast(float) (points[i].y + offset_y);
        dst[i] = .[px, py];
        if px < min_x min_x = px;
        if px > max_x max_x = px;
        if py < min_y min_y = py;
        if py > max_y max_y = py;
    }
    ID3D11DeviceContext_Unmap(r.ctx, xx r.sdf_point_buffer, 0);

    pad := radius + 2.0;
    quad_verts: [6] Line_Vertex;
    quad_verts[0].position = .[min_x - pad, min_y - pad];
    quad_verts[1].position = .[max_x + pad, min_y - pad];
    quad_verts[2].position = .[min_x - pad, max_y + pad];
    quad_verts[3].position = .[max_x + pad, min_y - pad];
    quad_verts[4].position = .[max_x + pad, max_y + pad];
    quad_verts[5].position = .[min_x - pad, max_y + pad];

    if !SUCCEEDED(ID3D11DeviceContext_Map(r.ctx, xx r.line_vertex_buffer, 0, .WRITE_DISCARD, 0, *mapped)) return;
    memcpy(mapped.pData, quad_verts.data, 6 * size_of(Line_Vertex));
    ID3D11DeviceContext_Unmap(r.ctx, xx r.line_vertex_buffer, 0);

    constants: Line_Const_Buffer;
    constants.screen_size = .[cast(float) screen_w, cast(float) screen_h];
    constants.line_width  = radius;
    constants.padding     = cast(float) count;
    constants.line_color  = .[color.x, color.y, color.z, alpha];
    update_constant_buffer(r.ctx, r.line_const_buffer, *constants, size_of(Line_Const_Buffer));

    ID3D11DeviceContext_PSSetShaderResources(r.ctx, 0, 1, *r.sdf_point_srv);
    ID3D11DeviceContext_Draw(r.ctx, 6, 0);
}

CURSOR_RING_SEGS :: 24;

highlight_cursor_nx: float = 0.0;
highlight_cursor_ny: float = -1.0;

update_highlight_cursor_direction :: (dx: float, dy: float) {
    d := sqrt(dx*dx + dy*dy);
    if d < 0.5 return;
    target_nx := -dy / d;
    target_ny :=  dx / d;
    highlight_cursor_nx += (target_nx - highlight_cursor_nx) * 0.1;
    highlight_cursor_ny += (target_ny - highlight_cursor_ny) * 0.1;
    nd := sqrt(highlight_cursor_nx * highlight_cursor_nx + highlight_cursor_ny * highlight_cursor_ny);
    if nd > 0.0001 { highlight_cursor_nx /= nd; highlight_cursor_ny /= nd; }
}

render_brush_cursor :: (r: *Betterss_Renderer, mode: Annotation_Mode, cx: float, cy: float, width: float, color: Vector3, sel: *Selection_State) {
    if width < 1.0 return;
    c := Vector4.{color.x, color.y, color.z, 0.5};

    if mode == .LINE {
        radius := width * 0.5;
        inner  := max(radius - 1.5, 0.0);
        for i: 0 .. CURSOR_RING_SEGS - 1 {
            a0 := cast(float) i       * (TAU / CURSOR_RING_SEGS);
            a1 := cast(float) (i + 1) * (TAU / CURSOR_RING_SEGS);
            c0 := cos(a0); s0 := sin(a0);
            c1 := cos(a1); s1 := sin(a1);
            ui_emit_triangle(cx+c0*inner, cy+s0*inner, cx+c0*radius, cy+s0*radius, cx+c1*radius, cy+s1*radius, c, c, c);
            ui_emit_triangle(cx+c0*inner, cy+s0*inner, cx+c1*radius, cy+s1*radius, cx+c1*inner, cy+s1*inner, c, c, c);
        }
    } else if mode == .HIGHLIGHT {
        nx := highlight_cursor_nx;
        ny := highlight_cursor_ny;
        half_w := width;
        t : float = 1.5;
        lx := cx + nx * half_w;
        ly := cy + ny * half_w;
        rx := cx - nx * half_w;
        ry := cy - ny * half_w;
        px := -ny;
        py :=  nx;
        ui_emit_triangle(lx-px*t, ly-py*t, lx+px*t, ly+py*t, rx+px*t, ry+py*t, c, c, c);
        ui_emit_triangle(lx-px*t, ly-py*t, rx+px*t, ry+py*t, rx-px*t, ry-py*t, c, c, c);
    }
}

release_mode_label :: (label: *Mode_Label) {
    safe_release(label.srv);
    safe_release(label.texture);
    <<label = Mode_Label.{};
}

render_mode_label :: (r: *Betterss_Renderer, label: *Mode_Label, cursor_x: s32, cursor_y: s32, screen_w: s32, screen_h: s32) {
    if !label.srv return;

    off_x := label.height;
    off_y := -(label.height * 3 / 2);
    qx := cursor_x + off_x;
    qy := cursor_y + off_y;
    if qx + label.width > screen_w qx = screen_w - label.width;
    if qy < 0  qy = cursor_y + label.height / 2;
    if qx < 0  qx = 0;

    viewport: D3D11_VIEWPORT;
    viewport.TopLeftX = cast(float) qx;
    viewport.TopLeftY = cast(float) qy;
    viewport.Width    = cast(float) label.width;
    viewport.Height   = cast(float) label.height;
    viewport.MaxDepth = 1.0;
    ID3D11DeviceContext_RSSetViewports(r.ctx, 1, *viewport);

    constants: Overlay_Const_Buffer;
    constants.dim_factor  = 1.0;
    constants.texel_size  = .[1.0 / cast(float) label.width, 1.0 / cast(float) label.height];
    update_constant_buffer(r.ctx, r.constant_buffer, *constants, size_of(Overlay_Const_Buffer));

    ID3D11DeviceContext_IASetInputLayout      (r.ctx, null);
    ID3D11DeviceContext_IASetPrimitiveTopology(r.ctx, .TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader           (r.ctx, r.vertex_shader, null, 0);
    ID3D11DeviceContext_PSSetShader           (r.ctx, r.overlay_shader, null, 0);
    ID3D11DeviceContext_PSSetConstantBuffers  (r.ctx, 0, 1, *r.constant_buffer);
    ID3D11DeviceContext_PSSetSamplers         (r.ctx, 0, 1, *r.sampler);
    ID3D11DeviceContext_PSSetShaderResources  (r.ctx, 0, 1, *label.srv);

    blend_factor : [4] float;
    ID3D11DeviceContext_OMSetBlendState(r.ctx, r.alpha_blend, *blend_factor, 0xFFFFFFFF);

    ID3D11DeviceContext_Draw(r.ctx, 3, 0);

    ID3D11DeviceContext_OMSetBlendState(r.ctx, null, *blend_factor, 0xFFFFFFFF);

    null_srv: *ID3D11ShaderResourceView;
    ID3D11DeviceContext_PSSetShaderResources(r.ctx, 0, 1, *null_srv);
}

cache_monitor_background :: (r: *Betterss_Renderer, c: *Capture_State) {
    get_cached_texture(r, *r.cached_background, r.width, r.height, .DEFAULT, .RENDER_TARGET | .SHADER_RESOURCE, 0);
    if !r.cached_background.rtv return;

    ID3D11DeviceContext_OMSetRenderTargets(r.ctx, 1, *r.cached_background.rtv, null);
    black : [4] float : .[0.0, 0.0, 0.0, 0.0];
    ID3D11DeviceContext_ClearRenderTargetView(r.ctx, r.cached_background.rtv, *black);

    ID3D11DeviceContext_VSSetShader         (r.ctx, r.vertex_shader, null, 0);
    ID3D11DeviceContext_PSSetShader         (r.ctx, r.overlay_shader, null, 0);
    ID3D11DeviceContext_PSSetConstantBuffers(r.ctx, 0, 1, *r.constant_buffer);
    ID3D11DeviceContext_PSSetSamplers       (r.ctx, 0, 1, *r.sampler);

    origin_x := c.virtual_screen.left;
    origin_y := c.virtual_screen.top;

    for * mon: array_view(c.monitors, 0, c.monitor_count) {
        if !mon.has_frame || !mon.texture || !mon.srv continue;

        mon_w := mon.bounds.right  - mon.bounds.left;
        mon_h := mon.bounds.bottom - mon.bounds.top;

        viewport: D3D11_VIEWPORT;
        viewport.TopLeftX = cast(float) (mon.bounds.left - origin_x);
        viewport.TopLeftY = cast(float) (mon.bounds.top  - origin_y);
        viewport.Width    = cast(float) mon_w;
        viewport.Height   = cast(float) mon_h;
        viewport.MaxDepth = 1.0;
        ID3D11DeviceContext_RSSetViewports(r.ctx, 1, *viewport);

        constants: Overlay_Const_Buffer;
        constants.dim_factor = 1.0;
        constants.texel_size = .[1.0 / cast(float) mon_w, 1.0 / cast(float) mon_h];
        constants.rotation   = cast(float) (cast(s32) mon.rotation);
        update_constant_buffer(r.ctx, r.constant_buffer, *constants, size_of(Overlay_Const_Buffer));

        ID3D11DeviceContext_PSSetShaderResources  (r.ctx, 0, 1, *mon.srv);
        ID3D11DeviceContext_IASetPrimitiveTopology(r.ctx, .TRIANGLELIST);
        ID3D11DeviceContext_Draw                  (r.ctx, 3, 0);
    }

    null_rtv: *ID3D11RenderTargetView;
    ID3D11DeviceContext_OMSetRenderTargets(r.ctx, 1, *null_rtv, null);
}

initialize_shaders :: (r: *Betterss_Renderer) -> bool {
    if !r.device { r.ready = false; return false; }

    ID3D11Device_CreateVertexShader(r.device, OVERLAY_VS.data, xx OVERLAY_VS.count, null, *r.vertex_shader);
    ID3D11Device_CreatePixelShader (r.device, OVERLAY_PS.data, xx OVERLAY_PS.count, null, *r.overlay_shader);

    line_ok := initialize_line_renderer(r);
    ui_ok   := initialize_ui_renderer(r);

    blend_desc: D3D11_BLEND_DESC;
    blend_desc.RenderTarget[0].BlendEnable           = xx BOOL.TRUE;
    blend_desc.RenderTarget[0].SrcBlend              = .ONE;
    blend_desc.RenderTarget[0].DestBlend             = .INV_SRC_ALPHA;
    blend_desc.RenderTarget[0].BlendOp               = .ADD;
    blend_desc.RenderTarget[0].SrcBlendAlpha         = .ONE;
    blend_desc.RenderTarget[0].DestBlendAlpha        = .INV_SRC_ALPHA;
    blend_desc.RenderTarget[0].BlendOpAlpha          = .ADD;
    blend_desc.RenderTarget[0].RenderTargetWriteMask = xx D3D11_COLOR_WRITE_ENABLE.ALL;
    ID3D11Device_CreateBlendState(r.device, *blend_desc, *r.alpha_blend);

    // one success/failure for the whole device lifetime resource set
    // onstant_buffer and sampler are created back in acquire_renderer,
    // so they get verified here too and if any creation failed its 
    // pointer is still null and ready stays false
    r.ready = line_ok && ui_ok
        && r.vertex_shader   != null && r.overlay_shader != null
        && r.constant_buffer != null && r.sampler        != null
        && r.alpha_blend     != null;
    return r.ready;
}
