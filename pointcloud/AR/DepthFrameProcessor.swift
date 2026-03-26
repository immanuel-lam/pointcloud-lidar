//
//  DepthFrameProcessor.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

import ARKit

final class DepthFrameProcessor {

    /// Sample every Nth pixel in both X and Y. Higher = fewer points, better perf.
    nonisolated(unsafe) var subsampleStep: Int = 4

    /// Process an ARFrame into an array of RGB-coloured 3-D vertices.
    /// Marked nonisolated so it can be called from background tasks.
    nonisolated func process(_ frame: ARFrame) -> [PointVertex] {
        let subsampleStep = self.subsampleStep

        // Prefer smoothed depth; fall back to raw.
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let confidenceBuffer = depthData.confidenceMap else { return [] }

        let depthMap   = depthData.depthMap     // Float32, depth in metres (landscape)
        let colorImage = frame.capturedImage    // YCbCr 4:2:0 (landscape)
        let intrinsics = frame.camera.intrinsics // 3×3 column-major, for RGB camera res

        CVPixelBufferLockBaseAddress(depthMap,         .readOnly)
        CVPixelBufferLockBaseAddress(confidenceBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(colorImage,       .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap,         .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(colorImage,       .readOnly)
        }

        let depthWidth  = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthBytes  = CVPixelBufferGetBaseAddress(depthMap)!
            .assumingMemoryBound(to: Float32.self)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride

        let confBytes    = CVPixelBufferGetBaseAddress(confidenceBuffer)!
            .assumingMemoryBound(to: UInt8.self)
        let confRowBytes = CVPixelBufferGetBytesPerRow(confidenceBuffer)

        let rgbWidth  = CVPixelBufferGetWidth(colorImage)
        let rgbHeight = CVPixelBufferGetHeight(colorImage)

        // Scale camera intrinsics (defined for RGB resolution) down to depth map resolution.
        // Both buffers are in landscape orientation so the scale is the same in X and Y.
        let scaleX = Float(depthWidth)  / Float(rgbWidth)
        let scaleY = Float(depthHeight) / Float(rgbHeight)
        let fx = intrinsics[0][0] * scaleX
        let fy = intrinsics[1][1] * scaleY
        let cx = intrinsics[2][0] * scaleX   // intrinsics is column-major: [col][row]
        let cy = intrinsics[2][1] * scaleY

        // Access luma (Y) and chroma (CbCr) planes of YCbCr buffer
        let yPlane    = CVPixelBufferGetBaseAddressOfPlane(colorImage, 0)!
            .assumingMemoryBound(to: UInt8.self)
        let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(colorImage, 1)!
            .assumingMemoryBound(to: UInt8.self)
        let yRowBytes    = CVPixelBufferGetBytesPerRowOfPlane(colorImage, 0)
        let cbcrRowBytes = CVPixelBufferGetBytesPerRowOfPlane(colorImage, 1)

        let approxCount = (depthWidth / subsampleStep) * (depthHeight / subsampleStep)
        var vertices = [PointVertex]()
        vertices.reserveCapacity(approxCount)

        let step = max(1, subsampleStep)

        for row in stride(from: 0, to: depthHeight, by: step) {
            for col in stride(from: 0, to: depthWidth, by: step) {

                // Accept medium + high confidence pixels (low = 0, medium = 1, high = 2)
                let conf = confBytes[row * confRowBytes + col]
                guard conf >= ARConfidenceLevel.medium.rawValue else { continue }

                let depth = depthBytes[row * depthRowBytes + col]
                guard depth > 0.1 && depth < 10.0 else { continue }

                // Unproject to camera space using scaled intrinsics.
                // ARKit camera: +X right, +Y up, -Z forward (into scene).
                let px = (Float(col) - cx) * depth / fx
                let py = (Float(row) - cy) * depth / fy   // row goes down → negate for +Y up
                let position = SIMD3<Float>(px, -py, -depth)

                // Map depth pixel → colour pixel by proportional UV (both buffers are landscape).
                let u = Float(col) / Float(depthWidth)
                let v = Float(row) / Float(depthHeight)
                let rgbCol = min(Int(u * Float(rgbWidth)),  rgbWidth  - 1)
                let rgbRow = min(Int(v * Float(rgbHeight)), rgbHeight - 1)

                // Sample YCbCr → linear RGB
                let luma    = Float(yPlane[rgbRow * yRowBytes + rgbCol])
                let cbcrCol = (rgbCol / 2) * 2
                let cbcrRow = rgbRow / 2
                let cb = Float(cbcrPlane[cbcrRow * cbcrRowBytes + cbcrCol])
                let cr = Float(cbcrPlane[cbcrRow * cbcrRowBytes + cbcrCol + 1])

                let r = clamp((luma                                          + 1.402   * (cr - 128)) / 255.0, 0, 1)
                let g = clamp((luma - 0.344136 * (cb - 128) - 0.714136 * (cr - 128)) / 255.0, 0, 1)
                let b = clamp((luma + 1.772   * (cb - 128))                           / 255.0, 0, 1)

                vertices.append(PointVertex(position: position,
                                            color: SIMD4<Float>(r, g, b, 1)))
            }
        }

        return vertices
    }

    private nonisolated func clamp(_ value: Float, _ lo: Float, _ hi: Float) -> Float {
        Swift.max(lo, Swift.min(hi, value))
    }
}
