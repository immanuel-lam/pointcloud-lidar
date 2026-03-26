//
//  SettingsPanel.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

import SwiftUI

struct RecordingSettings {
    enum Resolution: String, CaseIterable, Identifiable {
        case hd   = "1080p HD"
        case uhd  = "4K UHD"
        var id: String { rawValue }
        var size: (width: Int, height: Int) {
            switch self {
            case .hd:  return (1920, 1080)
            case .uhd: return (3840, 2160)
            }
        }
    }

    var resolution: Resolution = .hd
    var fps: Int = 30
    var useSmoothedDepth: Bool = true
    var dotOpacity: Float = 1.0
}

struct SettingsPanel: View {

    @Binding var settings: RecordingSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Output") {
                    Picker("Resolution", selection: $settings.resolution) {
                        ForEach(RecordingSettings.Resolution.allCases) { res in
                            Text(res.rawValue).tag(res)
                        }
                    }

                    Picker("Frame Rate", selection: $settings.fps) {
                        Text("24 fps").tag(24)
                        Text("30 fps").tag(30)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Depth") {
                    Toggle("Smoothed Depth", isOn: $settings.useSmoothedDepth)
                    Text("Smoothed depth reduces flicker but may lag slightly behind fast motion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Appearance") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dot Opacity: \(Int(settings.dotOpacity * 100))%")
                            .font(.subheadline)
                        Slider(value: $settings.dotOpacity, in: 0.2...1.0)
                    }
                }

                Section("After Effects Tips") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• Import the MP4 normally into AE.")
                        Text("• Use Blending Mode: Screen or Add to composite over footage.")
                        Text("• Use Keylight / Extract to key out the black background.")
                        Text("• The point positions are geometrically accurate — 3D Camera Tracker works well on this footage.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
