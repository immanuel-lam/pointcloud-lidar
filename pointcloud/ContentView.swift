//
//  ContentView.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

import SwiftUI
import MetalKit
import ARKit

@MainActor
struct ContentView: View {

    @StateObject private var arSession  = ARSessionManager()
    @StateObject private var recorder   = VideoRecorder(width: 1920, height: 1080, fps: 30)

    @State private var renderer: MetalRenderer?
    @State private var mtkView  = MTKView()

    @State private var pointSize: Float  = 6.0
    @State private var subsampleStep     = 4
    @State private var showSavedToast    = false
    @State private var showSettings      = false
    @State private var settings          = RecordingSettings()

    private let processor = DepthFrameProcessor()

    var body: some View {
        ZStack(alignment: .bottom) {
            if arSession.isSupported {
                // Full-screen Metal view
                MetalViewWrapper(mtkView: mtkView)
                    .ignoresSafeArea()
                    .onAppear {
                        setupRenderer()
                        arSession.start()
                    }
                    .onDisappear {
                        arSession.pause()
                    }

                // Settings button
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gear")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .padding(.trailing, 20)
                        .padding(.top, 60)
                    }
                    Spacer()
                }
                .ignoresSafeArea()

                // HUD overlay
                ControlBar(
                    isRecording:   .init(get: { recorder.isRecording },
                                         set: { _ in }),
                    pointSize:     $pointSize,
                    subsampleStep: $subsampleStep,
                    showSavedToast: showSavedToast,
                    onRecordToggle: toggleRecording
                )
            } else {
                UnsupportedDeviceView()
            }
        }
        .background(Color.black)
        .onChange(of: pointSize) { _, size in
            renderer?.pointSize = size
        }
        .onChange(of: subsampleStep) { _, step in
            processor.subsampleStep = step
        }
        .sheet(isPresented: $showSettings) {
            SettingsPanel(settings: $settings)
        }
    }

    // MARK: - Setup

    private func setupRenderer() {
        guard renderer == nil else { return }
        guard let r = MetalRenderer(mtkView: mtkView) else { return }
        renderer = r

        let proc    = processor
        let mtkView = mtkView

        arSession.onFrame = { [weak r] frame in
            guard let r else { return }
            // Offload heavy depth processing off the main thread
            Task.detached(priority: .userInitiated) {
                let vertices = proc.process(frame)
                await MainActor.run {
                    r.currentVertices = vertices
                    r.updateCamera(frame: frame, viewportSize: mtkView.drawableSize)
                }
            }
        }

        r.onFrameRendered = { [weak recorder] texture, time in
            recorder?.appendFrame(texture: texture, at: time)
        }
    }

    // MARK: - Recording

    private func toggleRecording() {
        guard let device = mtkView.device else { return }
        if recorder.isRecording {
            recorder.stopRecording()
            showToast()
        } else {
            recorder.startRecording(device: device)
        }
    }

    private func showToast() {
        withAnimation { showSavedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { showSavedToast = false }
        }
    }
}

// MARK: - MTKView wrapper

struct MetalViewWrapper: UIViewRepresentable {
    let mtkView: MTKView

    func makeUIView(context: Context) -> MTKView {
        mtkView.backgroundColor = .black
        mtkView.isPaused        = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
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
