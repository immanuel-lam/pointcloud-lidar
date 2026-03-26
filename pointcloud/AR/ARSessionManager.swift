//
//  ARSessionManager.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

import ARKit
import Combine

@MainActor
final class ARSessionManager: NSObject, ObservableObject {

    let session = ARSession()

    /// Publishes `true` once we've confirmed LiDAR is available on this device.
    @Published private(set) var isSupported: Bool = false

    /// Called on every new ARFrame from the AR session delegate.
    var onFrame: ((ARFrame) -> Void)?

    override init() {
        super.init()
        isSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        session.delegate = self
    }

    func start() {
        guard isSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        session.pause()
    }
}

// MARK: - ARSessionDelegate

extension ARSessionManager: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let callback = MainActor.assumeIsolated { self.onFrame }
        callback?(frame)
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        print("ARSession error: \(error.localizedDescription)")
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        print("ARSession interrupted")
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated { self.start() }
    }
}
