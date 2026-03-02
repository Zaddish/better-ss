/* Highlight Commposite Shader */

cbuffer CompositeConstants : register(b0)
{
    float2 UVScale;
};

Texture2D SceneTexture : register(t0);
Texture2D HighlightTexture : register(t1);
SamplerState SourceSampler : register(s0);

struct VS_OUTPUT
{
    float4 Position : SV_POSITION;
    float2 TexCoord : TEXCOORD0;
};

float4 PSMain(VS_OUTPUT Input) : SV_TARGET
{
    float2 UV = Input.TexCoord * UVScale;
    float3 Scene = SceneTexture.Sample(SourceSampler, UV).rgb;
    float3 Highlight = HighlightTexture.Sample(SourceSampler, UV).rgb;

    float Mask = 1.0 - dot(Highlight, float3(0.333, 0.334, 0.333));

    // brighten the scene toward highlight colour so the tint is visible on any background,
    // then multiply it to preserve contrast between light and dark scene pixels.
    float Lum = dot(Scene, float3(0.299, 0.587, 0.114));
    float Lift = (1.0 - Lum) * 0.35;
    float3 Lifted = Scene + Highlight * Lift;
    float3 Blended = Lifted * Highlight;

    float3 Result = lerp(Scene, Blended, saturate(Mask * 4.0));

    return float4(Result, 1.0);
}
