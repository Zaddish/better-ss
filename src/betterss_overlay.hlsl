/* BetterSS Overlay Shader */

cbuffer OverlayConstants : register(b0)
{
    float4 SelectionRect;
    float DimFactor;
    float2 TexelSize;
    float Rotation;
};

Texture2D DesktopTexture : register(t0);
SamplerState DesktopSampler : register(s0);

struct VS_OUTPUT
{
    float4 Position : SV_POSITION;
    float2 TexCoord : TEXCOORD0;
};

VS_OUTPUT VSMain(uint VertexID : SV_VertexID)
{
    VS_OUTPUT Output;
    float2 TexCoord = float2((VertexID << 1) & 2, VertexID & 2);
    Output.Position = float4(TexCoord.x * 2.0f - 1.0f, -(TexCoord.y * 2.0f - 1.0f), 0.0f, 1.0f);
    Output.TexCoord = TexCoord;
    return Output;
}

float2 RotateUV(float2 uv, float rot)
{
    if(rot < 1.5f) return uv;
    if(rot < 2.5f) return float2(uv.y, 1.0f - uv.x);
    if(rot < 3.5f) return float2(1.0f - uv.x, 1.0f - uv.y);
    return float2(1.0f - uv.y, uv.x);
}

float4 PSMain(VS_OUTPUT Input) : SV_TARGET
{
    float2 RotatedUV = RotateUV(Input.TexCoord, Rotation);
    float4 Color = DesktopTexture.Sample(DesktopSampler, RotatedUV);

    float2 SelectMin = SelectionRect.xy;
    float2 SelectMax = SelectionRect.xy + SelectionRect.zw;

    int InsideSelection = 0;
    int HasSelection = (SelectionRect.z > 0.001f && SelectionRect.w > 0.001f);
    
    if(HasSelection)
    {
        if(Input.TexCoord.x >= SelectMin.x && Input.TexCoord.x <= SelectMax.x &&
           Input.TexCoord.y >= SelectMin.y && Input.TexCoord.y <= SelectMax.y)
        {
            InsideSelection = 1;
        }
    }

    if(!InsideSelection || !HasSelection)
    {
        Color.rgb *= DimFactor;
    }

    float BorderWidth = 1.0f;
    float BorderWidthX = TexelSize.x * BorderWidth;
    float BorderWidthY = TexelSize.y * BorderWidth;
    
    if(HasSelection)
    {
        float DistLeft = abs(Input.TexCoord.x - SelectMin.x);
        float DistRight = abs(Input.TexCoord.x - SelectMax.x);
        float DistTop = abs(Input.TexCoord.y - SelectMin.y);
        float DistBottom = abs(Input.TexCoord.y - SelectMax.y);
        
        int NearLeft = (DistLeft < BorderWidthX) && (Input.TexCoord.y >= SelectMin.y - BorderWidthY && Input.TexCoord.y <= SelectMax.y + BorderWidthY);
        int NearRight = (DistRight < BorderWidthX) && (Input.TexCoord.y >= SelectMin.y - BorderWidthY && Input.TexCoord.y <= SelectMax.y + BorderWidthY);
        int NearTop = (DistTop < BorderWidthY) && (Input.TexCoord.x >= SelectMin.x - BorderWidthX && Input.TexCoord.x <= SelectMax.x + BorderWidthX);
        int NearBottom = (DistBottom < BorderWidthY) && (Input.TexCoord.x >= SelectMin.x - BorderWidthX && Input.TexCoord.x <= SelectMax.x + BorderWidthX);
        
        if(NearLeft || NearRight || NearTop || NearBottom)
        {
            Color.rgb = float3(1.0f, 1.0f, 1.0f);
        }
    }

    return Color;
}
