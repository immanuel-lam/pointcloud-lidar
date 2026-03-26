//
//  VideoRecorder.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

import AVFoundation
import Metal
import Photos

@MainActor
final class VideoRecorder: ObservableObject {

    @Published private(set) var isRecording = false

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelBufferPool: PixelBufferPool?
    private var startTime: CMTime?

    private let width: Int
    private let height: Int
    private let fps: Int

    init(width: Int = 1920, height: Int = 1080, fps: Int = 30) {
        self.width  = width
        self.height = height
        self.fps    = fps
    }

    func startRecording(device: MTLDevice) {
        guard !isRecording else { return }

        // Build output URL in Documents
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let filename = "pointcloud_\(Int(Date().timeIntervalSince1970)).mp4"
        let url = docs.appendingPathComponent(filename)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoMaxKeyFrameIntervalKey: fps
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String:           width,
            kCVPixelBufferHeightKey as String:          height
        ]
        let adapt = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                         sourcePixelBufferAttributes: adaptorAttrs)

        guard writer.canAdd(input) else { return }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let pool = PixelBufferPool(device: device, width: width, height: height)

        assetWriter       = writer
        videoInput        = input
        adaptor           = adapt
        pixelBufferPool   = pool
        startTime         = nil
        isRecording       = true
    }

    nonisolated func appendFrame(texture: MTLTexture, at time: CMTime) {
        // Capture what we need off the main actor safely
        MainActor.assumeIsolated {
            guard isRecording,
                  let input   = videoInput,
                  let adapt   = adaptor,
                  let pool    = pixelBufferPool else { return }

            // Establish a zero-based presentation time
            let presentationTime: CMTime
            if let start = startTime {
                presentationTime = CMTimeSubtract(time, start)
            } else {
                startTime        = time
                presentationTime = .zero
            }

            guard input.isReadyForMoreMediaData else { return }
            guard let pixelBuffer = pool.pixelBuffer(from: texture) else { return }
            adapt.append(pixelBuffer, withPresentationTime: presentationTime)
        }
    }

    func stopRecording() {
        guard isRecording,
              let writer = assetWriter,
              let input  = videoInput else { return }

        isRecording     = false
        let outputURL   = writer.outputURL

        input.markAsFinished()
        writer.finishWriting { [weak self] in
            Task { @MainActor in
                self?.saveToPhotos(url: outputURL)
                self?.cleanup()
            }
        }
    }

    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
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
