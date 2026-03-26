//
//  MetalRenderer.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

import Metal
import MetalKit
import ARKit
import simd

final class MetalRenderer: NSObject {

    // MARK: - Public state

    var pointSize: Float = 6.0
    var currentVertices: [PointVertex] = []

    /// Called each frame just before present — receives the drawable texture and presentation time.
    var onFrameRendered: ((MTLTexture, CMTime) -> Void)?

    // MARK: - Metal objects

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    // Triple-buffering
    private let maxBuffersInFlight = 3
    private let frameSemaphore: DispatchSemaphore
    private var vertexBuffers: [MTLBuffer]
    private var uniformBuffers: [MTLBuffer]
    private var currentBufferIndex = 0

    private let maxVertexCount = 200_000  // enough for dense LiDAR frames

    // AR camera matrices (updated from the main thread via updateCamera)
    private var projectionMatrix: float4x4 = matrix_identity_float4x4
    private var viewMatrix: float4x4 = matrix_identity_float4x4

    // Presentation timestamp for video recording
    private var frameTimestamp: CMTime = .zero

    // MARK: - Init

    init?(mtkView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.framebufferOnly = false  // needed for texture read-back during recording

        frameSemaphore = DispatchSemaphore(value: maxBuffersInFlight)

        let vertexBufferSize = maxVertexCount * MemoryLayout<PointVertex>.stride
        vertexBuffers = (0..<3).map { _ in
            device.makeBuffer(length: vertexBufferSize, options: .storageModeShared)!
        }
        uniformBuffers = (0..<3).map { _ in
            device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared)!
        }

        // Build pipeline
        guard let library = device.makeDefaultLibrary() else { return nil }
        let vertexFn   = library.makeFunction(name: "point_vertex")
        let fragmentFn = library.makeFunction(name: "point_fragment")

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction   = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Alpha blending for soft dots
        descriptor.colorAttachments[0].isBlendingEnabled          = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor       = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor  = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor     = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .zero

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        pipelineState = pipeline

        super.init()
        mtkView.delegate = self
    }

    // MARK: - Public API

    func updateCamera(frame: ARFrame, viewportSize: CGSize) {
        // Points are already in camera space (computed via depth intrinsics).
        // projectionMatrix(for: .portrait) includes the 90° landscape→portrait rotation.
        // viewMatrix must be identity — applying the world-to-camera transform to
        // camera-space points causes incorrect rotation and translation.
        projectionMatrix = frame.camera.projectionMatrix(for: .portrait,
                                                          viewportSize: viewportSize,
                                                          zNear: 0.01,
                                                          zFar: 20.0)
        viewMatrix = matrix_identity_float4x4
        frameTimestamp = CMTime(seconds: frame.timestamp, preferredTimescale: 600)
    }
}

// MARK: - MTKViewDelegate

extension MetalRenderer: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        _ = frameSemaphore.wait(timeout: .distantFuture)

        let bufferIndex = currentBufferIndex
        currentBufferIndex = (currentBufferIndex + 1) % maxBuffersInFlight

        let vertices = currentVertices
        let count = min(vertices.count, maxVertexCount)

        // Upload vertices
        if count > 0 {
            let vBuf = vertexBuffers[bufferIndex]
            vertices.withUnsafeBytes { ptr in
                vBuf.contents().copyMemory(from: ptr.baseAddress!,
                                           byteCount: count * MemoryLayout<PointVertex>.stride)
            }
        }

        // Upload uniforms
        var uniforms = Uniforms(projectionMatrix: projectionMatrix,
                                viewMatrix: viewMatrix,
                                pointSize: pointSize)
        uniformBuffers[bufferIndex].contents()
            .copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.stride)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor else {
            frameSemaphore.signal()
            return
        }

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.frameSemaphore.signal()
        }

        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)!
        encoder.setRenderPipelineState(pipelineState)

        if count > 0 {
            encoder.setVertexBuffer(vertexBuffers[bufferIndex], offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffers[bufferIndex], offset: 0, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        }

        encoder.endEncoding()

        // Notify recorder before present
        let texture   = drawable.texture
        let timestamp = frameTimestamp
        onFrameRendered?(texture, timestamp)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
