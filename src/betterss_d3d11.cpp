#pragma comment (lib, "d3d11.lib")
#pragma comment (lib, "dxgi.lib")
#pragma comment (lib, "dxguid.lib")

#include <xmmintrin.h>

static float FastSqrt(float X) {
    float Result;
    _mm_store_ss(&Result, _mm_sqrt_ss(_mm_set_ss(X)));
    return Result;
}

static void CreateDynamicBuffer(ID3D11Device *Device, ID3D11Buffer **Out, UINT ByteWidth, UINT BindFlags) {
    D3D11_BUFFER_DESC Desc = {};
    Desc.ByteWidth = ByteWidth;
    Desc.Usage = D3D11_USAGE_DYNAMIC;
    Desc.BindFlags = BindFlags;
    Desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    Device->CreateBuffer(&Desc, 0, Out);
}

static int RendererIsValid(betterss_renderer *Renderer) {
    int Result = (Renderer->Device &&
                  Renderer->SwapChain &&
                  Renderer->RenderTarget);
    return(Result);
}

static IDXGIFactory2 *AcquireDXGIFactory(ID3D11Device *Device) {
    IDXGIFactory2 *Result = 0;

    if(Device) {
        IDXGIDevice *DxgiDevice = 0;
        if(SUCCEEDED(Device->QueryInterface(IID_PPV_ARGS(&DxgiDevice)))) {
            IDXGIAdapter *DxgiAdapter = 0;
            if(SUCCEEDED(DxgiDevice->GetAdapter(&DxgiAdapter))) {
                DxgiAdapter->GetParent(IID_PPV_ARGS(&Result));
                DxgiAdapter->Release();
            }
            DxgiDevice->Release();
        }
    }

    return(Result);
}

static IDXGISwapChain2 *AcquireSwapChain(ID3D11Device *Device, HWND Window) {
    IDXGISwapChain2 *Result = 0;

    if(Device) {
        IDXGIFactory2 *DxgiFactory = AcquireDXGIFactory(Device);
        if(DxgiFactory) {
            DXGI_SWAP_CHAIN_DESC1 SwapChainDesc = {};
            SwapChainDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
            SwapChainDesc.SampleDesc.Count = 1;
            SwapChainDesc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
            SwapChainDesc.BufferCount = 2;
            SwapChainDesc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
            SwapChainDesc.Scaling = DXGI_SCALING_NONE;
            SwapChainDesc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
            SwapChainDesc.Flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT | 
                                  DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING;

            IDXGISwapChain1 *SwapChain1 = 0;
            if(SUCCEEDED(DxgiFactory->CreateSwapChainForHwnd(Device, Window, &SwapChainDesc, 0, 0, &SwapChain1))) {
                if(SUCCEEDED(SwapChain1->QueryInterface(IID_PPV_ARGS(&Result)))) {
                    DxgiFactory->MakeWindowAssociation(Window, DXGI_MWA_NO_ALT_ENTER | DXGI_MWA_NO_WINDOW_CHANGES);
                }
                SwapChain1->Release();
            }
            DxgiFactory->Release();
        }
    }

    return(Result);
}

static void ReleaseRenderTarget(betterss_renderer *Renderer) {
    if(Renderer->RenderTarget) {
        Renderer->RenderTarget->Release();
        Renderer->RenderTarget = 0;
    }
}

static void RendererResize(betterss_renderer *Renderer, uint32_t Width, uint32_t Height) {
    if(Width == 0 || Height == 0) return;
    if(Width == Renderer->Width && Height == Renderer->Height) return;

    Renderer->Context->ClearState();
    ReleaseRenderTarget(Renderer);
    Renderer->Context->Flush();

    HRESULT hr = Renderer->SwapChain->ResizeBuffers(0, Width, Height, 
        DXGI_FORMAT_UNKNOWN, 
        DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT | DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING);
    if(FAILED(hr)) {
        ReleaseRenderer(Renderer);
        return;
    }

    ID3D11Texture2D *BackBuffer = 0;
    hr = Renderer->SwapChain->GetBuffer(0, IID_PPV_ARGS(&BackBuffer));
    if(FAILED(hr)) {
        ReleaseRenderer(Renderer);
        return;
    }

    hr = Renderer->Device->CreateRenderTargetView(BackBuffer, 0, &Renderer->RenderTarget);
    BackBuffer->Release();
    if(FAILED(hr)) {
        ReleaseRenderer(Renderer);
        return;
    }

    Renderer->Width = Width;
    Renderer->Height = Height;
}

static void ReleaseRenderer(betterss_renderer *Renderer) {
    ReleaseRenderTarget(Renderer);

    if(Renderer->Sampler) Renderer->Sampler->Release();
    if(Renderer->ConstantBuffer) Renderer->ConstantBuffer->Release();
    if(Renderer->VertexShader) Renderer->VertexShader->Release();
    if(Renderer->OverlayShader) Renderer->OverlayShader->Release();
    if(Renderer->LineVertexShader) Renderer->LineVertexShader->Release();
    if(Renderer->LinePixelShader) Renderer->LinePixelShader->Release();
    if(Renderer->LineConstantBuffer) Renderer->LineConstantBuffer->Release();
    if(Renderer->LineVertexBuffer) Renderer->LineVertexBuffer->Release();
    if(Renderer->LineInputLayout) Renderer->LineInputLayout->Release();
    
    if(Renderer->CachedRender.RTV) Renderer->CachedRender.RTV->Release();
    if(Renderer->CachedRender.Texture) Renderer->CachedRender.Texture->Release();
    if(Renderer->CachedStaging.Texture) Renderer->CachedStaging.Texture->Release();
    
    if(Renderer->SwapChain) Renderer->SwapChain->Release();
    if(Renderer->Context1) Renderer->Context1->Release();
    if(Renderer->Context) Renderer->Context->Release();
    if(Renderer->Device) Renderer->Device->Release();

    *Renderer = {};
}

static betterss_renderer AcquireRenderer(HWND Window) {
    betterss_renderer Result = {};

    UINT Flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_SINGLETHREADED;

    D3D_FEATURE_LEVEL Levels[] = {D3D_FEATURE_LEVEL_11_0};
    HRESULT hr = D3D11CreateDevice(0, D3D_DRIVER_TYPE_HARDWARE, 0, Flags, Levels, ArrayCount(Levels), 
        D3D11_SDK_VERSION, &Result.Device, 0, &Result.Context);

    if(FAILED(hr)) {
        hr = D3D11CreateDevice(0, D3D_DRIVER_TYPE_WARP, 0, Flags, Levels, ArrayCount(Levels), 
            D3D11_SDK_VERSION, &Result.Device, 0, &Result.Context);
    }

    if(SUCCEEDED(hr)) {
        if(SUCCEEDED(Result.Context->QueryInterface(IID_PPV_ARGS(&Result.Context1)))) {
            Result.SwapChain = AcquireSwapChain(Result.Device, Window);
            if(Result.SwapChain) {
                CreateDynamicBuffer(Result.Device, &Result.ConstantBuffer, 
                    sizeof(overlay_const_buffer), D3D11_BIND_CONSTANT_BUFFER);

                D3D11_SAMPLER_DESC SamplerDesc = {};
                SamplerDesc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
                SamplerDesc.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
                SamplerDesc.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
                SamplerDesc.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
                Result.Device->CreateSamplerState(&SamplerDesc, &Result.Sampler);

                RECT ClientRect;
                GetClientRect(Window, &ClientRect);
                RendererResize(&Result, ClientRect.right, ClientRect.bottom);
            }
        }
    }

    if(!RendererIsValid(&Result)) {
        ReleaseRenderer(&Result);
    }

    return(Result);
}

static int RendererPresent(betterss_renderer *Renderer) {
    HRESULT hr = Renderer->SwapChain->Present(0, DXGI_PRESENT_ALLOW_TEARING);

    if((hr == DXGI_ERROR_DEVICE_RESET) || (hr == DXGI_ERROR_DEVICE_REMOVED)) {
        HRESULT Reason = Renderer->Device->GetDeviceRemovedReason();
        (void)Reason;
        OutputDebugStringA("D3D11: device removed during Present\n");
        ReleaseRenderer(Renderer);
        return(0);
    }

    if(Renderer->RenderTarget) {
        Renderer->Context1->DiscardView(Renderer->RenderTarget);
    }
    
    return(1);
}

static void InitializeLineRenderer(betterss_renderer *Renderer, 
                                    const BYTE *LineVSBytes, SIZE_T LineVSSize,
                                    const BYTE *LinePSBytes, SIZE_T LinePSSize) {
    if(!Renderer->Device) return;
    
    Renderer->Device->CreateVertexShader(LineVSBytes, LineVSSize, 0, &Renderer->LineVertexShader);
    Renderer->Device->CreatePixelShader(LinePSBytes, LinePSSize, 0, &Renderer->LinePixelShader);
    
    D3D11_INPUT_ELEMENT_DESC InputDesc[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0}
    };
    
    Renderer->Device->CreateInputLayout(InputDesc, ArrayCount(InputDesc), 
        LineVSBytes, LineVSSize, &Renderer->LineInputLayout);
    
    CreateDynamicBuffer(Renderer->Device, &Renderer->LineConstantBuffer, 
        sizeof(line_const_buffer), D3D11_BIND_CONSTANT_BUFFER);
    
    Renderer->LineVertexBufferCapacity = 4096;
    CreateDynamicBuffer(Renderer->Device, &Renderer->LineVertexBuffer, 
        Renderer->LineVertexBufferCapacity * sizeof(line_vertex), D3D11_BIND_VERTEX_BUFFER);
}

static void EmitRectQuad(line_vertex *Vertices, int *VertexIndex,
                         float Left, float Top, float Right, float Bottom) {
    int VI = *VertexIndex;
    Vertices[VI].Position[0] = Left;  Vertices[VI].Position[1] = Top;    VI++;
    Vertices[VI].Position[0] = Right; Vertices[VI].Position[1] = Top;    VI++;
    Vertices[VI].Position[0] = Left;  Vertices[VI].Position[1] = Bottom; VI++;
    Vertices[VI].Position[0] = Right; Vertices[VI].Position[1] = Top;    VI++;
    Vertices[VI].Position[0] = Right; Vertices[VI].Position[1] = Bottom; VI++;
    Vertices[VI].Position[0] = Left;  Vertices[VI].Position[1] = Bottom; VI++;
    *VertexIndex = VI;
}

static void RenderAnnotations(betterss_renderer *R, selection_state *Selection, 
                               int OffsetX, int OffsetY, int TargetWidth, int TargetHeight) {
    if(!R->LineVertexShader || !R->LinePixelShader || !R->LineInputLayout) return;
    if(!Selection || !Selection->Annotations) return;
    
    if(Selection->AnnotationCount == 0) return;
    
    int TotalVertexCount = 0;
    for(int i = 0; i < Selection->AnnotationCount; i++) {
        annotation_entry *Entry = &Selection->Annotations[i];
        if(Entry->Type == ANNOTATION_LINE) {
            if(Entry->Points && Entry->PointCount > 1) {
                TotalVertexCount += (Entry->PointCount - 1) * 6;
            }
        }
        else if(Entry->Type == ANNOTATION_RECT) {
            TotalVertexCount += 6;
        }
    }
    
    if(TotalVertexCount == 0) return;
    
    if(TotalVertexCount > (int)R->LineVertexBufferCapacity) {
        if(R->LineVertexBuffer) {
            R->LineVertexBuffer->Release();
            R->LineVertexBuffer = 0;
        }
        
        R->LineVertexBufferCapacity = TotalVertexCount * 2;
        CreateDynamicBuffer(R->Device, &R->LineVertexBuffer, 
            R->LineVertexBufferCapacity * sizeof(line_vertex), D3D11_BIND_VERTEX_BUFFER);
    }
    
    if(!R->LineVertexBuffer) return;
    
    float LineWidth = 2.0f;
    
    D3D11_MAPPED_SUBRESOURCE Mapped;
    if(SUCCEEDED(R->Context->Map(R->LineVertexBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &Mapped))) {
        line_vertex *Vertices = (line_vertex *)Mapped.pData;
        int VertexIndex = 0;
        
        for(int i = 0; i < Selection->AnnotationCount; i++) {
            annotation_entry *Entry = &Selection->Annotations[i];
            
            if(Entry->Type == ANNOTATION_LINE) {
                if(!Entry->Points || Entry->PointCount <= 1) continue;
                for(int j = 0; j < Entry->PointCount - 1; j++) {
                    float X0 = (float)(Entry->Points[j].X + OffsetX);
                    float Y0 = (float)(Entry->Points[j].Y + OffsetY);
                    float X1 = (float)(Entry->Points[j + 1].X + OffsetX);
                    float Y1 = (float)(Entry->Points[j + 1].Y + OffsetY);
                    
                    float DX = X1 - X0;
                    float DY = Y1 - Y0;
                    float Len = FastSqrt(DX * DX + DY * DY);
                    if(Len < 0.001f) continue;
                    
                    float PerpX = -DY / Len * (LineWidth * 0.5f);
                    float PerpY = DX / Len * (LineWidth * 0.5f);
                    
                    Vertices[VertexIndex].Position[0] = X0 + PerpX;
                    Vertices[VertexIndex].Position[1] = Y0 + PerpY;
                    VertexIndex++;
                    Vertices[VertexIndex].Position[0] = X0 - PerpX;
                    Vertices[VertexIndex].Position[1] = Y0 - PerpY;
                    VertexIndex++;
                    Vertices[VertexIndex].Position[0] = X1 + PerpX;
                    Vertices[VertexIndex].Position[1] = Y1 + PerpY;
                    VertexIndex++;
                    
                    Vertices[VertexIndex].Position[0] = X1 + PerpX;
                    Vertices[VertexIndex].Position[1] = Y1 + PerpY;
                    VertexIndex++;
                    Vertices[VertexIndex].Position[0] = X0 - PerpX;
                    Vertices[VertexIndex].Position[1] = Y0 - PerpY;
                    VertexIndex++;
                    Vertices[VertexIndex].Position[0] = X1 - PerpX;
                    Vertices[VertexIndex].Position[1] = Y1 - PerpY;
                    VertexIndex++;
                }
            }
            else if(Entry->Type == ANNOTATION_RECT) {
                float Left = (float)(Entry->X0 + OffsetX);
                float Top = (float)(Entry->Y0 + OffsetY);
                float Right = (float)(Entry->X1 + OffsetX);
                float Bottom = (float)(Entry->Y1 + OffsetY);
                if(Left > Right) { float T = Left; Left = Right; Right = T; }
                if(Top > Bottom) { float T = Top; Top = Bottom; Bottom = T; }
                EmitRectQuad(Vertices, &VertexIndex, Left, Top, Right, Bottom);
            }
        }
        
        R->Context->Unmap(R->LineVertexBuffer, 0);
        
        line_const_buffer Constants = {};
        Constants.ScreenSize[0] = (float)TargetWidth;
        Constants.ScreenSize[1] = (float)TargetHeight;
        Constants.LineWidth = LineWidth;
        Constants.LineColor[0] = 1.0f;
        Constants.LineColor[1] = 0.0f;
        Constants.LineColor[2] = 0.0f;
        Constants.LineColor[3] = 1.0f;
        
        if(SUCCEEDED(R->Context->Map(R->LineConstantBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &Mapped))) {
            memcpy(Mapped.pData, &Constants, sizeof(Constants));
            R->Context->Unmap(R->LineConstantBuffer, 0);
        }
        
        UINT Stride = sizeof(line_vertex);
        UINT Offset = 0;
        R->Context->IASetVertexBuffers(0, 1, &R->LineVertexBuffer, &Stride, &Offset);
        R->Context->IASetInputLayout(R->LineInputLayout);
        R->Context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        
        R->Context->VSSetShader(R->LineVertexShader, 0, 0);
        R->Context->PSSetShader(R->LinePixelShader, 0, 0);
        R->Context->VSSetConstantBuffers(0, 1, &R->LineConstantBuffer);
        R->Context->PSSetConstantBuffers(0, 1, &R->LineConstantBuffer);
        
        R->Context->Draw(VertexIndex, 0);
    }
}
