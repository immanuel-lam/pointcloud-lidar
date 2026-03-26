//
//  VideoRecorder.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

@preconcurrency import AVFoundation
import Combine
import Metal
import Photos

final class VideoRecorder: ObservableObject {

    @Published private(set) var isRecording = false
    /// Flips to true momentarily after a successful Photos save; observe in the UI.
    @Published private(set) var savedToPhotos = false

    // All mutable recording state accessed only on recordingQueue.
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelBufferPool: PixelBufferPool?
    private var startTime: CMTime?

    private let recordingQueue = DispatchQueue(label: "com.immanuel.pointcloud.recording",
                                               qos: .userInitiated)
    private let fps: Int

    init(fps: Int = 30) {
        self.fps = fps
    }

    /// Start recording at the drawable's actual pixel dimensions.
    @MainActor
    func startRecording(device: MTLDevice, drawableSize: CGSize) {
        guard !isRecording else { return }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url  = docs.appendingPathComponent("pointcloud_\(Int(Date().timeIntervalSince1970)).mp4")
        let w    = Int(drawableSize.width)
        let h    = Int(drawableSize.height)
        let f    = fps

        // Create all AVFoundation objects inside the queue to avoid @Sendable capture warnings.
        recordingQueue.sync {
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }

            let videoSettings: [String: Any] = [
                AVVideoCodecKey:  AVVideoCodecType.h264,
                AVVideoWidthKey:  w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoMaxKeyFrameIntervalKey: f
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true

            let adaptorAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String:           w,
                kCVPixelBufferHeightKey as String:          h
            ]
            let adapt = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                             sourcePixelBufferAttributes: adaptorAttrs)
            guard writer.canAdd(input) else { return }
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            self.assetWriter     = writer
            self.videoInput      = input
            self.adaptor         = adapt
            self.pixelBufferPool = PixelBufferPool(device: device, width: w, height: h)
            self.startTime       = nil
        }
        isRecording = true
    }

    /// Called from the Metal render thread — state access is serialised via recordingQueue.
    func appendFrame(texture: MTLTexture, at time: CMTime) {
        recordingQueue.async {
            guard let input = self.videoInput,
                  let adapt = self.adaptor,
                  let pool  = self.pixelBufferPool else { return }

            let presentationTime: CMTime
            if let start = self.startTime {
                presentationTime = CMTimeSubtract(time, start)
            } else {
                self.startTime   = time
                presentationTime = .zero
            }

            guard input.isReadyForMoreMediaData else { return }
            guard let pixelBuffer = pool.pixelBuffer(from: texture) else { return }
            adapt.append(pixelBuffer, withPresentationTime: presentationTime)
        }
    }

    @MainActor
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        recordingQueue.async {
            guard let writer = self.assetWriter,
                  let input  = self.videoInput else { return }
            let outputURL = writer.outputURL
            input.markAsFinished()
            writer.finishWriting {
                DispatchQueue.main.async {
                    self.saveToPhotos(url: outputURL)
                }
            }
        }
    }

    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self?.cleanup() }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { [weak self] success, error in
                if let error { print("Photos save error: \(error)") }
                DispatchQueue.main.async {
                    if success { self?.savedToPhotos = true }
                    self?.cleanup()
                }
            }
        }
    }

    private func cleanup() {
        assetWriter     = nil
        videoInput      = nil
        adaptor         = nil
        pixelBufferPool = nil
        startTime       = nil
    }
}
