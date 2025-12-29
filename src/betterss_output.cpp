#pragma comment (lib, "ole32.lib")
#pragma comment (lib, "windowscodecs.lib")

#include <wincodec.h>
#include <objbase.h>

static ID3D11Texture2D *CreateStagingTexture(ID3D11Device *Device, uint32_t Width, uint32_t Height) {
    ID3D11Texture2D *Result = 0;

    D3D11_TEXTURE2D_DESC Desc = {};
    Desc.Width = Width;
    Desc.Height = Height;
    Desc.MipLevels = 1;
    Desc.ArraySize = 1;
    Desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    Desc.SampleDesc.Count = 1;
    Desc.Usage = D3D11_USAGE_STAGING;
    Desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;

    Device->CreateTexture2D(&Desc, 0, &Result);
    return(Result);
}

static ID3D11Texture2D *CreateRenderTexture(ID3D11Device *Device, uint32_t Width, uint32_t Height) {
    ID3D11Texture2D *Result = 0;

    D3D11_TEXTURE2D_DESC Desc = {};
    Desc.Width = Width;
    Desc.Height = Height;
    Desc.MipLevels = 1;
    Desc.ArraySize = 1;
    Desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    Desc.SampleDesc.Count = 1;
    Desc.Usage = D3D11_USAGE_DEFAULT;
    Desc.BindFlags = D3D11_BIND_RENDER_TARGET;

    Device->CreateTexture2D(&Desc, 0, &Result);
    return(Result);
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

    for(uint32_t y = 0; y < Height; y++) {
        uint32_t SrcY = y;
        uint32_t DstY = Height - 1 - y;
        for(uint32_t x = 0; x < Width; x++) {
            Dst[DstY * RowSize + x * 3 + 0] = Src[SrcY * Pitch + x * 4 + 0];
            Dst[DstY * RowSize + x * 3 + 1] = Src[SrcY * Pitch + x * 4 + 1];
            Dst[DstY * RowSize + x * 3 + 2] = Src[SrcY * Pitch + x * 4 + 2];
        }
    }

    GlobalUnlock(hMem);

    if(OpenClipboard(0)) {
        EmptyClipboard();
        SetClipboardData(CF_DIB, hMem);
        CloseClipboard();
        return(1);
    }

    GlobalFree(hMem);
    return(0);
}

static int SavePixelsToFile(void *Pixels, uint32_t Width, uint32_t Height, uint32_t Pitch, const wchar_t *Filename) {
    IWICImagingFactory *Factory = 0;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, 0, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&Factory));
    if(FAILED(hr)) return(0);

    IWICStream *Stream = 0;
    hr = Factory->CreateStream(&Stream);
    if(FAILED(hr)) {
        Factory->Release();
        return(0);
    }

    hr = Stream->InitializeFromFilename(Filename, GENERIC_WRITE);
    if(FAILED(hr)) {
        Stream->Release();
        Factory->Release();
        return(0);
    }

    IWICBitmapEncoder *Encoder = 0;
    hr = Factory->CreateEncoder(GUID_ContainerFormatPng, 0, &Encoder);
    if(FAILED(hr)) {
        Stream->Release();
        Factory->Release();
        return(0);
    }

    hr = Encoder->Initialize((IStream*)Stream, WICBitmapEncoderNoCache);
    if(FAILED(hr)) {
        Encoder->Release();
        Stream->Release();
        Factory->Release();
        return(0);
    }

    IWICBitmapFrameEncode *FrameEncoder = 0;
    IPropertyBag2 *Props = 0;
    hr = Encoder->CreateNewFrame(&FrameEncoder, &Props);
    if(FAILED(hr)) {
        Encoder->Release();
        Stream->Release();
        Factory->Release();
        return(0);
    }

    if(Props) Props->Release();

    hr = FrameEncoder->Initialize(0);
    if(FAILED(hr)) {
        FrameEncoder->Release();
        Encoder->Release();
        Stream->Release();
        Factory->Release();
        return(0);
    }

    hr = FrameEncoder->SetSize(Width, Height);
    if(FAILED(hr)) {
        FrameEncoder->Release();
        Encoder->Release();
        Stream->Release();
        Factory->Release();
        return(0);
    }

    WICPixelFormatGUID Format = GUID_WICPixelFormat32bppBGRA;
    hr = FrameEncoder->SetPixelFormat(&Format);
    if(FAILED(hr)) {
        FrameEncoder->Release();
        Encoder->Release();
        Stream->Release();
        Factory->Release();
        return(0);
    }

    uint8_t *Src = (uint8_t *)Pixels;
    UINT Stride = Pitch;
    for(uint32_t y = 0; y < Height; y++) {
        hr = FrameEncoder->WritePixels(1, Stride, Stride, Src + y * Pitch);
        if(FAILED(hr)) break;
    }

    if(SUCCEEDED(hr)) {
        hr = FrameEncoder->Commit();
    }
    if(SUCCEEDED(hr)) {
        hr = Encoder->Commit();
    }

    FrameEncoder->Release();
    Encoder->Release();
    Stream->Release();
    Factory->Release();

    return(SUCCEEDED(hr) ? 1 : 0);
}

static int CopySelectionToClipboard(betterss_renderer *R, capture_state *C, RECT Selection, selection_state *S) {
    if(!R || !R->Device || !R->Context || !C) return(0);
    
    monitor_duplication *Mon = 0;
    if(!FindMonitorForRect(C, Selection, &Mon)) {
        return(0);
    }

    int SelWidth = Selection.right - Selection.left;
    int SelHeight = Selection.bottom - Selection.top;
    if(SelWidth <= 0 || SelHeight <= 0) return(0);

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
    if(SelWidth <= 0 || SelHeight <= 0) return(0);

    // If no annotations, use fast path
    if(!S || S->LineCount == 0) {
        ID3D11Texture2D *Staging = CreateStagingTexture(R->Device, (uint32_t)SelWidth, (uint32_t)SelHeight);
        if(!Staging) return(0);

        D3D11_BOX SrcBox = {};
        SrcBox.left = (UINT)LocalLeft;
        SrcBox.top = (UINT)LocalTop;
        SrcBox.front = 0;
        SrcBox.right = (UINT)(LocalLeft + SelWidth);
        SrcBox.bottom = (UINT)(LocalTop + SelHeight);
        SrcBox.back = 1;

        R->Context->CopySubresourceRegion(Staging, 0, 0, 0, 0, Mon->Texture, 0, &SrcBox);

        D3D11_MAPPED_SUBRESOURCE Mapped;
        HRESULT hr = R->Context->Map(Staging, 0, D3D11_MAP_READ, 0, &Mapped);

        int Result = 0;
        if(SUCCEEDED(hr)) {
            Result = CopyPixelsToClipboard(Mapped.pData, (uint32_t)SelWidth, (uint32_t)SelHeight, Mapped.RowPitch);
            R->Context->Unmap(Staging, 0);
        }

        Staging->Release();
        return(Result);
    }

    // With annotations: render to intermediate texture
    ID3D11Texture2D *RenderTexture = CreateRenderTexture(R->Device, (uint32_t)SelWidth, (uint32_t)SelHeight);
    if(!RenderTexture) return(0);

    ID3D11RenderTargetView *RTV = 0;
    if(FAILED(R->Device->CreateRenderTargetView(RenderTexture, 0, &RTV))) {
        RenderTexture->Release();
        return(0);
    }

    // Copy desktop region first
    D3D11_BOX SrcBox = {};
    SrcBox.left = (UINT)LocalLeft;
    SrcBox.top = (UINT)LocalTop;
    SrcBox.front = 0;
    SrcBox.right = (UINT)(LocalLeft + SelWidth);
    SrcBox.bottom = (UINT)(LocalTop + SelHeight);
    SrcBox.back = 1;

    R->Context->CopySubresourceRegion(RenderTexture, 0, 0, 0, 0, Mon->Texture, 0, &SrcBox);

    // Render annotations on top
    R->Context->OMSetRenderTargets(1, &RTV, 0);
    
    D3D11_VIEWPORT Viewport = {};
    Viewport.Width = (float)SelWidth;
    Viewport.Height = (float)SelHeight;
    Viewport.MaxDepth = 1.0f;
    R->Context->RSSetViewports(1, &Viewport);
    
    RenderAnnotationLines(R, S, -Selection.left, -Selection.top, SelWidth, SelHeight);
    
    RTV->Release();

    // Copy to staging
    ID3D11Texture2D *Staging = CreateStagingTexture(R->Device, (uint32_t)SelWidth, (uint32_t)SelHeight);
    if(!Staging) {
        RenderTexture->Release();
        return(0);
    }

    R->Context->CopyResource(Staging, RenderTexture);
    RenderTexture->Release();

    D3D11_MAPPED_SUBRESOURCE Mapped;
    HRESULT hr = R->Context->Map(Staging, 0, D3D11_MAP_READ, 0, &Mapped);

    int Result = 0;
    if(SUCCEEDED(hr)) {
        Result = CopyPixelsToClipboard(Mapped.pData, (uint32_t)SelWidth, (uint32_t)SelHeight, Mapped.RowPitch);
        R->Context->Unmap(Staging, 0);
    }

    Staging->Release();
    return(Result);
}

static int SaveSelectionToFile(betterss_renderer *R, capture_state *C, RECT Selection, const wchar_t *Filename, selection_state *S) {
    if(!R || !R->Device || !R->Context || !C) return(0);
    
    monitor_duplication *Mon = 0;
    if(!FindMonitorForRect(C, Selection, &Mon)) {
        return(0);
    }

    int SelWidth = Selection.right - Selection.left;
    int SelHeight = Selection.bottom - Selection.top;
    if(SelWidth <= 0 || SelHeight <= 0) return(0);

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
    if(SelWidth <= 0 || SelHeight <= 0) return(0);

    // If no annotations, use fast path
    if(!S || S->LineCount == 0) {
        ID3D11Texture2D *Staging = CreateStagingTexture(R->Device, (uint32_t)SelWidth, (uint32_t)SelHeight);
        if(!Staging) return(0);

        D3D11_BOX SrcBox = {};
        SrcBox.left = (UINT)LocalLeft;
        SrcBox.top = (UINT)LocalTop;
        SrcBox.front = 0;
        SrcBox.right = (UINT)(LocalLeft + SelWidth);
        SrcBox.bottom = (UINT)(LocalTop + SelHeight);
        SrcBox.back = 1;

        R->Context->CopySubresourceRegion(Staging, 0, 0, 0, 0, Mon->Texture, 0, &SrcBox);

        D3D11_MAPPED_SUBRESOURCE Mapped;
        HRESULT hr = R->Context->Map(Staging, 0, D3D11_MAP_READ, 0, &Mapped);

        int Result = 0;
        if(SUCCEEDED(hr)) {
            Result = SavePixelsToFile(Mapped.pData, (uint32_t)SelWidth, (uint32_t)SelHeight, Mapped.RowPitch, Filename);
            R->Context->Unmap(Staging, 0);
        }

        Staging->Release();
        return(Result);
    }

    // With annotations: render to intermediate texture
    ID3D11Texture2D *RenderTexture = CreateRenderTexture(R->Device, (uint32_t)SelWidth, (uint32_t)SelHeight);
    if(!RenderTexture) return(0);

    ID3D11RenderTargetView *RTV = 0;
    if(FAILED(R->Device->CreateRenderTargetView(RenderTexture, 0, &RTV))) {
        RenderTexture->Release();
        return(0);
    }

    // Copy desktop region first
    D3D11_BOX SrcBox = {};
    SrcBox.left = (UINT)LocalLeft;
    SrcBox.top = (UINT)LocalTop;
    SrcBox.front = 0;
    SrcBox.right = (UINT)(LocalLeft + SelWidth);
    SrcBox.bottom = (UINT)(LocalTop + SelHeight);
    SrcBox.back = 1;

    R->Context->CopySubresourceRegion(RenderTexture, 0, 0, 0, 0, Mon->Texture, 0, &SrcBox);

    // Render annotations on top
    R->Context->OMSetRenderTargets(1, &RTV, 0);
    
    D3D11_VIEWPORT Viewport = {};
    Viewport.Width = (float)SelWidth;
    Viewport.Height = (float)SelHeight;
    Viewport.MaxDepth = 1.0f;
    R->Context->RSSetViewports(1, &Viewport);
    
    RenderAnnotationLines(R, S, -Selection.left, -Selection.top, SelWidth, SelHeight);
    
    RTV->Release();

    // Copy to staging
    ID3D11Texture2D *Staging = CreateStagingTexture(R->Device, (uint32_t)SelWidth, (uint32_t)SelHeight);
    if(!Staging) {
        RenderTexture->Release();
        return(0);
    }

    R->Context->CopyResource(Staging, RenderTexture);
    RenderTexture->Release();

    D3D11_MAPPED_SUBRESOURCE Mapped;
    HRESULT hr = R->Context->Map(Staging, 0, D3D11_MAP_READ, 0, &Mapped);

    int Result = 0;
    if(SUCCEEDED(hr)) {
        Result = SavePixelsToFile(Mapped.pData, (uint32_t)SelWidth, (uint32_t)SelHeight, Mapped.RowPitch, Filename);
        R->Context->Unmap(Staging, 0);
    }

    Staging->Release();
    return(Result);
}

