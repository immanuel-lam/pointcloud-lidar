//
//  PointCloudShaders.metal
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

#include <metal_stdlib>
using namespace metal;

// Must mirror RendererTypes.swift exactly (memory layout).
struct PointVertex {
    float3 position;
    float4 color;
};

struct Uniforms {
    float4x4 projectionMatrix;
    float4x4 viewMatrix;
    float    pointSize;
    float3   padding;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float  pointSize [[point_size]];
};

vertex VertexOut point_vertex(
    const device PointVertex* vertices [[buffer(0)]],
    constant Uniforms&        uniforms [[buffer(1)]],
    uint                      vid      [[vertex_id]])
{
    VertexOut out;
    float4 worldPos = float4(vertices[vid].position, 1.0);
    out.position  = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    out.color     = vertices[vid].color;
    out.pointSize = uniforms.pointSize;
    return out;
}

fragment float4 point_fragment(
    VertexOut in         [[stage_in]],
    float2    pointCoord [[point_coord]])
{
    // Discard corners to draw a circular dot.
    float dist = length(pointCoord - float2(0.5));
    if (dist > 0.5) discard_fragment();
    return in.color;
}
