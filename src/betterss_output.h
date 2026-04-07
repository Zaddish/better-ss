#pragma once

struct ID3D11Texture2D;

enum output_pixels_source_kind
{
    OutputPixelsSource_None,
    OutputPixelsSource_D3DStaging,
};

struct output_pixels
{

    void *Data;
    uint32_t Width;
    uint32_t Height;
    uint32_t Pitch;

    output_pixels_source_kind SourceKind;
    ID3D11Texture2D *Staging;
    betterss_renderer *Renderer;
};

static output_pixels AcquireSelectionPixels(betterss_renderer *R, RECT Selection, selection_state *S);
static void ReleaseOutputPixels(output_pixels *P);

static int WritePixelsToClipboard(output_pixels Pixels);
static int WritePixelsToFile(IWICImagingFactory *WICFactory, output_pixels Pixels, const wchar_t *Filename);


