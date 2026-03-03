#pragma comment (lib, "ole32.lib")
#pragma comment (lib, "windowscodecs.lib")

#include <wincodec.h>
#include <objbase.h>
#include <tmmintrin.h>

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
            uint8_t *SrcPx = SrcRow + x * 4;
            uint8_t *DstPx = DstRow + x * 3;
            DstPx[0] = SrcPx[0];
            DstPx[1] = SrcPx[1];
            DstPx[2] = SrcPx[2];
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
        HANDLE Result = SetClipboardData(CF_DIB, hMem);
        CloseClipboard();
        if(!Result) { GlobalFree(hMem); return(0); }
        return(1);
    }

    GlobalFree(hMem);
    return(0);
}

static int SavePixelsToFile(IWICImagingFactory *Factory, void *Pixels, uint32_t Width, uint32_t Height, uint32_t Pitch, const wchar_t *Filename) {
    if(!Factory) return(0);

    int Result = 0;
    uint32_t RowBytes = 0;
    uint32_t BufferBytes = 0;

    IWICStream *Stream = 0;
    IWICBitmapEncoder *Encoder = 0;
    IWICBitmapFrameEncode *FrameEncoder = 0;

    HRESULT hr = Factory->CreateStream(&Stream);
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

    RowBytes = Width * 4;
    BufferBytes = (Height > 0) ? ((Height - 1) * Pitch + RowBytes) : 0;
    hr = FrameEncoder->WritePixels(Height, Pitch, BufferBytes, (uint8_t *)Pixels);
    if(SUCCEEDED(hr)) hr = FrameEncoder->Commit();
    if(SUCCEEDED(hr)) hr = Encoder->Commit();
    if(SUCCEEDED(hr)) Result = 1;

done:
    if(FrameEncoder) FrameEncoder->Release();
    if(Encoder) Encoder->Release();
    if(Stream) Stream->Release();
    return(Result);
}

static output_pixels AcquireSelectionPixels(betterss_renderer *R, capture_state *C, RECT Selection, selection_state *S) {
    output_pixels Result = {};
    if(!R || !R->Device || !R->Context || !C) return(Result);

    int SelWidth = Selection.right - Selection.left;
    int SelHeight = Selection.bottom - Selection.top;
    if(SelWidth <= 0 || SelHeight <= 0) return(Result);

    RECT SelScreen;
    SelScreen.left = Selection.left + C->VirtualScreen.left;
    SelScreen.top = Selection.top + C->VirtualScreen.top;
    SelScreen.right = Selection.right + C->VirtualScreen.left;
    SelScreen.bottom = Selection.bottom + C->VirtualScreen.top;

    ID3D11Texture2D *RenderTexture = GetCachedTexture(R, &R->CachedRender, (uint32_t)SelWidth, (uint32_t)SelHeight,
        D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET, 0);
    if(!RenderTexture || !R->CachedRender.RTV) return(Result);

    R->Context->OMSetRenderTargets(1, &R->CachedRender.RTV, 0);
    float ClearColor[4] = {};
    R->Context->ClearRenderTargetView(R->CachedRender.RTV, ClearColor);

    RECT NoSelection = {};
    ComposeMonitorsToRT(R, C, SelScreen.left, SelScreen.top, NoSelection, 1.0f);

    int HasAnnotations = S && S->AnnotationCount > 0;
    if(HasAnnotations) {
        D3D11_VIEWPORT Viewport = {};
        Viewport.Width = (float)SelWidth;
        Viewport.Height = (float)SelHeight;
        Viewport.MaxDepth = 1.0f;
        R->Context->RSSetViewports(1, &Viewport);

        RenderAnnotations(R, S, -Selection.left, -Selection.top, SelWidth, SelHeight);
    }

    ID3D11RenderTargetView *NullRTV = 0;
    R->Context->OMSetRenderTargets(1, &NullRTV, 0);

    ID3D11Texture2D *Staging = GetCachedTexture(R, &R->CachedStaging, (uint32_t)SelWidth, (uint32_t)SelHeight,
        D3D11_USAGE_STAGING, 0, D3D11_CPU_ACCESS_READ);
    if(!Staging) return(Result);

    D3D11_BOX FullBox = {};
    FullBox.right = (UINT)SelWidth;
    FullBox.bottom = (UINT)SelHeight;
    FullBox.back = 1;
    R->Context->CopySubresourceRegion(Staging, 0, 0, 0, 0, RenderTexture, 0, &FullBox);

    D3D11_MAPPED_SUBRESOURCE Mapped;
    if(SUCCEEDED(R->Context->Map(Staging, 0, D3D11_MAP_READ, 0, &Mapped))) {
        Result.Data = Mapped.pData;
        Result.Width = (uint32_t)SelWidth;
        Result.Height = (uint32_t)SelHeight;
        Result.Pitch = Mapped.RowPitch;
        Result.SourceKind = OutputPixelsSource_D3DStaging;
        Result.Staging = Staging;
        Result.Renderer = R;
    }

    return(Result);
}

static void ReleaseOutputPixels(output_pixels *P) {
    if(P->SourceKind == OutputPixelsSource_D3DStaging && P->Data) {
        P->Renderer->Context->Unmap(P->Staging, 0);
    }
    *P = {};
}

static int WritePixelsToClipboard(output_pixels Pixels) {
    if(!Pixels.Data) return(0);
    return(CopyPixelsToClipboard(Pixels.Data, Pixels.Width, Pixels.Height, Pixels.Pitch));
}

static int WritePixelsToFile(IWICImagingFactory *WICFactory, output_pixels Pixels, const wchar_t *Filename) {
    if(!Pixels.Data || !WICFactory) return(0);
    return(SavePixelsToFile(WICFactory, Pixels.Data, Pixels.Width, Pixels.Height, Pixels.Pitch, Filename));
}
