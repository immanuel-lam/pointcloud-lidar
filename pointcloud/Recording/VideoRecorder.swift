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

    // All mutable state below is accessed only on recordingQueue
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelBufferPool: PixelBufferPool?
    private var startTime: CMTime?

    private let recordingQueue = DispatchQueue(label: "com.immanuel.pointcloud.recording",
                                               qos: .userInitiated)

    private let width: Int
    private let height: Int
    private let fps: Int

    init(width: Int = 1920, height: Int = 1080, fps: Int = 30) {
        self.width  = width
        self.height = height
        self.fps    = fps
    }

    @MainActor
    func startRecording(device: MTLDevice) {
        guard !isRecording else { return }

        // All value-type parameters that will be sent into the queue
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url  = docs.appendingPathComponent("pointcloud_\(Int(Date().timeIntervalSince1970)).mp4")
        let w = width, h = height, f = fps

        // Create AVFoundation objects inside the queue to avoid @Sendable capture warnings
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
                    self.cleanup()
                }
            }
        }
    }

    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { _, error in
                if let error { print("Photos save error: \(error)") }
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
