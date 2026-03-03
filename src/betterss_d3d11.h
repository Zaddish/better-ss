/* BetterSS - D3D11 Renderer Types */

#pragma once

struct overlay_const_buffer
{
    float SelectionRect[4];
    float DimFactor;
    float TexelSize[2];
    float Rotation;
};

struct line_const_buffer
{
    float ScreenSize[2];
    float LineWidth;
    float Padding;
    float LineColor[4];
};

struct composite_const_buffer
{
    float UVScale[2];
    float Padding[2];
};

struct line_vertex
{
    float Position[2];
};

struct mode_label
{
    ID3D11Texture2D *Texture;
    ID3D11ShaderResourceView *SRV;
    int Width;
    int Height;
};

#define MODE_LABEL_COUNT 3

struct betterss_renderer
{
    ID3D11Device *Device;
    ID3D11DeviceContext *Context;
    ID3D11DeviceContext1 *Context1;
    IDXGISwapChain2 *SwapChain;
    ID3D11RenderTargetView *RenderTarget;
    ID3D11VertexShader *VertexShader;
    ID3D11PixelShader *OverlayShader;
    ID3D11Buffer *ConstantBuffer;
    ID3D11SamplerState *Sampler;
    uint32_t Width;
    uint32_t Height;
    
    // Line rendering
    ID3D11VertexShader *LineVertexShader;
    ID3D11PixelShader *LinePixelShader;
    ID3D11Buffer *LineConstantBuffer;
    ID3D11Buffer *LineVertexBuffer;
    ID3D11InputLayout *LineInputLayout;
    uint32_t LineVertexBufferCapacity;
    struct cached_texture {
        ID3D11Texture2D *Texture;
        ID3D11RenderTargetView *RTV;
        ID3D11ShaderResourceView *SRV;
        uint32_t Width;
        uint32_t Height;
    };

    cached_texture CachedStaging;
    cached_texture CachedRender;

    ID3D11RasterizerState *NoCullState;

    // highlight composite
    ID3D11PixelShader *CompositeShader;
    ID3D11Buffer *CompositeConstantBuffer;
    cached_texture HighlightTexture;
    cached_texture SceneCopy;

    mode_label ModeLabels[MODE_LABEL_COUNT];
    ID3D11BlendState *AlphaBlend;
};

static int RendererIsValid(betterss_renderer *Renderer);
static betterss_renderer AcquireRenderer(HWND Window);
static void ReleaseRenderer(betterss_renderer *Renderer);
static void RendererResize(betterss_renderer *Renderer, uint32_t Width, uint32_t Height);
static int RendererPresent(betterss_renderer *Renderer);
static void RenderAnnotations(betterss_renderer *R, selection_state *Selection,
                               int OffsetX, int OffsetY, int TargetWidth, int TargetHeight);
static ID3D11Texture2D *GetCachedTexture(betterss_renderer *R, betterss_renderer::cached_texture *Cache,
                                          uint32_t Width, uint32_t Height,
                                          D3D11_USAGE Usage, UINT BindFlags, UINT CPUAccess);
static void ComposeMonitorsToRT(betterss_renderer *R, capture_state *C,
                                int OriginX, int OriginY,
                                RECT SelectRect, float DimFactor);
static mode_label BakeModeLabel(ID3D11Device *Device, const wchar_t *Text, int FontHeight);
static void RenderModeLabel(betterss_renderer *R, mode_label *Label, int CursorX, int CursorY,
                            int ScreenWidth, int ScreenHeight);
static void ReleaseModeLabel(mode_label *Label);