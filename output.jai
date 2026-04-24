Output_Pixels_Source_Kind :: enum u32 {
    NONE        :: 0;
    D3D_STAGING :: 1;
}

Output_Pixels :: struct {
    data:   *void;
    width:  u32;
    height: u32;
    pitch:  u32;

    source_kind: Output_Pixels_Source_Kind;
    staging:     *ID3D11Texture2D;
    renderer:    *Betterss_Renderer;
}

// pshufb mask to extract BGR from each BGRA quad, zero the top 4 bytes
SHUF_MASK : [16] u8 : .[
    0,  1,  2,   4,  5,  6,   8,  9, 10,  12, 13, 14,
    0xFF, 0xFF, 0xFF, 0xFF,
];

SIMD_TAIL_PADDING :: 48;  // one pshufb block of BGR

copy_pixels_to_clipboard :: (pixels: *u8, width: u32, height: u32, pitch: u32) -> bool {
    row_size    := (width * 3 + 3) & ~cast(u32) 3;
    data_size   := row_size * height;
    header_size := cast(u32) size_of(BITMAPINFOHEADER);

    // tail pad so the last SIMD block can overrun into a throwaway region
    // the header still declares biSizeImage = data_size so the clipboard
    // consumer only reads the real bytes
    // idk if im happy with this yet. requires a copy. need something more elegant to be honest
    hmem := GlobalAlloc(GMEM_MOVEABLE, header_size + data_size + SIMD_TAIL_PADDING);
    if !hmem return false;

    mem_ptr := GlobalLock(hmem);
    if !mem_ptr {
        GlobalFree(hmem);
        return false;
    }

    header := cast(*BITMAPINFOHEADER) mem_ptr;
    memset(header, 0, size_of(BITMAPINFOHEADER));
    header.biSize        = size_of(BITMAPINFOHEADER);
    header.biWidth       = cast(s32) width;
    header.biHeight      = cast(s32) height;
    header.biPlanes      = 1;
    header.biBitCount    = 24;
    header.biCompression = BI_RGB;
    header.biSizeImage   = data_size;

    // pad source rows up to 64 so the 4xmm load block always has 64 safe
    // bytes per row (DXGIs mapped pitch gives no guarantee :(
    aligned_pitch_u32 := (width * 4 + 63) & ~cast(u32) 63;
    aligned_pitch     := cast(s64) aligned_pitch_u32;
    src_buffer := cast(*u8) alloc(aligned_pitch * cast(s64) height + SIMD_TAIL_PADDING,, temp);

    for y: 0 .. cast(s64) height - 1 {
        memcpy(src_buffer + y * aligned_pitch, pixels + y * cast(s64) pitch, cast(s64) width * 4);
    }

    dst_data := cast(*u8) mem_ptr + header_size;

    blocks_per_row := (cast(s64) width + 15) / 16;

    mask_ptr := SHUF_MASK.data;

    // iterate image bottom -> top cuz the the DIBs memory order is also bottom up,
    // so we walk the dest forward each SIMD overrun lands in the NEXT rows src slot
    // which gets rewritten next iter the last iter's overrun lands in SIMD_TAIL_PADDING
    y_img := cast(s32) height - 1;
    while y_img >= 0 {
        defer y_img -= 1;

        src_row := src_buffer + cast(s64) y_img * aligned_pitch;
        dst_row := dst_data + (cast(s64) height - 1 - y_img) * cast(s64) row_size;

        for b: 0 .. blocks_per_row - 1 {
            s := src_row + b * 64;
            d := dst_row + b * 48;
            m := mask_ptr;

            #asm SSSE3 {
                movdqu.x mask:, [m];
                movdqu.x s0:,   [s + 0];
                movdqu.x s1:,   [s + 16];
                movdqu.x s2:,   [s + 32];
                movdqu.x s3:,   [s + 48];
                pshufb.x s0, mask;
                pshufb.x s1, mask;
                pshufb.x s2, mask;
                pshufb.x s3, mask;

                // 12 valid BGR + 4 zero
                movdqa.x t0:, s1;
                pslldq.x t0, 12;
                por.x    t0, s0;
                movdqu.x [d + 0], t0;

                // reassemble into 3x16 stores
                psrldq.x s1, 4;
                movdqa.x t1:, s2;
                pslldq.x t1, 8;
                por.x    t1, s1;
                movdqu.x [d + 16], t1;

                psrldq.x s2, 8;
                pslldq.x s3, 4;
                por.x    s3, s2;
                movdqu.x [d + 32], s3;
            }
        }
    }

    GlobalUnlock(hmem);

    // OpenClipboard fails if another process has it open
    // so just just retry briefly
    opened := false;
    for attempt: 0 .. 9 {
        if OpenClipboard(null) == .TRUE { opened = true; break; }
        Sleep(10);
    }

    if !opened {
        GlobalFree(hmem);
        return false;
    }

    EmptyClipboard();
    result := SetClipboardData(CF_DIB, hmem);
    CloseClipboard();

    if !result {
        GlobalFree(hmem);
        return false;
    }
    return true;
}

save_pixels_to_file :: (factory: *IWICImagingFactory, pixels: *u8, width: u32, height: u32, pitch: u32, filename: *u16) -> bool {
    if !factory return false;

    stream:        *IWICStream;
    encoder:       *IWICBitmapEncoder;
    frame_encoder: *IWICBitmapFrameEncode;
    props:         *IPropertyBag2;

    defer {
        safe_release(frame_encoder);
        safe_release(props);
        safe_release(encoder);
        safe_release(stream);
    }

    if FAILED(IWICImagingFactory_CreateStream (factory, *stream))                                                      return false;
    if FAILED(IWICStream_InitializeFromFilename(stream,  filename, GENERIC_WRITE))                                     return false;
    if FAILED(IWICImagingFactory_CreateEncoder(factory, *GUID_CONTAINER_FORMAT_PNG, null, *encoder))                   return false;
    if FAILED(IWICBitmapEncoder_Initialize    (encoder, cast(*IStream) stream, WICBitmapEncoderNoCache))               return false;
    if FAILED(IWICBitmapEncoder_CreateNewFrame(encoder, *frame_encoder, *props))                                       return false;
    if FAILED(IWICBitmapFrameEncode_Initialize(frame_encoder, null))                                                   return false;
    if FAILED(IWICBitmapFrameEncode_SetSize   (frame_encoder, width, height))                                          return false;

    if FAILED(IWICBitmapFrameEncode_SetPixelFormat(frame_encoder, *GUID_WIC_PIXEL_FORMAT_32BPPBGRA)) return false;

    row_bytes    : u32 = width * 4;
    buffer_bytes : u32 = ifx height > 0 then (height - 1) * pitch + row_bytes else 0;
    if FAILED(IWICBitmapFrameEncode_WritePixels(frame_encoder, height, pitch, buffer_bytes, pixels)) return false;
    if FAILED(IWICBitmapFrameEncode_Commit     (frame_encoder))                                      return false;
    if FAILED(IWICBitmapEncoder_Commit         (encoder))                                            return false;

    return true;
}

acquire_selection_pixels :: (r: *Betterss_Renderer, selection_rect: RECT, s: *Selection_State) -> Output_Pixels {
    result: Output_Pixels;
    if !r || !r.device || !r.ctx return result;
    if !r.cached_background.texture return result;

    sel_w := selection_rect.right  - selection_rect.left;
    sel_h := selection_rect.bottom - selection_rect.top;
    if sel_w <= 0 || sel_h <= 0 return result;

    render_tex := get_cached_texture(r, *r.cached_render, cast(u32) sel_w, cast(u32) sel_h,
                                     .DEFAULT, .RENDER_TARGET, 0);
    if !render_tex || !r.cached_render.rtv return result;

    src_box: D3D11_BOX;
    src_box.left   = cast(u32) selection_rect.left;
    src_box.top    = cast(u32) selection_rect.top;
    src_box.right  = cast(u32) selection_rect.right;
    src_box.bottom = cast(u32) selection_rect.bottom;
    src_box.back   = 1;
    ID3D11DeviceContext_CopySubresourceRegion(r.ctx, xx render_tex, 0, 0, 0, 0, xx r.cached_background.texture, 0, *src_box);

    has_annotations := s != null && s.annotation_count > 0;
    if has_annotations {
        ID3D11DeviceContext_OMSetRenderTargets(r.ctx, 1, *r.cached_render.rtv, null);

        viewport: D3D11_VIEWPORT;
        viewport.Width    = cast(float) sel_w;
        viewport.Height   = cast(float) sel_h;
        viewport.MaxDepth = 1.0;
        ID3D11DeviceContext_RSSetViewports(r.ctx, 1, *viewport);

        render_annotations(r, s, -selection_rect.left, -selection_rect.top, sel_w, sel_h);

        null_rtv: *ID3D11RenderTargetView;
        ID3D11DeviceContext_OMSetRenderTargets(r.ctx, 1, *null_rtv, null);
    }

    staging := get_cached_texture(r, *r.cached_staging, cast(u32) sel_w, cast(u32) sel_h,
                                  .STAGING, 0, .READ);
    if !staging return result;

    full_box: D3D11_BOX;
    full_box.right  = cast(u32) sel_w;
    full_box.bottom = cast(u32) sel_h;
    full_box.back   = 1;
    ID3D11DeviceContext_CopySubresourceRegion(r.ctx, xx staging, 0, 0, 0, 0, xx render_tex, 0, *full_box);

    mapped: D3D11_MAPPED_SUBRESOURCE;
    if SUCCEEDED(ID3D11DeviceContext_Map(r.ctx, xx staging, 0, .READ, 0, *mapped)) {
        result.data        = mapped.pData;
        result.width       = cast(u32) sel_w;
        result.height      = cast(u32) sel_h;
        result.pitch       = mapped.RowPitch;
        result.source_kind = .D3D_STAGING;
        result.staging     = staging;
        result.renderer    = r;
    }

    return result;
}

release_output_pixels :: (p: *Output_Pixels) {
    if p.source_kind == .D3D_STAGING && p.data {
        ID3D11DeviceContext_Unmap(p.renderer.ctx, xx p.staging, 0);
    }
    <<p = Output_Pixels.{};
}

write_pixels_to_clipboard :: (p: Output_Pixels) -> bool {
    if !p.data return false;
    return copy_pixels_to_clipboard(cast(*u8) p.data, p.width, p.height, p.pitch);
}

write_pixels_to_file :: (factory: *IWICImagingFactory, p: Output_Pixels, filename: *u16) -> bool {
    if !p.data || !factory return false;
    return save_pixels_to_file(factory, cast(*u8) p.data, p.width, p.height, p.pitch, filename);
}
