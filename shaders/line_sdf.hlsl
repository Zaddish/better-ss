StructuredBuffer<float2> Points : register(t0);

cbuffer SdfConstants : register(b0)
{
    float2 ScreenSize;
    float  Radius;
    float  PointCount;
    float4 Color;
};

float DistToSegment(float2 P, float2 A, float2 B)
{
    float2 AB = B - A;
    float  Len2 = dot(AB, AB);
    float  T = (Len2 > 0.0001) ? saturate(dot(P - A, AB) / Len2) : 0.0;
    return length(P - (A + AB * T));
}

float4 PSMain(float4 Pos : SV_POSITION) : SV_TARGET
{
    float2 Pixel = Pos.xy;
    int Count = (int)PointCount;
    float D = 1e10;

    if (Count == 1) {
        D = length(Pixel - Points[0]);
    } else {
        for (int I = 0; I < Count - 1; I++)
            D = min(D, DistToSegment(Pixel, Points[I], Points[I + 1]));
    }

    float A = Color.a * (1.0 - smoothstep(Radius - 1.0, Radius, D));
    if (A < 0.004) discard;
    return float4(Color.rgb, A);
}
