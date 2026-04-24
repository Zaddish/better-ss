struct VS_Input {
    float2 Position : POSITION;
    float4 Color    : COLOR;
};

struct PS_Input {
    float4 Position : SV_POSITION;
    float4 Color    : COLOR;
};

cbuffer UIConstants : register(b0) {
    float2 ScreenSize;
    float2 Padding;
};

PS_Input VSMain(VS_Input input) {
    PS_Input output;
    float2 ndc;
    ndc.x =  (input.Position.x / ScreenSize.x) * 2.0 - 1.0;
    ndc.y = -(input.Position.y / ScreenSize.y) * 2.0 + 1.0;
    output.Position = float4(ndc, 0.0, 1.0);
    output.Color    = input.Color;
    return output;
}

float4 PSMain(PS_Input input) : SV_Target {
    return input.Color;
}
