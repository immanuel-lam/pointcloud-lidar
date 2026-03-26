//
//  GuidedDepthUpsampler.swift
//  pointcloud
//
//  Metal wrapper for the joint bilateral guided upsampling kernel.
//  Converts a ~256×192 Float32 depth map to a full-camera-resolution BGRA8
//  pixel buffer, guided by the RGB luma channel to preserve edges.
//

import Metal
import CoreVideo
import ARKit

/// Upsamples a LiDAR depth map to full camera resolution using the luma
/// channel of the captured RGB frame as an edge guide.
final class GuidedDepthUpsampler {

    private let device:       MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline:     MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    /// Pool of output BGRA pixel buffers at camera resolution.
    private var outputPool:   CVPixelBufferPool?
    private var poolWidth:    Int = 0
    private var poolHeight:   Int = 0

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else { return nil }
        device       = dev
        commandQueue = queue

        guard let lib  = dev.makeDefaultLibrary(),
              let func_ = lib.makeFunction(name: "guidedUpsampleToBGRA") else {
            print("GuidedDepthUpsampler: kernel not found")
            return nil
        }
        guard let ps = try? dev.makeComputePipelineState(function: func_) else {
            print("GuidedDepthUpsampler: pipeline creation failed")
            return nil
        }
        pipeline = ps

        CVMetalTextureCacheCreate(nil, nil, dev, nil, &textureCache)
    }

    // MARK: - Public API

    /// Upsample `depthMap` to the dimensions of `capturedImage`.
    /// Returns a BGRA CVPixelBuffer at full camera resolution, or nil on failure.
    func upsample(depthMap: CVPixelBuffer,
                  capturedImage: CVPixelBuffer,
                  maxDepth: Float) -> CVPixelBuffer? {
        let outW = CVPixelBufferGetWidth(capturedImage)
        let outH = CVPixelBufferGetHeight(capturedImage)

        guard let outBuf = getOutputBuffer(width: outW, height: outH) else { return nil }

        guard let cache = textureCache else { return nil }

        // --- Depth texture (R32Float) ---
        let dW = CVPixelBufferGetWidth(depthMap)
        let dH = CVPixelBufferGetHeight(depthMap)
        var depthMTLTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, depthMap, nil,
                .r32Float, dW, dH, 0, &depthMTLTex) == kCVReturnSuccess,
              let depthTex = CVMetalTextureGetTexture(depthMTLTex!) else { return nil }

        // --- Luma texture (Y-plane of YCbCr, R8Unorm) ---
        let lW = CVPixelBufferGetWidthOfPlane(capturedImage, 0)
        let lH = CVPixelBufferGetHeightOfPlane(capturedImage, 0)
        var lumaMTLTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, capturedImage, nil,
                .r8Unorm, lW, lH, 0, &lumaMTLTex) == kCVReturnSuccess,
              let lumaTex = CVMetalTextureGetTexture(lumaMTLTex!) else { return nil }

        // --- Output texture (BGRA8Unorm) ---
        var outMTLTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, outBuf, nil,
                .bgra8Unorm, outW, outH, 0, &outMTLTex) == kCVReturnSuccess,
              let outTex = CVMetalTextureGetTexture(outMTLTex!) else { return nil }

        // --- Encode and dispatch ---
        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(depthTex, index: 0)
        encoder.setTexture(lumaTex,  index: 1)
        encoder.setTexture(outTex,   index: 2)

        var md = maxDepth
        encoder.setBytes(&md, length: MemoryLayout<Float>.size, index: 0)

        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let grid   = MTLSize(
            width:  (outW + tgSize.width  - 1) / tgSize.width,
            height: (outH + tgSize.height - 1) / tgSize.height,
            depth:  1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return outBuf
    }

    // MARK: - Private

    private func getOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if outputPool == nil || poolWidth != width || poolHeight != height {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey:     kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey:               width,
                kCVPixelBufferHeightKey:              height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
                kCVPixelBufferMetalCompatibilityKey:  true
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess,
                  let p = pool else { return nil }
            outputPool  = p
            poolWidth   = width
            poolHeight  = height
        }
        var buf: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, outputPool!, &buf) == kCVReturnSuccess else { return nil }
        return buf
    }
}
