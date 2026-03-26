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
import CoreImage

@MainActor
struct ContentView: View {

    @StateObject private var arSession   = ARSessionManager()
    @StateObject private var recorder    = DualVideoRecorder()
    @StateObject private var depthOverlay = DepthOverlayProcessor()

    @State private var showDepthOverlay = false
    @State private var showSavedToast   = false
    @State private var viewportSize: CGSize = .zero

    var body: some View {
        ZStack(alignment: .bottom) {
            if arSession.isSupported {
                // Camera feed
                CameraPreviewView(session: arSession.session)
                    .ignoresSafeArea()
                    .onAppear {
                        setupFrameCallback()
                        requestCameraAndStartAR()
                    }
                    .onDisappear { arSession.pause() }

                // Depth matte — rendered to viewport size by DepthOverlayProcessor
                // so no scaling is needed; just fill + clip to avoid layout overflow.
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
                    isRecording:     .init(get: { recorder.isRecording }, set: { _ in }),
                    maxDepth:        Binding(get: { recorder.maxDepth },
                                            set: { recorder.maxDepth = $0 }),
                    showDepthOverlay: $showDepthOverlay,
                    showSavedToast:  showSavedToast,
                    onRecordToggle:  toggleRecording
                )
            } else {
                UnsupportedDeviceView()
            }
        }
        .background(Color.black)
        // Capture the actual layout size so depth images are rendered to the right dimensions.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
        .onChange(of: recorder.savedToPhotos) { _, saved in if saved { showToast() } }
        .onChange(of: showDepthOverlay) { _, enabled in
            depthOverlay.isEnabled = enabled
            if !enabled { depthOverlay.image = nil }
        }
        .onChange(of: viewportSize) { _, size in
            depthOverlay.viewportSize = size
        }
    }

    // MARK: - Setup

    private func setupFrameCallback() {
        let overlay = depthOverlay
        arSession.onFrame = { [weak recorder, weak overlay] frame in
            recorder?.appendFrame(frame)
            overlay?.process(frame: frame,
                             maxDepth: recorder?.maxDepth ?? 5.0,
                             viewportSize: overlay?.viewportSize ?? .zero)
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

/// Converts ARFrame depth maps to viewport-aligned UIImages using ARKit's displayTransform.
/// CoreImage (GPU) handles the affine warp; CPU only does the Float32→UInt8 normalisation.
final class DepthOverlayProcessor: ObservableObject {
    @Published var image: UIImage?
    var isEnabled   = false
    /// Set from ContentView via onGeometryChange before any frame is processed.
    var viewportSize: CGSize = .zero

    private let queue     = DispatchQueue(label: "com.immanuel.pointcloud.depthoverlay",
                                          qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Reusable BGRA pool — recreated when depth map size changes.
    private var bgraPool:  CVPixelBufferPool?
    private var poolDepthW = 0
    private var poolDepthH = 0

    func process(frame: ARFrame, maxDepth: Float, viewportSize: CGSize) {
        guard isEnabled,
              viewportSize != .zero,
              let depthMap = frame.sceneDepth?.depthMap else { return }

        // Capture everything needed before leaving the main thread.
        let transform = frame.displayTransform(for: .portrait, viewportSize: viewportSize)
        let depthW    = CVPixelBufferGetWidth(depthMap)
        let depthH    = CVPixelBufferGetHeight(depthMap)

        queue.async { [weak self] in
            guard let self else { return }

            // Ensure BGRA pool matches current depth map dimensions.
            if depthW != poolDepthW || depthH != poolDepthH {
                let attrs: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey:     kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey:               depthW,
                    kCVPixelBufferHeightKey:              depthH,
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
                ]
                var pool: CVPixelBufferPool?
                CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
                bgraPool   = pool
                poolDepthW = depthW
                poolDepthH = depthH
            }
            guard let pool = bgraPool else { return }

            let img = makeAlignedImage(
                depthMap:         depthMap,
                depthW:           depthW,  depthH: depthH,
                maxDepth:         maxDepth,
                displayTransform: transform,
                viewportSize:     viewportSize,
                bgraPool:         pool)

            DispatchQueue.main.async { self.image = img }
        }
    }

    // MARK: - Private

    /// 1. Normalise Float32 depth → BGRA pixel buffer (CPU, ~49 K px)
    /// 2. Wrap as CIImage, apply ARKit displayTransform (GPU), render to viewport size.
    private func makeAlignedImage(
        depthMap: CVPixelBuffer,
        depthW: Int, depthH: Int,
        maxDepth: Float,
        displayTransform: CGAffineTransform,
        viewportSize: CGSize,
        bgraPool: CVPixelBufferPool
    ) -> UIImage? {

        // --- Step 1: depth Float32 → BGRA 8-bit ---
        var outBuf: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, bgraPool, &outBuf) == kCVReturnSuccess,
              let bgra = outBuf else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(bgra, [])
        do {
            let floats  = CVPixelBufferGetBaseAddress(depthMap)!.assumingMemoryBound(to: Float32.self)
            let bytes   = CVPixelBufferGetBaseAddress(bgra)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(bgra)
            for y in 0..<depthH {
                for x in 0..<depthW {
                    let v    = UInt8(max(0, min(1, 1 - floats[y * depthW + x] / maxDepth)) * 255)
                    let base = y * rowBytes + x * 4
                    bytes[base]     = v   // B
                    bytes[base + 1] = v   // G
                    bytes[base + 2] = v   // R
                    bytes[base + 3] = 255 // A
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(bgra, [])
        CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)

        // --- Step 2: CIImage + ARKit displayTransform (GPU) ---
        //
        // ARKit image UV: (0,0) at lower-left (y-up).
        // displayTransform maps camera UV → UIKit viewport UV (y-down, upper-left origin).
        //
        // CIImage also uses y-up (lower-left origin), so we must y-flip the
        // displayTransform output to bring it back into CIImage space before scaling.
        //
        //   full = scaleDown · displayTransform · yFlip · scaleUp
        //
        // After CIContext.createCGImage(from:) the y-axis is flipped one final
        // time (CIImage→CGImage), which undoes our yFlip and gives the correct
        // portrait image.

        let scaleDown = CGAffineTransform(scaleX: 1 / CGFloat(depthW),
                                          y:      1 / CGFloat(depthH))
        let yFlip     = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
        let scaleUp   = CGAffineTransform(scaleX: viewportSize.width,
                                          y:      viewportSize.height)
        let fullT     = scaleDown
            .concatenating(displayTransform)
            .concatenating(yFlip)
            .concatenating(scaleUp)

        let ciImage   = CIImage(cvPixelBuffer: bgra).transformed(by: fullT)
        let bounds    = CGRect(origin: .zero, size: viewportSize)

        guard let cg  = ciContext.createCGImage(ciImage, from: bounds) else { return nil }
        return UIImage(cgImage: cg) // .up — already in viewport space
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
