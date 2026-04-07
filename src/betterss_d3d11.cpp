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

static void UpdateConstantBuffer(ID3D11DeviceContext *Ctx, ID3D11Buffer *Buffer, void *Data, size_t Size) {
    D3D11_MAPPED_SUBRESOURCE Mapped;
    if(SUCCEEDED(Ctx->Map(Buffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &Mapped))) {
        memcpy(Mapped.pData, Data, Size);
        Ctx->Unmap(Buffer, 0);
    }
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
            SwapChainDesc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
            SwapChainDesc.Scaling = DXGI_SCALING_NONE;
            SwapChainDesc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
            SwapChainDesc.Flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

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
        DXGI_FORMAT_UNKNOWN, DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
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

    if(Renderer->NoCullState) Renderer->NoCullState->Release();
    if(Renderer->CompositeShader) Renderer->CompositeShader->Release();
    if(Renderer->CompositeConstantBuffer) Renderer->CompositeConstantBuffer->Release();
    if(Renderer->HighlightTexture.SRV) Renderer->HighlightTexture.SRV->Release();
    if(Renderer->HighlightTexture.RTV) Renderer->HighlightTexture.RTV->Release();
    if(Renderer->HighlightTexture.Texture) Renderer->HighlightTexture.Texture->Release();
    if(Renderer->SceneCopy.SRV) Renderer->SceneCopy.SRV->Release();
    if(Renderer->SceneCopy.Texture) Renderer->SceneCopy.Texture->Release();
    if(Renderer->CachedBackground.SRV) Renderer->CachedBackground.SRV->Release();
    if(Renderer->CachedBackground.RTV) Renderer->CachedBackground.RTV->Release();
    if(Renderer->CachedBackground.Texture) Renderer->CachedBackground.Texture->Release();

    for EachCount(i, MODE_LABEL_COUNT) ReleaseModeLabel(&Renderer->ModeLabels[i]);
    if(Renderer->AlphaBlend) Renderer->AlphaBlend->Release();

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
    HRESULT hr = Renderer->SwapChain->Present(0, 0);

    if((hr == DXGI_ERROR_DEVICE_RESET) || (hr == DXGI_ERROR_DEVICE_REMOVED)) {
        HRESULT Reason = Renderer->Device->GetDeviceRemovedReason();
        (void)Reason;
        OutputDebugStringA("D3D11: device removed during Present\n");
        ReleaseRenderer(Renderer);
        return(0);
    }

    return(1);
}

static void InitializeLineRenderer(betterss_renderer *Renderer, 
                                    const BYTE *LineVSBytes, SIZE_T LineVSSize,
                                    const BYTE *LinePSBytes, SIZE_T LinePSSize,
                                    const BYTE *CompositePSBytes, SIZE_T CompositePSSize) {
    if(!Renderer->Device) return;
    
    Renderer->Device->CreateVertexShader(LineVSBytes, LineVSSize, 0, &Renderer->LineVertexShader);
    Renderer->Device->CreatePixelShader(LinePSBytes, LinePSSize, 0, &Renderer->LinePixelShader);
    Renderer->Device->CreatePixelShader(CompositePSBytes, CompositePSSize, 0, &Renderer->CompositeShader);
    
    D3D11_INPUT_ELEMENT_DESC InputDesc[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0}
    };
    
    Renderer->Device->CreateInputLayout(InputDesc, ArrayCount(InputDesc), 
        LineVSBytes, LineVSSize, &Renderer->LineInputLayout);
    
    CreateDynamicBuffer(Renderer->Device, &Renderer->LineConstantBuffer, 
        sizeof(line_const_buffer), D3D11_BIND_CONSTANT_BUFFER);

    CreateDynamicBuffer(Renderer->Device, &Renderer->CompositeConstantBuffer,
        sizeof(composite_const_buffer), D3D11_BIND_CONSTANT_BUFFER);
    
    Renderer->LineVertexBufferCapacity = 4096;
    CreateDynamicBuffer(Renderer->Device, &Renderer->LineVertexBuffer, 
        Renderer->LineVertexBufferCapacity * sizeof(line_vertex), D3D11_BIND_VERTEX_BUFFER);

    D3D11_RASTERIZER_DESC RasterDesc = {};
    RasterDesc.FillMode = D3D11_FILL_SOLID;
    RasterDesc.CullMode = D3D11_CULL_NONE;
    RasterDesc.DepthClipEnable = TRUE;
    Renderer->Device->CreateRasterizerState(&RasterDesc, &Renderer->NoCullState);
}

static ID3D11Texture2D *GetCachedTexture(betterss_renderer *R, betterss_renderer::cached_texture *Cache,
                                          uint32_t Width, uint32_t Height,
                                          D3D11_USAGE Usage, UINT BindFlags, UINT CPUAccess) {
    if(Cache->Texture && Cache->Width >= Width && Cache->Height >= Height) {
        return Cache->Texture;
    }

    if(Cache->RTV) { Cache->RTV->Release(); Cache->RTV = 0; }
    if(Cache->SRV) { Cache->SRV->Release(); Cache->SRV = 0; }
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
        if(BindFlags & D3D11_BIND_SHADER_RESOURCE) {
            R->Device->CreateShaderResourceView(Cache->Texture, 0, &Cache->SRV);
        }
        Cache->Width = Width;
        Cache->Height = Height;
    }

    return Cache->Texture;
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

static void EmitLineSegments(line_vertex *Vertices, int *VertexIndex,
                              annotation_entry *Entry, int OffsetX, int OffsetY, float LineWidth) {
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

        int VI = *VertexIndex;
        Vertices[VI].Position[0] = X0 + PerpX; Vertices[VI].Position[1] = Y0 + PerpY; VI++;
        Vertices[VI].Position[0] = X0 - PerpX; Vertices[VI].Position[1] = Y0 - PerpY; VI++;
        Vertices[VI].Position[0] = X1 + PerpX; Vertices[VI].Position[1] = Y1 + PerpY; VI++;
        Vertices[VI].Position[0] = X1 + PerpX; Vertices[VI].Position[1] = Y1 + PerpY; VI++;
        Vertices[VI].Position[0] = X0 - PerpX; Vertices[VI].Position[1] = Y0 - PerpY; VI++;
        Vertices[VI].Position[0] = X1 - PerpX; Vertices[VI].Position[1] = Y1 - PerpY; VI++;
        *VertexIndex = VI;
    }
}

static void EmitHighlightSegments(line_vertex *Vertices, int *VertexIndex,
                                   annotation_entry *Entry, int OffsetX, int OffsetY, float HalfHeight) {
    float Smooth = 0.3f;

    for(int j = 0; j < Entry->PointCount - 1; j++) {
        float RawX0 = (float)(Entry->Points[j].X + OffsetX);
        float RawY0 = (float)(Entry->Points[j].Y + OffsetY);
        float RawX1 = (float)(Entry->Points[j + 1].X + OffsetX);
        float RawY1 = (float)(Entry->Points[j + 1].Y + OffsetY);

        float X0, Y0, X1, Y1;
        if(j > 0) {
            float PrevX = (float)(Entry->Points[j - 1].X + OffsetX);
            float PrevY = (float)(Entry->Points[j - 1].Y + OffsetY);
            X0 = RawX0 + Smooth * (PrevX - RawX0);
            Y0 = RawY0 + Smooth * (PrevY - RawY0);
        } else {
            X0 = RawX0;
            Y0 = RawY0;
        }
        if(j < Entry->PointCount - 2) {
            float NextX = (float)(Entry->Points[j + 2].X + OffsetX);
            float NextY = (float)(Entry->Points[j + 2].Y + OffsetY);
            X1 = RawX1 + Smooth * (NextX - RawX1);
            Y1 = RawY1 + Smooth * (NextY - RawY1);
        } else {
            X1 = RawX1;
            Y1 = RawY1;
        }

        float DX = X1 - X0;
        float DY = Y1 - Y0;
        float Len = FastSqrt(DX * DX + DY * DY);
        if(Len < 0.001f) continue;

        float PerpX = -DY / Len * HalfHeight;
        float PerpY =  DX / Len * HalfHeight;

        int VI = *VertexIndex;
        Vertices[VI].Position[0] = X0 + PerpX; Vertices[VI].Position[1] = Y0 + PerpY; VI++;
        Vertices[VI].Position[0] = X1 + PerpX; Vertices[VI].Position[1] = Y1 + PerpY; VI++;
        Vertices[VI].Position[0] = X0 - PerpX; Vertices[VI].Position[1] = Y0 - PerpY; VI++;
        Vertices[VI].Position[0] = X0 - PerpX; Vertices[VI].Position[1] = Y0 - PerpY; VI++;
        Vertices[VI].Position[0] = X1 + PerpX; Vertices[VI].Position[1] = Y1 + PerpY; VI++;
        Vertices[VI].Position[0] = X1 - PerpX; Vertices[VI].Position[1] = Y1 - PerpY; VI++;
        *VertexIndex = VI;
    }
}

static void UpdateLineConstants(betterss_renderer *R, int TargetWidth, int TargetHeight,
                                 float ColorR, float ColorG, float ColorB, float ColorA) {
    line_const_buffer Constants = {};
    Constants.ScreenSize[0] = (float)TargetWidth;
    Constants.ScreenSize[1] = (float)TargetHeight;
    Constants.LineColor[0] = ColorR;
    Constants.LineColor[1] = ColorG;
    Constants.LineColor[2] = ColorB;
    Constants.LineColor[3] = ColorA;

    UpdateConstantBuffer(R->Context, R->LineConstantBuffer, &Constants, sizeof(Constants));
}

static void RenderAnnotations(betterss_renderer *R, selection_state *Selection, 
                               int OffsetX, int OffsetY, int TargetWidth, int TargetHeight) {
    if(!R->LineVertexShader || !R->LinePixelShader || !R->LineInputLayout) return;
    if(!Selection || !Selection->Annotations) return;
    if(Selection->AnnotationCount == 0) return;

    float LineWidth = 2.0f;
    float HighlightHalfH = 20.0f;

    int MaxVertices = 0;
    for EachCount(i, Selection->AnnotationCount) {
        annotation_entry *Entry = &Selection->Annotations[i];
        if((Entry->Type == ANNOTATION_LINE || Entry->Type == ANNOTATION_HIGHLIGHT) && Entry->Points && Entry->PointCount > 1)
            MaxVertices += (Entry->PointCount - 1) * 6;
        else if(Entry->Type == ANNOTATION_RECT)
            MaxVertices += 6;
    }
    if(MaxVertices == 0) return;

    if(MaxVertices > (int)R->LineVertexBufferCapacity) {
        if(R->LineVertexBuffer) {
            R->LineVertexBuffer->Release();
            R->LineVertexBuffer = 0;
        }
        R->LineVertexBufferCapacity = MaxVertices * 2;
        CreateDynamicBuffer(R->Device, &R->LineVertexBuffer, 
            R->LineVertexBufferCapacity * sizeof(line_vertex), D3D11_BIND_VERTEX_BUFFER);
    }
    if(!R->LineVertexBuffer) return;

    D3D11_MAPPED_SUBRESOURCE Mapped;
    if(!SUCCEEDED(R->Context->Map(R->LineVertexBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &Mapped))) return;

    line_vertex *Vertices = (line_vertex *)Mapped.pData;
    int VertexIndex = 0;

    for EachCount(i, Selection->AnnotationCount) {
        annotation_entry *Entry = &Selection->Annotations[i];
        if(Entry->Type == ANNOTATION_LINE) {
            if(!Entry->Points || Entry->PointCount <= 1) continue;
            EmitLineSegments(Vertices, &VertexIndex, Entry, OffsetX, OffsetY, LineWidth);
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
    int OpaqueCount = VertexIndex;

    for EachCount(i, Selection->AnnotationCount) {
        annotation_entry *Entry = &Selection->Annotations[i];
        if(Entry->Type == ANNOTATION_HIGHLIGHT) {
            if(!Entry->Points || Entry->PointCount <= 1) continue;
            EmitHighlightSegments(Vertices, &VertexIndex, Entry, OffsetX, OffsetY, HighlightHalfH);
        }
    }
    int HighlightCount = VertexIndex - OpaqueCount;

    R->Context->Unmap(R->LineVertexBuffer, 0);

    UINT Stride = sizeof(line_vertex);
    UINT VBOffset = 0;
    R->Context->IASetVertexBuffers(0, 1, &R->LineVertexBuffer, &Stride, &VBOffset);
    R->Context->IASetInputLayout(R->LineInputLayout);
    R->Context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    R->Context->VSSetShader(R->LineVertexShader, 0, 0);
    R->Context->PSSetShader(R->LinePixelShader, 0, 0);
    R->Context->VSSetConstantBuffers(0, 1, &R->LineConstantBuffer);
    R->Context->PSSetConstantBuffers(0, 1, &R->LineConstantBuffer);

    if(R->NoCullState) R->Context->RSSetState(R->NoCullState);

    if(OpaqueCount > 0) {
        UpdateLineConstants(R, TargetWidth, TargetHeight, 1.0f, 0.0f, 0.0f, 1.0f);
        R->Context->Draw(OpaqueCount, 0);
    }

    if(HighlightCount > 0 && R->CompositeShader) {
        ID3D11RenderTargetView *PrevRTV = 0;
        R->Context->OMGetRenderTargets(1, &PrevRTV, 0);

        GetCachedTexture(R, &R->HighlightTexture, (uint32_t)TargetWidth, (uint32_t)TargetHeight,
            D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE, 0);

        if(R->HighlightTexture.RTV && R->HighlightTexture.SRV) {
            float ClearColor[4] = {1.0f, 1.0f, 1.0f, 1.0f};
            R->Context->ClearRenderTargetView(R->HighlightTexture.RTV, ClearColor);
            R->Context->OMSetRenderTargets(1, &R->HighlightTexture.RTV, 0);

            UpdateLineConstants(R, TargetWidth, TargetHeight, 1.0f, 0.95f, 0.4f, 1.0f);
            R->Context->Draw(HighlightCount, OpaqueCount);

            R->Context->OMSetRenderTargets(1, &PrevRTV, 0);

            // copy current RT so the composite shader can read the scene
            GetCachedTexture(R, &R->SceneCopy, (uint32_t)TargetWidth, (uint32_t)TargetHeight,
                D3D11_USAGE_DEFAULT, D3D11_BIND_SHADER_RESOURCE, 0);

            if(R->SceneCopy.Texture && R->SceneCopy.SRV) {
                ID3D11Resource *RTResource = 0;
                PrevRTV->GetResource(&RTResource);
                if(RTResource) {
                    D3D11_BOX CopyBox = {};
                    CopyBox.right = (UINT)TargetWidth;
                    CopyBox.bottom = (UINT)TargetHeight;
                    CopyBox.back = 1;
                    R->Context->CopySubresourceRegion(R->SceneCopy.Texture, 0, 0, 0, 0, RTResource, 0, &CopyBox);
                    RTResource->Release();
                }

                composite_const_buffer CompConstants = {};
                CompConstants.UVScale[0] = (float)TargetWidth / (float)R->HighlightTexture.Width;
                CompConstants.UVScale[1] = (float)TargetHeight / (float)R->HighlightTexture.Height;
                UpdateConstantBuffer(R->Context, R->CompositeConstantBuffer, &CompConstants, sizeof(CompConstants));

                R->Context->IASetInputLayout(0);
                R->Context->VSSetShader(R->VertexShader, 0, 0);
                R->Context->PSSetShader(R->CompositeShader, 0, 0);
                ID3D11ShaderResourceView *SRVs[2] = {R->SceneCopy.SRV, R->HighlightTexture.SRV};
                R->Context->PSSetShaderResources(0, 2, SRVs);
                R->Context->PSSetSamplers(0, 1, &R->Sampler);
                R->Context->PSSetConstantBuffers(0, 1, &R->CompositeConstantBuffer);

                R->Context->Draw(3, 0);

                ID3D11ShaderResourceView *NullSRVs[2] = {};
                R->Context->PSSetShaderResources(0, 2, NullSRVs);
            }
        }

        if(PrevRTV) PrevRTV->Release();
    }

    R->Context->RSSetState(0);
}

static mode_label BakeModeLabel(ID3D11Device *Device, const wchar_t *Text, int FontHeight) {
    mode_label Result = {};
    if(!Device) return Result;

    HDC Dc = CreateCompatibleDC(0);
    if(!Dc) return Result;

    HFONT Font = CreateFontW(-FontHeight, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
        DEFAULT_PITCH, L"Segoe UI");
    HFONT OldFont = (HFONT)SelectObject(Dc, Font);

    SIZE TextSize;
    int Len = 0;
    for(const wchar_t *P = Text; *P; P++) Len++;
    GetTextExtentPoint32W(Dc, Text, Len, &TextSize);

    int TexW = TextSize.cx;
    int TexH = TextSize.cy;
    if(TexW <= 0 || TexH <= 0) {
        SelectObject(Dc, OldFont);
        DeleteObject(Font);
        DeleteDC(Dc);
        return Result;
    }

    BITMAPINFO Bmi = {};
    Bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    Bmi.bmiHeader.biWidth = TexW;
    Bmi.bmiHeader.biHeight = -TexH;
    Bmi.bmiHeader.biPlanes = 1;
    Bmi.bmiHeader.biBitCount = 32;
    Bmi.bmiHeader.biCompression = BI_RGB;

    uint32_t *Bits = 0;
    HBITMAP Bitmap = CreateDIBSection(Dc, &Bmi, DIB_RGB_COLORS, (void **)&Bits, 0, 0);
    if(!Bitmap || !Bits) {
        SelectObject(Dc, OldFont);
        DeleteObject(Font);
        DeleteDC(Dc);
        return Result;
    }

    HBITMAP OldBitmap = (HBITMAP)SelectObject(Dc, Bitmap);
    SetTextColor(Dc, RGB(255, 255, 255));
    SetBkMode(Dc, TRANSPARENT);

    RECT DrawRect = {0, 0, TexW, TexH};
    DrawTextW(Dc, Text, Len, &DrawRect, DT_LEFT | DT_TOP | DT_NOCLIP);
    GdiFlush();

    for(int i = 0; i < TexW * TexH; i++) {
        uint32_t Pixel = Bits[i];
        uint8_t R = (uint8_t)(Pixel & 0xFF);
        uint8_t G = (uint8_t)((Pixel >> 8) & 0xFF);
        uint8_t B = (uint8_t)((Pixel >> 16) & 0xFF);
        uint8_t A = (R > G) ? ((R > B) ? R : B) : ((G > B) ? G : B);
        Bits[i] = (A << 24) | (A << 16) | (A << 8) | A;
    }

    D3D11_TEXTURE2D_DESC TexDesc = {};
    TexDesc.Width = (UINT)TexW;
    TexDesc.Height = (UINT)TexH;
    TexDesc.MipLevels = 1;
    TexDesc.ArraySize = 1;
    TexDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    TexDesc.SampleDesc.Count = 1;
    TexDesc.Usage = D3D11_USAGE_IMMUTABLE;
    TexDesc.BindFlags = D3D11_BIND_SHADER_RESOURCE;

    D3D11_SUBRESOURCE_DATA InitData = {};
    InitData.pSysMem = Bits;
    InitData.SysMemPitch = (UINT)(TexW * 4);

    Device->CreateTexture2D(&TexDesc, &InitData, &Result.Texture);
    if(Result.Texture) {
        Device->CreateShaderResourceView(Result.Texture, 0, &Result.SRV);
        Result.Width = TexW;
        Result.Height = TexH;
    }

    SelectObject(Dc, OldBitmap);
    SelectObject(Dc, OldFont);
    DeleteObject(Bitmap);
    DeleteObject(Font);
    DeleteDC(Dc);
    return Result;
}

static void ReleaseModeLabel(mode_label *Label) {
    if(Label->SRV) Label->SRV->Release();
    if(Label->Texture) Label->Texture->Release();
    *Label = {};
}

static void RenderModeLabel(betterss_renderer *R, mode_label *Label, int CursorX, int CursorY,
                            int ScreenWidth, int ScreenHeight) {
    if(!Label->SRV || !R->VertexShader || !R->OverlayShader || !R->AlphaBlend) return;

    int OffX = Label->Height;
    int OffY = -(Label->Height * 3 / 2);
    int QX = CursorX + OffX;
    int QY = CursorY + OffY;
    if(QX + Label->Width > ScreenWidth) QX = ScreenWidth - Label->Width;
    if(QY < 0) QY = CursorY + Label->Height / 2;
    if(QX < 0) QX = 0;

    D3D11_VIEWPORT Viewport = {};
    Viewport.TopLeftX = (float)QX;
    Viewport.TopLeftY = (float)QY;
    Viewport.Width = (float)Label->Width;
    Viewport.Height = (float)Label->Height;
    Viewport.MaxDepth = 1.0f;
    R->Context->RSSetViewports(1, &Viewport);

    overlay_const_buffer Constants = {};
    Constants.DimFactor = 1.0f;
    Constants.TexelSize[0] = 1.0f / (float)Label->Width;
    Constants.TexelSize[1] = 1.0f / (float)Label->Height;
    UpdateConstantBuffer(R->Context, R->ConstantBuffer, &Constants, sizeof(Constants));

    R->Context->IASetInputLayout(0);
    R->Context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    R->Context->VSSetShader(R->VertexShader, 0, 0);
    R->Context->PSSetShader(R->OverlayShader, 0, 0);
    R->Context->PSSetConstantBuffers(0, 1, &R->ConstantBuffer);
    R->Context->PSSetSamplers(0, 1, &R->Sampler);
    R->Context->PSSetShaderResources(0, 1, &Label->SRV);

    float BlendFactor[4] = {};
    R->Context->OMSetBlendState(R->AlphaBlend, BlendFactor, 0xFFFFFFFF);

    R->Context->Draw(3, 0);

    R->Context->OMSetBlendState(0, BlendFactor, 0xFFFFFFFF);

    ID3D11ShaderResourceView *NullSRV = 0;
    R->Context->PSSetShaderResources(0, 1, &NullSRV);
}
