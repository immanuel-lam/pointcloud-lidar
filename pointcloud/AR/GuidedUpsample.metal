//
//  GuidedUpsample.metal
//  pointcloud
//
//  Joint bilateral upsampling: for each output pixel at full camera resolution,
//  compute a weighted average of nearby depth samples.
//  Weights = spatial Gaussian × luma-similarity Gaussian.
//
//  Inputs
//    depthTex   — R32Float,  ~256×192 (landscape, ARKit sceneDepth)
//    lumaTex    — R8Unorm,   ~1920×1440 (Y-plane of capturedImage, same landscape)
//    maxDepth   — float, depth value that maps to black (0)
//
//  Output
//    outTex     — BGRA8Unorm, same dimensions as lumaTex
//
//  Both textures are in ARKit landscape orientation and share the same
//  normalised UV space, so a direct UV lookup aligns them correctly.

#include <metal_stdlib>
using namespace metal;

// Tuning parameters
constant int   RADIUS        = 4;     // search window half-size in depth-texture pixels
constant float SIGMA_SPATIAL = 2.0;   // spatial Gaussian std-dev (depth pixels)
constant float SIGMA_LUMA    = 0.1;   // luma Gaussian std-dev (0–1 range)

kernel void guidedUpsampleToBGRA(
    texture2d<float, access::sample>  depthTex [[ texture(0) ]],
    texture2d<float, access::sample>  lumaTex  [[ texture(1) ]],
    texture2d<float, access::write>   outTex   [[ texture(2) ]],
    constant float                   &maxDepth [[ buffer(0)  ]],
    uint2 gid [[ thread_position_in_grid ]]
)
{
    const uint outW = outTex.get_width();
    const uint outH = outTex.get_height();
    if (gid.x >= outW || gid.y >= outH) return;

    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);

    // Normalised UV for this output pixel (centre of texel)
    float2 uv = (float2(gid) + 0.5f) / float2(outW, outH);

    // Sample query luma at this pixel
    float queryLuma = lumaTex.sample(bilinear, uv).r;

    // Depth texture dimensions (for converting UV → depth pixel coords)
    const uint dW = depthTex.get_width();
    const uint dH = depthTex.get_height();
    float2 depthCoord = uv * float2(dW, dH) - 0.5f;  // continuous depth-pixel coord

    float weightSum  = 0.0f;
    float depthSum   = 0.0f;

    for (int dy = -RADIUS; dy <= RADIUS; dy++) {
        for (int dx = -RADIUS; dx <= RADIUS; dx++) {
            float2 sampleCoord = depthCoord + float2(dx, dy);
            float2 sampleUV    = (sampleCoord + 0.5f) / float2(dW, dH);

            float depthVal  = depthTex.sample(bilinear, sampleUV).r;
            float sampleLuma = lumaTex.sample(bilinear, sampleUV).r;

            // Spatial weight
            float spatialDist2 = float(dx*dx + dy*dy);
            float wSpatial     = exp(-spatialDist2 / (2.0f * SIGMA_SPATIAL * SIGMA_SPATIAL));

            // Luma-similarity weight (edge-preserving)
            float lumaDiff  = queryLuma - sampleLuma;
            float wLuma     = exp(-(lumaDiff * lumaDiff) / (2.0f * SIGMA_LUMA * SIGMA_LUMA));

            float w = wSpatial * wLuma;
            weightSum += w;
            depthSum  += w * depthVal;
        }
    }

    float depth      = (weightSum > 0.0f) ? (depthSum / weightSum) : 0.0f;
    float normalized = clamp(1.0f - depth / maxDepth, 0.0f, 1.0f);
    uint8_t pixel    = uint8_t(normalized * 255.0f);

    // Write BGRA (all channels equal for greyscale, full alpha)
    outTex.write(float4(pixel/255.0f, pixel/255.0f, pixel/255.0f, 1.0f), gid);
}
