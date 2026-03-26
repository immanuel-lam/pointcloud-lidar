//
//  DepthFrameProcessor.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

import ARKit
import Accelerate

final class DepthFrameProcessor {

    /// Sample every Nth pixel in both X and Y. Higher = fewer points, better perf.
    var subsampleStep: Int = 4

    /// Process an ARFrame into an array of RGB-coloured 3-D vertices.
    func process(_ frame: ARFrame) -> [PointVertex] {
        // Prefer smoothed depth; fall back to raw.
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let confidenceBuffer = depthData.confidenceMap else { return [] }

        let depthMap   = depthData.depthMap          // Float32, depth in metres
        let colorImage = frame.capturedImage          // YCbCr 4:2:0
        let intrinsics = frame.camera.intrinsics      // 3×3 column-major
        let transform  = frame.displayTransform(for: .portrait, viewportSize: CGSize(
            width:  CVPixelBufferGetWidth(depthMap),
            height: CVPixelBufferGetHeight(depthMap)))

        CVPixelBufferLockBaseAddress(depthMap,       .readOnly)
        CVPixelBufferLockBaseAddress(confidenceBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(colorImage,     .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap,       .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(colorImage,     .readOnly)
        }

        let depthWidth  = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthBytes  = CVPixelBufferGetBaseAddress(depthMap)!
            .assumingMemoryBound(to: Float32.self)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride

        let confBytes = CVPixelBufferGetBaseAddress(confidenceBuffer)!
            .assumingMemoryBound(to: UInt8.self)
        let confRowBytes = CVPixelBufferGetBytesPerRow(confidenceBuffer)

        // Camera intrinsics (column-major simd_float3x3)
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        // RGB image dimensions
        let rgbWidth  = CVPixelBufferGetWidth(colorImage)
        let rgbHeight = CVPixelBufferGetHeight(colorImage)

        // Access luma (Y) and chroma (CbCr) planes of YCbCr buffer
        let yPlane    = CVPixelBufferGetBaseAddressOfPlane(colorImage, 0)!.assumingMemoryBound(to: UInt8.self)
        let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(colorImage, 1)!.assumingMemoryBound(to: UInt8.self)
        let yRowBytes    = CVPixelBufferGetBytesPerRowOfPlane(colorImage, 0)
        let cbcrRowBytes = CVPixelBufferGetBytesPerRowOfPlane(colorImage, 1)

        // Pre-allocate approximate capacity
        let approxCount = (depthWidth / subsampleStep) * (depthHeight / subsampleStep)
        var vertices = [PointVertex]()
        vertices.reserveCapacity(approxCount)

        let step = max(1, subsampleStep)

        for row in stride(from: 0, to: depthHeight, by: step) {
            for col in stride(from: 0, to: depthWidth, by: step) {

                // Skip low-confidence pixels
                let conf = confBytes[row * confRowBytes + col]
                guard conf >= ARConfidenceLevel.high.rawValue else { continue }

                let depth = depthBytes[row * depthRowBytes + col]
                guard depth > 0.1 && depth < 10.0 else { continue }  // reasonable range

                // Unproject depth pixel → camera-space 3-D point
                let x = (Float(col) - cx) * depth / fx
                let y = (Float(row) - cy) * depth / fy
                let position = SIMD3<Float>(x, -y, -depth)  // flip Y for Metal convention

                // Map depth pixel → RGB pixel via displayTransform
                let depthUV = CGPoint(x: CGFloat(col) / CGFloat(depthWidth),
                                      y: CGFloat(row) / CGFloat(depthHeight))
                let rgbUV = depthUV.applying(transform)
                let rgbCol = Int(rgbUV.x * CGFloat(rgbWidth))
                let rgbRow = Int(rgbUV.y * CGFloat(rgbHeight))

                guard rgbCol >= 0 && rgbCol < rgbWidth &&
                      rgbRow >= 0 && rgbRow < rgbHeight else { continue }

                // Sample YCbCr → RGB
                let luma   = Float(yPlane[rgbRow * yRowBytes + rgbCol])
                let cbcrCol = (rgbCol / 2) * 2
                let cbcrRow = rgbRow / 2
                let cb = Float(cbcrPlane[cbcrRow * cbcrRowBytes + cbcrCol])
                let cr = Float(cbcrPlane[cbcrRow * cbcrRowBytes + cbcrCol + 1])

                let r = clamp((luma + 1.402 * (cr - 128)) / 255.0, 0, 1)
                let g = clamp((luma - 0.344136 * (cb - 128) - 0.714136 * (cr - 128)) / 255.0, 0, 1)
                let b = clamp((luma + 1.772 * (cb - 128)) / 255.0, 0, 1)

                vertices.append(PointVertex(position: position,
                                            color: SIMD4<Float>(r, g, b, 1)))
            }
        }

        return vertices
    }

    private func clamp(_ value: Float, _ lo: Float, _ hi: Float) -> Float {
        Swift.max(lo, Swift.min(hi, value))
    }
}
