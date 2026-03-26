//
//  PixelBufferPool.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

import Metal
import CoreVideo

final class PixelBufferPool {

    private let pool: CVPixelBufferPool
    private let textureCache: CVMetalTextureCache
    let width: Int
    let height: Int

    init?(device: MTLDevice, width: Int, height: Int) {
        self.width  = width
        self.height = height

        // Create pixel buffer pool
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey:           width,
            kCVPixelBufferHeightKey:          height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
        var poolOut: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &poolOut) == kCVReturnSuccess,
              let pool = poolOut else { return nil }
        self.pool = pool

        // Create Metal texture cache for zero-copy GPU → CPU path
        var cacheOut: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cacheOut) == kCVReturnSuccess,
              let cache = cacheOut else { return nil }
        self.textureCache = cache
    }

    /// Copy a Metal texture into a fresh CVPixelBuffer from the pool.
    func pixelBuffer(from texture: MTLTexture) -> CVPixelBuffer? {
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess,
              let pixelBuffer = pbOut else { return nil }

        // Wrap the pixel buffer as a Metal texture via the cache.
        var metalTexRef: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &metalTexRef
        ) == kCVReturnSuccess,
              let metalTexRef,
              let destTexture = CVMetalTextureGetTexture(metalTexRef) else { return nil }

        // Blit the source drawable texture → destination pixel buffer texture
        guard let queue = texture.device.makeCommandQueue(),
              let cmd   = queue.makeCommandBuffer(),
              let blit  = cmd.makeBlitCommandEncoder() else { return nil }

        blit.copy(
            from: texture,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize:   MTLSize(width: width, height: height, depth: 1),
            to: destTexture,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        return pixelBuffer
    }

    func flush() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
