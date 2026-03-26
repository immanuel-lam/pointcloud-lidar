//
//  CameraPreviewView.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

import SwiftUI
import ARKit
import SceneKit

/// Full-screen live camera preview backed by ARSCNView.
/// Pass in the ARSession from ARSessionManager — the view will render
/// whatever the session produces without any 3D content overlaid.
struct CameraPreviewView: UIViewRepresentable {

    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.scene   = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain  = false
        view.rendersMotionBlur   = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
