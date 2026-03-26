# CLAUDE.md — LiDAR Recorder Project

## Project overview
Native iOS app using rear LiDAR + camera. Currently two branches:

- **`main`** (tagged `alpha`) — point cloud video recorder. Records RGB-coloured 3D point cloud to MP4. **Known bug: recorded video is rotated 90°.** Live preview works. Point cloud follows camera like a live feed.
- **`v2`** (active) — new direction: record **standard RGB video** + **separate depth map video** as two MP4 files, synced frame-for-frame. No point cloud rendering needed.

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
- Branch: currently on `v2`
- Remote: `git@github.com:immanuel-lam/pointcloud-lidar.git` (SSH, key must be loaded)

---

## v2 plan — RGB video + depth map video

### What to build
When user taps record, simultaneously record **two separate MP4 files**:
1. `rgb_<timestamp>.mp4` — standard H.264 colour video from `frame.capturedImage` (YCbCr → BGRA)
2. `depth_<timestamp>.mp4` — grayscale depth map video, each pixel encodes depth (near=white/255, far=black/0), normalised across a configurable range (e.g. 0–5 m)

Both files saved to Photos library on stop.

### Files to create (v2)
```
pointcloud/
├── AR/
│   └── ARSessionManager.swift    — reuse from alpha (same ARKit setup)
├── Recording/
│   ├── DualVideoRecorder.swift   — new: records both streams simultaneously
│   └── PixelBufferPool.swift     — reuse/adapt from alpha
├── UI/
│   ├── CameraPreviewView.swift   — new: shows live RGB camera feed
│   └── ControlBar.swift          — simpler than alpha (just record + timer)
└── ContentView.swift             — new root view
```

### Key implementation notes for v2

**RGB video**: `frame.capturedImage` is a YCbCr 4:2:0 CVPixelBuffer. Convert to BGRA before encoding:
- Use `vImageConvert_YpCbCrToARGB_GenerateConversion` from Accelerate, or
- Use a `CIContext` with `CIFilter` (simpler but slower), or
- Use `AVCaptureVideoDataOutput` instead of ARKit for the RGB stream (cleanest)

Actually simplest: use `VTPixelTransferSession` or just pass the YCbCr buffer directly since `AVAssetWriterInput` accepts `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`.

**Depth map video**: `frame.sceneDepth?.depthMap` is `kCVPixelFormatType_DepthFloat32`.
- Normalise each Float32 pixel: `pixel_u8 = clamp(1 - depth/maxDepth, 0, 1) * 255`
- Output as `kCVPixelFormatType_32BGRA` grayscale (R=G=B=pixel_u8)
- Max depth configurable, default 5 m

**Synchronisation**: Both recorders use the same `frame.timestamp` as presentation time — guaranteed sync.

**Camera preview**: Use `ARSCNView` or a simple Metal blit of `frame.capturedImage` to an MTKView, or use `UIImageView` updated each frame (simplest for v2).

**No Metal rendering needed** — v2 doesn't render a point cloud, so no Metal shaders required.

### Permission keys already in Info.plist
- `NSCameraUsageDescription` ✓
- `NSMicrophoneUsageDescription` ✓
- `NSPhotoLibraryAddUsageDescription` ✓

---

## alpha branch known issues (do not fix on v2 branch)
1. **Video rotated 90°** — `AVAssetWriterInput` needs `transform = CGAffineTransform(rotationAngle: .pi / 2)` when drawable is portrait, or the drawable dimensions may be landscape (need to verify with print). To debug: add `print("Recording at \(w)x\(h)")` in `VideoRecorder.startRecording`.
2. **Confidence filter** — currently `>= medium`. Could go lower for denser point clouds.

## ARKit depth notes
- `frame.sceneDepth` — raw depth, lower latency
- `frame.smoothedSceneDepth` — temporally smoothed, less flicker
- `depthMap` format: `kCVPixelFormatType_DepthFloat32`, landscape orientation (~256×192 on iPhone 16 Pro Max)
- `confidenceMap` format: `kCVPixelFormatType_OneComponent8`, values 0=low, 1=medium, 2=high
- Intrinsics (`frame.camera.intrinsics`) are for the RGB camera resolution — MUST scale to depth map resolution before using for depth unprojection
- Both depth map and capturedImage are in **landscape** orientation regardless of device orientation
