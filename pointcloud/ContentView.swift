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
                // Camera feed — fills full screen including safe areas.
                CameraPreviewView(session: arSession.session)
                    .ignoresSafeArea()
                    .onAppear {
                        setupFrameCallback()
                        requestCameraAndStartAR()
                    }
                    .onDisappear { arSession.pause() }

                // Depth matte — processor renders it at the full-screen size and
                // already applies the same displayTransform ARSCNView uses, so no
                // additional scaling/rotation is needed here.
                if showDepthOverlay, let img = depthOverlay.image {
                    Image(uiImage: img)
                        .resizable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
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
        // Use a full-screen GeometryReader (ignoresSafeArea) so viewportSize matches
        // the size ARSCNView uses when calling displayTransform(for:viewportSize:).
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear            { depthOverlay.viewportSize = geo.size }
                    .onChange(of: geo.size) { _, s in depthOverlay.viewportSize = s }
            }
            .ignoresSafeArea()
        )
        .onChange(of: recorder.savedToPhotos) { _, saved in if saved { showToast() } }
        .onChange(of: showDepthOverlay) { _, enabled in
            depthOverlay.isEnabled = enabled
            if !enabled { depthOverlay.image = nil }
        }
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

// MARK: - Depth overlay processor

/// Converts each ARFrame's depth map to a UIImage that is pixel-aligned with ARSCNView's
/// camera display, using ARKit's displayTransform to backward-sample the depth map.
///
/// Coordinate reasoning:
///   `frame.displayTransform(for:viewportSize:)` maps camera UV → display UV
///   (both in Metal/UIKit y-down convention, (0,0) upper-left).
///   Apple's own ARKit sample code inverts it in the shader to map display→camera.
///   We do the same: for each OUTPUT pixel at display UV (ox/W, oy/H), compute
///   the INPUT depth pixel via displayTransform.inverted() and sample.
final class DepthOverlayProcessor: ObservableObject {
    @Published var image: UIImage?
    var isEnabled    = false
    var viewportSize: CGSize = .zero

    private let queue = DispatchQueue(label: "com.immanuel.pointcloud.depthoverlay",
                                      qos: .userInitiated)

    // Reuse output buffer across frames to avoid per-frame heap allocations.
    private var outBuf   = [UInt8]()
    private var outW     = 0
    private var outH     = 0

    func process(frame: ARFrame, maxDepth: Float) {
        guard isEnabled,
              viewportSize.width > 0, viewportSize.height > 0,
              let depthMap = frame.sceneDepth?.depthMap else { return }

        // Capture everything on the main thread before hopping to the queue.
        let transform  = frame.displayTransform(for: .portrait, viewportSize: viewportSize)
        let invTransform = transform.inverted()   // display UV → camera UV
        let vs         = viewportSize

        queue.async { [weak self] in
            guard let self else { return }
            let img = self.render(depthMap: depthMap, maxDepth: maxDepth,
                                  invTransform: invTransform, viewportSize: vs)
            DispatchQueue.main.async { self.image = img }
        }
    }

    // MARK: - Private

    /// Backward-samples the depth map using the inverted displayTransform.
    /// Both coordinate spaces are y-down (Metal/UIKit convention).
    private func render(depthMap: CVPixelBuffer,
                        maxDepth: Float,
                        invTransform: CGAffineTransform,
                        viewportSize: CGSize) -> UIImage? {

        let dW = CVPixelBufferGetWidth(depthMap)
        let dH = CVPixelBufferGetHeight(depthMap)
        let oW = Int(viewportSize.width)
        let oH = Int(viewportSize.height)
        guard oW > 0, oH > 0 else { return nil }

        // Resize output buffer if dimensions changed.
        let needed = oW * oH * 4
        if outBuf.count != needed {
            outBuf = [UInt8](repeating: 255, count: needed)
            outW = oW; outH = oH
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let floats = CVPixelBufferGetBaseAddress(depthMap)!.assumingMemoryBound(to: Float32.self)

        let dWf = CGFloat(dW)
        let dHf = CGFloat(dH)
        let oWf = CGFloat(oW)
        let oHf = CGFloat(oH)

        // Pre-extract transform components to avoid CGPoint.applying overhead in hot loop.
        let a = invTransform.a;  let b = invTransform.b
        let c = invTransform.c;  let d = invTransform.d
        let tx = invTransform.tx; let ty = invTransform.ty

        for oy in 0..<oH {
            let ny = CGFloat(oy) / oHf               // display UV y in [0,1]
            for ox in 0..<oW {
                let nx = CGFloat(ox) / oWf           // display UV x in [0,1]

                // invTransform: display UV → camera UV (both y-down, (0,0) upper-left)
                let cu = a * nx + c * ny + tx
                let cv = b * nx + d * ny + ty

                // Camera UV → depth pixel (clamp to valid range)
                let dx = Int(max(0, min(dWf - 1, cu * dWf)))
                let dy = Int(max(0, min(dHf - 1, cv * dHf)))

                let depth = floats[dy * dW + dx]
                // NaN (unmeasured pixel) → treat as max depth (black)
                let v = depth.isNaN ? 0 : UInt8(max(0, min(1, 1 - depth / maxDepth)) * 255)

                let base = (oy * oW + ox) * 4
                outBuf[base]     = v   // R
                outBuf[base + 1] = v   // G
                outBuf[base + 2] = v   // B
                // outBuf[base + 3] = 255 (alpha stays 255 from init)
            }
        }

        guard let provider = CGDataProvider(data: Data(outBuf) as CFData),
              let cg = CGImage(
                  width: oW, height: oH,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: oW * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: .init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent) else { return nil }

        return UIImage(cgImage: cg)  // .up — already in display (y-down) space
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
