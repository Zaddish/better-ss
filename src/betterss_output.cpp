#pragma comment (lib, "ole32.lib")
#pragma comment (lib, "windowscodecs.lib")

#include <wincodec.h>
#include <objbase.h>
#include <tmmintrin.h>

static ID3D11Texture2D *GetCachedTexture(betterss_renderer *R, betterss_renderer::cached_texture *Cache,
                                          uint32_t Width, uint32_t Height,
                                          D3D11_USAGE Usage, UINT BindFlags, UINT CPUAccess) {
    if(Cache->Texture && Cache->Width >= Width && Cache->Height >= Height) {
        return Cache->Texture;
    }

    if(Cache->RTV) { Cache->RTV->Release(); Cache->RTV = 0; }
    if(Cache->Texture) { Cache->Texture->Release(); Cache->Texture = 0; }

    D3D11_TEXTURE2D_DESC Desc = {};
    Desc.Width = Width;
    Desc.Height = Height;
    Desc.MipLevels = 1;
    Desc.ArraySize = 1;
    Desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    Desc.SampleDesc.Count = 1;
    Desc.Usage = Usage;
    Desc.BindFlags = BindFlags;
    Desc.CPUAccessFlags = CPUAccess;

    R->Device->CreateTexture2D(&Desc, 0, &Cache->Texture);

    if(Cache->Texture) {
        if(BindFlags & D3D11_BIND_RENDER_TARGET) {
            R->Device->CreateRenderTargetView(Cache->Texture, 0, &Cache->RTV);
        }
        Cache->Width = Width;
        Cache->Height = Height;
    }

    return Cache->Texture;
}

static int FindMonitorForRect(capture_state *C, RECT Selection, monitor_duplication **OutMon) {
    int CenterX = (Selection.left + Selection.right) / 2;
    int CenterY = (Selection.top + Selection.bottom) / 2;

    CenterX += C->VirtualScreen.left;
    CenterY += C->VirtualScreen.top;

    for(uint32_t i = 0; i < C->MonitorCount; i++) {
        monitor_duplication *Mon = &C->Monitors[i];
        if(Mon->HasFrame && Mon->Texture) {
            if(CenterX >= Mon->Bounds.left && CenterX < Mon->Bounds.right &&
               CenterY >= Mon->Bounds.top && CenterY < Mon->Bounds.bottom) {
                *OutMon = Mon;
                return(1);
            }
        }
    }

    for(uint32_t i = 0; i < C->MonitorCount; i++) {
        if(C->Monitors[i].HasFrame && C->Monitors[i].Texture) {
            *OutMon = &C->Monitors[i];
            return(1);
        }
    }

    return(0);
}

static int CopyPixelsToClipboard(void *Pixels, uint32_t Width, uint32_t Height, uint32_t Pitch) {
    uint32_t RowSize = ((Width * 3 + 3) / 4) * 4;
    uint32_t DataSize = RowSize * Height;
    uint32_t HeaderSize = sizeof(BITMAPINFOHEADER);

    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, HeaderSize + DataSize);
    if(!hMem) return(0);

    void *MemPtr = GlobalLock(hMem);
    if(!MemPtr) {
        GlobalFree(hMem);
        return(0);
    }

    BITMAPINFOHEADER *Header = (BITMAPINFOHEADER *)MemPtr;
    memset(Header, 0, sizeof(BITMAPINFOHEADER));
    Header->biSize = sizeof(BITMAPINFOHEADER);
    Header->biWidth = (LONG)Width;
    Header->biHeight = (LONG)Height;
    Header->biPlanes = 1;
    Header->biBitCount = 24;
    Header->biCompression = BI_RGB;
    Header->biSizeImage = DataSize;

    uint8_t *Src = (uint8_t *)Pixels;
    uint8_t *Dst = (uint8_t *)MemPtr + HeaderSize;

    __m128i ShufMask = _mm_setr_epi8(0,1,2,4, 5,6,8,9, 10,12,13,14, -1,-1,-1,-1);
    uint32_t SimdWidth = Width & ~15u;

    for(uint32_t y = 0; y < Height; y++) {
        uint8_t *SrcRow = Src + y * Pitch;
        uint8_t *DstRow = Dst + (Height - 1 - y) * RowSize;

        uint32_t x = 0;
        for(; x < SimdWidth; x += 16) {
            __m128i s0 = _mm_shuffle_epi8(_mm_loadu_si128((__m128i *)(SrcRow + x * 4 +  0)), ShufMask);
            __m128i s1 = _mm_shuffle_epi8(_mm_loadu_si128((__m128i *)(SrcRow + x * 4 + 16)), ShufMask);
            __m128i s2 = _mm_shuffle_epi8(_mm_loadu_si128((__m128i *)(SrcRow + x * 4 + 32)), ShufMask);
            __m128i s3 = _mm_shuffle_epi8(_mm_loadu_si128((__m128i *)(SrcRow + x * 4 + 48)), ShufMask);

            _mm_storeu_si128((__m128i *)(DstRow + x * 3 +  0), _mm_or_si128(s0, _mm_slli_si128(s1, 12)));
            _mm_storeu_si128((__m128i *)(DstRow + x * 3 + 16), _mm_or_si128(_mm_srli_si128(s1, 4), _mm_slli_si128(s2, 8)));
            _mm_storeu_si128((__m128i *)(DstRow + x * 3 + 32), _mm_or_si128(_mm_srli_si128(s2, 8), _mm_slli_si128(s3, 4)));
        }

        for(; x < Width; x++) {
            DstRow[x * 3 + 0] = SrcRow[x * 4 + 0];
            DstRow[x * 3 + 1] = SrcRow[x * 4 + 1];
            DstRow[x * 3 + 2] = SrcRow[x * 4 + 2];
        }
    }

    GlobalUnlock(hMem);

    // OpenClipboard fails if another process has it open;
    // so we'll retry briefly for transient contention
    int Opened = 0;
    for(int Attempt = 0; Attempt < 10; Attempt++) {
        if(OpenClipboard(0)) { Opened = 1; break; }
        Sleep(10);
    }

    if(Opened) {
        EmptyClipboard();
        SetClipboardData(CF_DIB, hMem);
        CloseClipboard();
        return(1);
    }

    GlobalFree(hMem);
    return(0);
}

static int SavePixelsToFile(void *Pixels, uint32_t Width, uint32_t Height, uint32_t Pitch, const wchar_t *Filename) {
    int Result = 0;

    IWICImagingFactory *Factory = 0;
    IWICStream *Stream = 0;
    IWICBitmapEncoder *Encoder = 0;
    IWICBitmapFrameEncode *FrameEncoder = 0;

    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, 0, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&Factory));
    if(FAILED(hr)) goto done;

    hr = Factory->CreateStream(&Stream);
    if(FAILED(hr)) goto done;

    hr = Stream->InitializeFromFilename(Filename, GENERIC_WRITE);
    if(FAILED(hr)) goto done;

    hr = Factory->CreateEncoder(GUID_ContainerFormatPng, 0, &Encoder);
    if(FAILED(hr)) goto done;

    hr = Encoder->Initialize((IStream*)Stream, WICBitmapEncoderNoCache);
    if(FAILED(hr)) goto done;

    {
        IPropertyBag2 *Props = 0;
        hr = Encoder->CreateNewFrame(&FrameEncoder, &Props);
        if(Props) Props->Release();
        if(FAILED(hr)) goto done;
    }

    hr = FrameEncoder->Initialize(0);
    if(FAILED(hr)) goto done;

    hr = FrameEncoder->SetSize(Width, Height);
    if(FAILED(hr)) goto done;

    {
        WICPixelFormatGUID Format = GUID_WICPixelFormat32bppBGRA;
        hr = FrameEncoder->SetPixelFormat(&Format);
        if(FAILED(hr)) goto done;
    }

    hr = FrameEncoder->WritePixels(Height, Pitch, Height * Pitch, (uint8_t *)Pixels);
    if(SUCCEEDED(hr)) hr = FrameEncoder->Commit();
    if(SUCCEEDED(hr)) hr = Encoder->Commit();
    if(SUCCEEDED(hr)) Result = 1;

done:
    if(FrameEncoder) FrameEncoder->Release();
    if(Encoder) Encoder->Release();
    if(Stream) Stream->Release();
    if(Factory) Factory->Release();
    return(Result);
}

struct resolved_pixels {
    void *Data;
    uint32_t Width;
    uint32_t Height;
    uint32_t Pitch;
    ID3D11Texture2D *Staging;
    betterss_renderer *Renderer;
};

static resolved_pixels ResolveSelectionPixels(betterss_renderer *R, capture_state *C, RECT Selection, selection_state *S) {
    resolved_pixels Result = {};
    if(!R || !R->Device || !R->Context || !C) return(Result);

    monitor_duplication *Mon = 0;
    if(!FindMonitorForRect(C, Selection, &Mon)) return(Result);

    int SelWidth = Selection.right - Selection.left;
    int SelHeight = Selection.bottom - Selection.top;
    if(SelWidth <= 0 || SelHeight <= 0) return(Result);

    int VirtLeft = Selection.left + C->VirtualScreen.left;
    int VirtTop = Selection.top + C->VirtualScreen.top;
    int LocalLeft = VirtLeft - Mon->Bounds.left;
    int LocalTop = VirtTop - Mon->Bounds.top;

    int MonWidth = Mon->Bounds.right - Mon->Bounds.left;
    int MonHeight = Mon->Bounds.bottom - Mon->Bounds.top;

    if(LocalLeft < 0) { SelWidth += LocalLeft; LocalLeft = 0; }
    if(LocalTop < 0) { SelHeight += LocalTop; LocalTop = 0; }
    if(LocalLeft + SelWidth > MonWidth) SelWidth = MonWidth - LocalLeft;
    if(LocalTop + SelHeight > MonHeight) SelHeight = MonHeight - LocalTop;
    if(SelWidth <= 0 || SelHeight <= 0) return(Result);

    D3D11_BOX SrcBox = {};
    SrcBox.left = (UINT)LocalLeft;
    SrcBox.top = (UINT)LocalTop;
    SrcBox.front = 0;
    SrcBox.right = (UINT)(LocalLeft + SelWidth);
    SrcBox.bottom = (UINT)(LocalTop + SelHeight);
    SrcBox.back = 1;

    int HasAnnotations = S && S->LineCount > 0;

    if(HasAnnotations) {
        ID3D11Texture2D *RenderTexture = GetCachedTexture(R, &R->CachedRender, (uint32_t)SelWidth, (uint32_t)SelHeight,
            D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET, 0);
        if(!RenderTexture || !R->CachedRender.RTV) return(Result);

        R->Context->CopySubresourceRegion(RenderTexture, 0, 0, 0, 0, Mon->Texture, 0, &SrcBox);

        R->Context->OMSetRenderTargets(1, &R->CachedRender.RTV, 0);

        D3D11_VIEWPORT Viewport = {};
        Viewport.Width = (float)SelWidth;
        Viewport.Height = (float)SelHeight;
        Viewport.MaxDepth = 1.0f;
        R->Context->RSSetViewports(1, &Viewport);

        RenderAnnotationLines(R, S, -Selection.left, -Selection.top, SelWidth, SelHeight);

        ID3D11RenderTargetView *NullRTV = 0;
        R->Context->OMSetRenderTargets(1, &NullRTV, 0);

        SrcBox.left = 0;
        SrcBox.top = 0;
        SrcBox.right = (UINT)SelWidth;
        SrcBox.bottom = (UINT)SelHeight;
    }

    ID3D11Texture2D *Staging = GetCachedTexture(R, &R->CachedStaging, (uint32_t)SelWidth, (uint32_t)SelHeight,
        D3D11_USAGE_STAGING, 0, D3D11_CPU_ACCESS_READ);
    if(!Staging) return(Result);

    ID3D11Texture2D *CopySrc = HasAnnotations ? R->CachedRender.Texture : Mon->Texture;
    R->Context->CopySubresourceRegion(Staging, 0, 0, 0, 0, CopySrc, 0, &SrcBox);

    D3D11_MAPPED_SUBRESOURCE Mapped;
    if(SUCCEEDED(R->Context->Map(Staging, 0, D3D11_MAP_READ, 0, &Mapped))) {
        Result.Data = Mapped.pData;
        Result.Width = (uint32_t)SelWidth;
        Result.Height = (uint32_t)SelHeight;
        Result.Pitch = Mapped.RowPitch;
        Result.Staging = Staging;
        Result.Renderer = R;
    }

    return(Result);
}

static void ReleaseResolvedPixels(resolved_pixels *P) {
    if(P->Data) {
        P->Renderer->Context->Unmap(P->Staging, 0);
        P->Data = 0;
    }
}

static int CopySelectionToClipboard(betterss_renderer *R, capture_state *C, RECT Selection, selection_state *S) {
    resolved_pixels Pixels = ResolveSelectionPixels(R, C, Selection, S);
    int Result = 0;
    if(Pixels.Data) {
        Result = CopyPixelsToClipboard(Pixels.Data, Pixels.Width, Pixels.Height, Pixels.Pitch);
    }
    ReleaseResolvedPixels(&Pixels);
    return(Result);
}

static int SaveSelectionToFile(betterss_renderer *R, capture_state *C, RECT Selection, const wchar_t *Filename, selection_state *S) {
    resolved_pixels Pixels = ResolveSelectionPixels(R, C, Selection, S);
    int Result = 0;
    if(Pixels.Data) {
        Result = SavePixelsToFile(Pixels.Data, Pixels.Width, Pixels.Height, Pixels.Pitch, Filename);
    }
    ReleaseResolvedPixels(&Pixels);
    return(Result);
}
