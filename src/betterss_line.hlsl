/* BetterSS Line Annotation Shader */

struct LineVertex
{
    float2 Position : POSITION;
};

cbuffer LineConstants : register(b0)
{
    float2 ScreenSize;
    float LineWidth;
    float _Padding;
    float4 LineColor;
};

struct VS_OUTPUT
{
    float4 Position : SV_POSITION;
    float4 Color : COLOR0;
};

VS_OUTPUT VSMain(LineVertex Input)
{
    VS_OUTPUT Output;
    
    float2 NormalizedPos;
    NormalizedPos.x = (Input.Position.x / ScreenSize.x) * 2.0f - 1.0f;
    NormalizedPos.y = -((Input.Position.y / ScreenSize.y) * 2.0f - 1.0f);
    
    Output.Position = float4(NormalizedPos, 0.0f, 1.0f);
    Output.Color = LineColor;
    
    return Output;
}

float4 PSMain(VS_OUTPUT Input) : SV_TARGET
{
    return Input.Color;
}
