//
//  DualVideoRecorder.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

@preconcurrency import AVFoundation
import ARKit
import Combine
import Photos

/// Records two synced MP4 files simultaneously:
///   - `rgb_<ts>.mp4`   — H.264 colour video from ARFrame.capturedImage (YCbCr)
///   - `depth_<ts>.mp4` — greyscale depth map (near=white, far=black), H.264
///                         upsampled to full camera resolution via guided bilateral filter
///
/// Writers are lazily created on the first `appendFrame` call after `startRecording`,
/// so video dimensions are read directly from the live ARFrame.
final class DualVideoRecorder: ObservableObject {

    @Published private(set) var isRecording = false
    /// Flips to true momentarily after both files are saved to Photos.
    @Published private(set) var savedToPhotos = false

    /// Maximum depth to encode (maps to black=0). Values ≥ maxDepth → 0.
    var maxDepth: Float = 5.0

    // All mutable writer state is accessed only on recordingQueue.
    private var rgbWriter:    AVAssetWriter?
    private var rgbAdaptor:   AVAssetWriterInputPixelBufferAdaptor?
    private var depthWriter:  AVAssetWriter?
    private var depthAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var depthPool:    CVPixelBufferPool?
    private var startTime:    TimeInterval?

    /// Guided bilateral upsampler — created once, reused every frame.
    private let upsampler = GuidedDepthUpsampler()

    private let recordingQueue = DispatchQueue(label: "com.immanuel.pointcloud.dualrecording",
                                               qos: .userInitiated)

    // MARK: - Public API (called on MainActor)

    @MainActor
    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        // Writers are created on the first appendFrame call.
    }

    /// Called each AR frame (on main thread via ARKit delegate).
    func appendFrame(_ frame: ARFrame) {
        guard isRecording else { return }
        let capturedMaxDepth = maxDepth  // capture MainActor value before queue hop
        recordingQueue.async { [self] in
            // Lazily create writers on first frame so we know the actual pixel dimensions.
            if rgbWriter == nil {
                setupWriters(frame: frame)
                return  // skip this frame; start appending from the next one
            }
            guard rgbWriter?.status == .writing else { return }

            let elapsed = frame.timestamp - (startTime ?? frame.timestamp)
            let pts = CMTime(seconds: elapsed, preferredTimescale: 600)

            // RGB — append YCbCr pixel buffer directly; H.264 accepts it natively.
            if let adaptor = rgbAdaptor, adaptor.assetWriterInput.isReadyForMoreMediaData {
                adaptor.append(frame.capturedImage, withPresentationTime: pts)
            }

            // Depth — upsample Float32 depth to camera resolution via guided bilateral filter,
            // falling back to CPU BGRA conversion if Metal is unavailable.
            if let depthMap = frame.sceneDepth?.depthMap,
               let adaptor  = depthAdaptor,
               adaptor.assetWriterInput.isReadyForMoreMediaData {
                let rgb = frame.capturedImage
                if let up = upsampler,
                   let bgraBuffer = up.upsample(depthMap: depthMap,
                                                capturedImage: rgb,
                                                maxDepth: capturedMaxDepth) {
                    adaptor.append(bgraBuffer, withPresentationTime: pts)
                } else if let pool = depthPool,
                          let bgraBuffer = convertDepthToBGRA(depthMap, pool: pool,
                                                              maxDepth: capturedMaxDepth) {
                    adaptor.append(bgraBuffer, withPresentationTime: pts)
                }
            }
        }
    }

    @MainActor
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        recordingQueue.async { [self] in
            guard let rw = rgbWriter, let dw = depthWriter else { cleanup(); return }
            let rURL = rw.outputURL
            let dURL = dw.outputURL

            rgbAdaptor?.assetWriterInput.markAsFinished()
            depthAdaptor?.assetWriterInput.markAsFinished()
            cleanup()

            let group = DispatchGroup()
            group.enter(); rw.finishWriting { group.leave() }
            group.enter(); dw.finishWriting { group.leave() }
            group.notify(queue: .main) { [weak self] in
                self?.saveBothToPhotos(rgbURL: rURL, depthURL: dURL)
            }
        }
    }

    // MARK: - Private (called on recordingQueue)

    private func setupWriters(frame: ARFrame) {
        let rgbBuf = frame.capturedImage
        let rgbW   = CVPixelBufferGetWidth(rgbBuf)
        let rgbH   = CVPixelBufferGetHeight(rgbBuf)

        guard frame.sceneDepth?.depthMap != nil else { return }
        // Depth video is recorded at full camera resolution (upsampled), not sensor 256×192.
        let depthW = rgbW
        let depthH = rgbH

        let ts   = Int(Date().timeIntervalSince1970)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let rURL = docs.appendingPathComponent("rgb_\(ts).mp4")
        let dURL = docs.appendingPathComponent("depth_\(ts).mp4")

        guard let rw = try? AVAssetWriter(outputURL: rURL, fileType: .mp4),
              let dw = try? AVAssetWriter(outputURL: dURL, fileType: .mp4) else { return }

        // --- RGB input (YCbCr passthrough → H.264) ---
        let rgbInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  rgbW,
            AVVideoHeightKey: rgbH,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]
        ])
        rgbInput.expectsMediaDataInRealTime = true
        rgbInput.transform = CGAffineTransform(rotationAngle: .pi / 2)  // portrait orientation

        let rAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: rgbInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String:           rgbW,
                kCVPixelBufferHeightKey as String:          rgbH
            ])
        guard rw.canAdd(rgbInput) else { return }
        rw.add(rgbInput)

        // --- Depth input (BGRA greyscale → H.264, upsampled to camera resolution) ---
        let depthInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  depthW,
            AVVideoHeightKey: depthH,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
        ])
        depthInput.expectsMediaDataInRealTime = true
        depthInput.transform = CGAffineTransform(rotationAngle: .pi / 2)

        let dAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: depthInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String:           depthW,
                kCVPixelBufferHeightKey as String:          depthH
            ])
        guard dw.canAdd(depthInput) else { return }
        dw.add(depthInput)

        // --- Depth pixel buffer pool ---
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey:      kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey:                depthW,
            kCVPixelBufferHeightKey:               depthH,
            kCVPixelBufferIOSurfacePropertiesKey:  [:] as [CFString: Any]
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, poolAttrs as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else { return }

        rw.startWriting(); rw.startSession(atSourceTime: .zero)
        dw.startWriting(); dw.startSession(atSourceTime: .zero)

        rgbWriter    = rw
        rgbAdaptor   = rAdaptor
        depthWriter  = dw
        depthAdaptor = dAdaptor
        depthPool    = pool
        startTime    = frame.timestamp
    }

    /// Converts a `kCVPixelFormatType_DepthFloat32` buffer to `kCVPixelFormatType_32BGRA` greyscale.
    /// near (0 m) → white (255), far (≥ maxDepth) → black (0).
    private func convertDepthToBGRA(_ depthMap: CVPixelBuffer,
                                    pool: CVPixelBufferPool,
                                    maxDepth: Float) -> CVPixelBuffer? {
        var outBuf: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf) == kCVReturnSuccess,
              let out = outBuf else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(out, [])
        }

        let width       = CVPixelBufferGetWidth(depthMap)
        let height      = CVPixelBufferGetHeight(depthMap)
        let floatPtr    = CVPixelBufferGetBaseAddress(depthMap)!.assumingMemoryBound(to: Float32.self)
        let bgraPtr     = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(out)

        for y in 0..<height {
            for x in 0..<width {
                let depth      = floatPtr[y * width + x]
                let normalized = max(0, min(1, 1 - depth / maxDepth))
                let pixel      = UInt8(normalized * 255)
                let base       = y * bytesPerRow + x * 4
                bgraPtr[base + 0] = pixel  // B
                bgraPtr[base + 1] = pixel  // G
                bgraPtr[base + 2] = pixel  // R
                bgraPtr[base + 3] = 255    // A
            }
        }
        return out
    }

    private func saveBothToPhotos(rgbURL: URL, depthURL: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: rgbURL)
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: depthURL)
            } completionHandler: { [weak self] success, error in
                if let error { print("Photos save error: \(error)") }
                DispatchQueue.main.async {
                    if success { self?.savedToPhotos = true }
                }
            }
        }
    }

    private func cleanup() {
        rgbWriter    = nil
        rgbAdaptor   = nil
        depthWriter  = nil
        depthAdaptor = nil
        depthPool    = nil
        startTime    = nil
    }
}
