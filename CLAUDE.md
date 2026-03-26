# CLAUDE.md — LiDAR Recorder Project

## Project overview
Native iOS app using rear LiDAR + camera. Three branches:

- **`v1`** (tagged `alpha`) — point cloud video recorder. Archived — do not develop here.
- **`main`** (active) — records RGB video + depth map video as two synced MP4s. Live depth overlay for preview. **All production work happens here.**
- **`guided-upsampling`** — experiment: use RGB frame as edge guide to upsample 256×192 depth to full camera resolution before recording/display.
- **`smoothed-depth`** — experiment: switch recorder and overlay to `frame.smoothedSceneDepth` instead of `frame.sceneDepth` for temporally stabilised depth with less flicker.

## Xcode project
- Path: `/Users/immanuellam/Documents/pointcloud/pointcloud.xcodeproj`
- Bundle ID: `com.immanuel.pointcloud`
- Team: `6NX7WN475L` (Immanuel Lam personal)
- Deployment target: iOS 26.2
- Uses `GENERATE_INFOPLIST_FILE = YES` and `PBXFileSystemSynchronizedRootGroup` — all new files in `pointcloud/` are auto-included, no pbxproj edits needed for source files
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — all types are implicitly `@MainActor`. Use `nonisolated` explicitly when calling from background threads
- Device for testing: **iPhone 16 Pro Max**, UDID `00008140-000859DE3AC0801C`

## Building & deploying
```bash
# Build
xcodebuild -project pointcloud.xcodeproj -scheme pointcloud \
  -destination 'id=00008140-000859DE3AC0801C' -configuration Debug build

# Install
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/pointcloud-*/Build/Products/Debug-iphoneos -name "pointcloud.app" | head -1)
xcrun devicectl device install app --device 00008140-000859DE3AC0801C "$APP_PATH"

# Launch
xcrun devicectl device process launch --device 00008140-000859DE3AC0801C com.immanuel.pointcloud
```

## Adding Info.plist keys (no standalone plist file)
Use Python to edit the pbxproj directly (tabs matter — use Python, not the Edit tool):
```python
python3 -c "
content = open('pointcloud.xcodeproj/project.pbxproj').read()
old = '\t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;'
new = old + '\n\t\t\t\tINFOPLIST_KEY_YOUR_KEY = \"Your description.\";'
open('pointcloud.xcodeproj/project.pbxproj', 'w').write(content.replace(old, new))
"
```

## Git workflow
- Commit after every meaningful change — user tracks progress this way
- Push to `origin` after each commit or logical group
- Active branch: **`main`**
- Remote: `git@github.com:immanuel-lam/pointcloud-lidar.git`
- `gh` CLI is installed and authenticated as `immanuel-lam`

---

## What main does (implemented)

Records two synced MP4s when user taps record:
1. `rgb_<timestamp>.mp4` — H.264 colour video from `frame.capturedImage` (YCbCr passthrough)
2. `depth_<timestamp>.mp4` — greyscale depth map (near=white, far=black), normalised over configurable range (default 0–5 m)

Both saved to Photos on stop. Live depth matte overlay toggled by eye button in ControlBar.

## Current file structure

```
pointcloud/
├── AR/
│   └── ARSessionManager.swift       — ARKit session, LiDAR config, onFrame callback
├── Recording/
│   └── DualVideoRecorder.swift      — two simultaneous AVAssetWriters (RGB + depth)
│                                       lazy writer setup on first frame (reads actual dims)
│                                       depth: Float32 → BGRA CPU loop on recordingQueue
│                                       both inputs: transform = .pi/2 for portrait
├── UI/
│   ├── CameraPreviewView.swift      — ARSCNView UIViewRepresentable (live camera preview)
│   └── ControlBar.swift             — record button, timer, maxDepth slider, eye toggle
└── ContentView.swift                — root view + DepthOverlayProcessor + DepthOverlayView
```

## Key implementation decisions

**Camera preview**: ARSCNView (not MTKView). Handles camera feed display automatically.

**Depth overlay**: `DepthOverlayProcessor` generates UIImages on a background queue.
Writes directly to a `weak UIImageView` reference (via `DepthOverlayView` UIViewRepresentable)
— **not** `@Published` — to avoid 60fps SwiftUI re-renders breaking ControlBar gestures.

**Depth overlay display transform**: uses `UIImage(cgImage:, orientation: .right)` to rotate
the landscape depth map to portrait. Not pixel-perfect aligned with ARSCNView — close enough
for use as a reference overlay, final work done in AE.

**Depth source**: currently `frame.sceneDepth` (raw, lower latency).
`frame.smoothedSceneDepth` is also available (temporally smoothed, same resolution).

**Depth resolution**: hardware-limited to ~256×192 on iPhone 16 Pro Max. Cannot be increased
via ARKit or AVFoundation — both use the same LiDAR sensor.

**Concurrency pattern**: ARKit calls `session(_:didUpdate:)` on the main thread.
`onFrame` callback runs on main. Heavy work (depth conversion, writing) dispatched to
`DispatchQueue` with `.userInitiated` QoS. `@preconcurrency import AVFoundation` suppresses
pre-concurrency warnings.

---

## ARKit depth notes
- `frame.sceneDepth` — raw depth, lower latency
- `frame.smoothedSceneDepth` — temporally smoothed, less flicker, same resolution
- `depthMap` format: `kCVPixelFormatType_DepthFloat32`, landscape ~256×192 on iPhone 16 Pro Max
- `confidenceMap` format: `kCVPixelFormatType_OneComponent8`, values 0=low, 1=medium, 2=high
- Both depthMap and capturedImage are in **landscape** orientation regardless of device orientation
- ARSessionManager already requests both `.sceneDepth` and `.smoothedSceneDepth` semantics

## Experiment branch notes

### guided-upsampling
Goal: upsample 256×192 depth to full RGB camera resolution before recording/display.
Approach: joint bilateral upsampling — for each output pixel, compute a weighted average of
nearby depth samples, weighted by depth similarity AND RGB colour similarity (edges in RGB
indicate depth discontinuities). Implementable as a Metal compute shader.
Key inputs: `frame.sceneDepth.depthMap` (256×192 Float32) + `frame.capturedImage` (YCbCr).
Key challenge: need to scale camera intrinsics from RGB res to depth res for correct mapping.

### smoothed-depth
Goal: use `frame.smoothedSceneDepth?.depthMap` everywhere instead of `frame.sceneDepth`.
Changes needed: `DualVideoRecorder.appendFrame` and `DepthOverlayProcessor.process` —
swap `.sceneDepth` for `.smoothedSceneDepth`. One-line change in each.
