// 一段真实可用的 MSL（Metal Shading Language）源码。
// 它不经过 `metal` 编译；App 在运行时用 newLibraryWithSource:options:error: 现场编译。
// 这样在 Windows 上也能交付「带着色器」的 App。
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut v_quad(uint vid [[vertex_id]]) {
    // 覆盖全屏的两个三角形
    float2 pos[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1,  1),
        float2(-1,  1), float2( 1, -1), float2( 1,  1)
    };
    VertexOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.uv = (pos[vid] + 1.0) * 0.5;
    return o;
}

fragment float4 f_gradient(VertexOut in [[stage_in]]) {
    return float4(in.uv, 0.75, 1.0);
}
