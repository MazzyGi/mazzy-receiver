#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut fullscreen_vertex(uint vid [[vertex_id]]) {
    // triangle strip covering the screen, flipping UV vertically
    const float4 pos[4] = {
        float4(-1, -1, 0, 1), float4(1, -1, 0, 1),
        float4(-1,  1, 0, 1), float4(1,  1, 0, 1)
    };
    VertexOut o;
    o.position = pos[vid];
    o.uv = float2((o.position.x + 1) * 0.5, 1 - (o.position.y + 1) * 0.5);
    return o;
}

fragment float4 yuv_fragment(VertexOut in [[stage_in]],
                             texture2d<float> luma   [[texture(0)]],
                             texture2d<float> chroma [[texture(1)]],
                             sampler s [[sampler(0)]]) {
    float y = luma.sample(s, in.uv).r;
    float2 uv = chroma.sample(s, in.uv).rg - 0.5;
    // BT.709 limited-range -> RGB
    float yy = (y - 16.0 / 255.0) / (219.0 / 255.0);
    float u = uv.x / (224.0 / 255.0);
    float v = uv.y / (224.0 / 255.0);
    float r = yy            + 1.5748 * v;
    float g = yy - 0.1873 * u - 0.4681 * v;
    float b = yy + 1.8556 * u;
    return float4(saturate(r), saturate(g), saturate(b), 1);
}
