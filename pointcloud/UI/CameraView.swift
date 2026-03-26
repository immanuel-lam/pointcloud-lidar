//
//  CameraView.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

import SwiftUI
import MetalKit

struct CameraView: UIViewRepresentable {

    let renderer: MetalRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.backgroundColor = .black
        view.isPaused        = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        // renderer configures the view (device, pixelFormat, delegate) in its own init,
        // but here we pass the existing view in so the renderer can re-set the delegate.
        view.delegate = renderer
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
