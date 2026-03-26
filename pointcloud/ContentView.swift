//
//  ContentView.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

import SwiftUI
import ARKit
import AVFoundation
import Combine

@MainActor
struct ContentView: View {

    @StateObject private var arSession    = ARSessionManager()
    @StateObject private var recorder     = DualVideoRecorder()
    @StateObject private var depthOverlay = DepthOverlayProcessor()

    @State private var showDepthOverlay = false
    @State private var showSavedToast   = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if arSession.isSupported {
                CameraPreviewView(session: arSession.session)
                    .ignoresSafeArea()
                    .onAppear {
                        setupFrameCallback()
                        requestCameraAndStartAR()
                    }
                    .onDisappear { arSession.pause() }

                // Depth matte — UIViewRepresentable pushes image directly to UIImageView,
                // bypassing SwiftUI's render pipeline so frame updates never cause
                // ContentView (and the ControlBar) to re-render and drop touches.
                if showDepthOverlay {
                    DepthOverlayView(processor: depthOverlay)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .opacity(0.75)
                        .allowsHitTesting(false)
                }

                ControlBar(
                    isRecording:      .init(get: { recorder.isRecording }, set: { _ in }),
                    maxDepth:         Binding(get: { recorder.maxDepth },
                                             set: { recorder.maxDepth = $0 }),
                    showDepthOverlay: $showDepthOverlay,
                    showSavedToast:   showSavedToast,
                    onRecordToggle:   toggleRecording
                )
            } else {
                UnsupportedDeviceView()
            }
        }
        .background(Color.black)
        .onChange(of: recorder.savedToPhotos) { _, saved in if saved { showToast() } }
        .onChange(of: showDepthOverlay) { _, enabled in depthOverlay.isEnabled = enabled }
    }

    // MARK: - Setup

    private func setupFrameCallback() {
        let overlay = depthOverlay
        arSession.onFrame = { [weak recorder, weak overlay] frame in
            recorder?.appendFrame(frame)
            overlay?.process(frame: frame, maxDepth: recorder?.maxDepth ?? 5.0)
        }
    }

    private func requestCameraAndStartAR() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            arSession.start()
        case .notDetermined:
            let session = arSession
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in if granted { session.start() } }
            }
        default:
            break
        }
    }

    // MARK: - Recording

    private func toggleRecording() {
        if recorder.isRecording { recorder.stopRecording() }
        else                    { recorder.startRecording() }
    }

    private func showToast() {
        withAnimation { showSavedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { showSavedToast = false }
        }
    }
}

// MARK: - Depth overlay UIKit view

/// Wraps a UIImageView so the processor can push images directly without going
/// through SwiftUI's @Published → objectWillChange → full ContentView re-render path.
struct DepthOverlayView: UIViewRepresentable {
    let processor: DepthOverlayProcessor

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.isUserInteractionEnabled = false
        processor.imageView = iv
        return iv
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        processor.imageView = uiView
    }
}

// MARK: - Depth overlay processor

/// Generates depth images on a background queue and writes them straight to
/// a UIImageView — no @Published, no SwiftUI re-renders while the overlay is live.
/// On this branch the depth map is first upsampled to camera resolution via
/// joint bilateral filtering (GuidedDepthUpsampler / Metal).
final class DepthOverlayProcessor: ObservableObject {

    /// Weak so the UIImageView is released when the SwiftUI view is removed.
    weak var imageView: UIImageView?
    var isEnabled = false

    private let queue     = DispatchQueue(label: "com.immanuel.pointcloud.depthoverlay",
                                          qos: .userInitiated)
    private let upsampler = GuidedDepthUpsampler()

    func process(frame: ARFrame, maxDepth: Float) {
        guard isEnabled, imageView != nil,
              let depthMap = frame.sceneDepth?.depthMap else { return }
        let rgb = frame.capturedImage
        queue.async { [weak self] in
            guard let self else { return }
            let img: UIImage?
            if let up = upsampler,
               let bgra = up.upsample(depthMap: depthMap, capturedImage: rgb, maxDepth: maxDepth) {
                img = Self.imageFromBGRA(bgra)
            } else {
                img = Self.makeImageCPU(from: depthMap, maxDepth: maxDepth)
            }
            DispatchQueue.main.async { self.imageView?.image = img }
        }
    }

    /// Wrap an already-rendered BGRA CVPixelBuffer as a UIImage (portrait via .right).
    private static func imageFromBGRA(_ buf: CVPixelBuffer) -> UIImage? {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let w   = CVPixelBufferGetWidth(buf)
        let h   = CVPixelBufferGetHeight(buf)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        guard let provider = CGDataProvider(
                dataInfo: nil,
                data: base, size: bpr * h,
                releaseData: { _, _, _ in }),
              let cg = CGImage(
                  width: w, height: h,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: bpr,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue:
                      CGImageAlphaInfo.noneSkipFirst.rawValue |
                      CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider,
                  decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg, scale: 1.0, orientation: .right)
    }

    /// CPU fallback (used only if Metal unavailable).
    private static func makeImageCPU(from depthMap: CVPixelBuffer, maxDepth: Float) -> UIImage? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let w      = CVPixelBufferGetWidth(depthMap)
        let h      = CVPixelBufferGetHeight(depthMap)
        let floats = CVPixelBufferGetBaseAddress(depthMap)!.assumingMemoryBound(to: Float32.self)

        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let v = UInt8(max(0, min(1, 1 - floats[i] / maxDepth)) * 255)
            rgba[i * 4 + 0] = v
            rgba[i * 4 + 1] = v
            rgba[i * 4 + 2] = v
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(
                  width: w, height: h,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: w * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: .init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil, shouldInterpolate: true,
                  intent: .defaultIntent) else { return nil }

        return UIImage(cgImage: cg, scale: 1.0, orientation: .right)
    }
}

// MARK: - Unsupported device

struct UnsupportedDeviceView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.metering.none")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("LiDAR Not Available")
                .font(.title2.bold())
            Text("This app requires an iPhone with a LiDAR scanner (iPhone 12 Pro or later).")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}

#Preview {
    ContentView()
}
