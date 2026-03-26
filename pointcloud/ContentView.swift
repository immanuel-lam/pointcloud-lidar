//
//  ContentView.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

import SwiftUI
import ARKit
import AVFoundation

@MainActor
struct ContentView: View {

    @StateObject private var arSession = ARSessionManager()
    @StateObject private var recorder  = DualVideoRecorder()

    @State private var showSavedToast = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if arSession.isSupported {
                CameraPreviewView(session: arSession.session)
                    .ignoresSafeArea()
                    .onAppear {
                        setupFrameCallback()
                        requestCameraAndStartAR()
                    }
                    .onDisappear {
                        arSession.pause()
                    }

                ControlBar(
                    isRecording:    .init(get: { recorder.isRecording }, set: { _ in }),
                    maxDepth:       Binding(
                                        get: { recorder.maxDepth },
                                        set: { recorder.maxDepth = $0 }),
                    showSavedToast: showSavedToast,
                    onRecordToggle: toggleRecording
                )
            } else {
                UnsupportedDeviceView()
            }
        }
        .background(Color.black)
        .onChange(of: recorder.savedToPhotos) { _, saved in if saved { showToast() } }
    }

    // MARK: - Setup

    private func setupFrameCallback() {
        arSession.onFrame = { [weak recorder] frame in
            recorder?.appendFrame(frame)
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
        if recorder.isRecording {
            recorder.stopRecording()
        } else {
            recorder.startRecording()
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
