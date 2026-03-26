//
//  ControlBar.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

import SwiftUI

struct ControlBar: View {

    @Binding var isRecording: Bool
    @Binding var maxDepth: Float
    var showSavedToast: Bool

    let onRecordToggle: () -> Void

    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 12) {
            if showSavedToast {
                Text("Saved to Photos")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }

            HStack(spacing: 20) {
                // Max depth slider
                VStack(alignment: .leading, spacing: 2) {
                    Text("Depth: \(String(format: "%.1f", maxDepth)) m")
                        .font(.caption2).foregroundStyle(.white)
                    Slider(value: $maxDepth, in: 1...10, step: 0.5)
                        .frame(width: 110)
                        .tint(.white)
                }

                Spacer()

                // Record button
                Button(action: onRecordToggle) {
                    ZStack {
                        Circle()
                            .strokeBorder(.white, lineWidth: 3)
                            .frame(width: 72, height: 72)
                        if isRecording {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.red)
                                .frame(width: 28, height: 28)
                        } else {
                            Circle()
                                .fill(.red)
                                .frame(width: 56, height: 56)
                        }
                    }
                }

                Spacer()

                // Elapsed timer (right-aligned placeholder so button stays centred)
                VStack(alignment: .trailing, spacing: 2) {
                    if isRecording {
                        Text(formattedElapsed)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }
                .frame(width: 110)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial.opacity(0.8))
        .onChange(of: isRecording) { _, recording in
            if recording {
                elapsed = 0
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in elapsed += 1 }
            } else {
                timer?.invalidate(); timer = nil; elapsed = 0
            }
        }
    }

    private var formattedElapsed: String {
        let h = Int(elapsed) / 3600
        let m = (Int(elapsed) % 3600) / 60
        let s = Int(elapsed) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
