# CLAUDE.md — LiDAR Recorder Project

## Project overview
Native iOS app using rear LiDAR + camera. Two branches:

- **`v1`** (tagged `alpha`) — point cloud video recorder. Records RGB-coloured 3D point cloud to MP4. **Known bug: recorded video is rotated 90°.** Live preview works. Point cloud follows camera like a live feed. **Archived — do not develop here.**
- **`main`** (active) — records **standard RGB video** + **separate depth map video** as two MP4 files, synced frame-for-frame. No point cloud rendering needed. **All work happens here.**

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

## main branch plan — RGB video + depth map video

### What to build
When user taps record, simultaneously record **two separate MP4 files**:
1. `rgb_<timestamp>.mp4` — standard H.264 colour video from `frame.capturedImage` (YCbCr)
2. `depth_<timestamp>.mp4` — greyscale depth map video, each pixel encodes depth (near=white/255, far=black/0), normalised over a configurable range (default 0–5 m)

Both files saved to Photos library on stop.

### Files to create
```
pointcloud/
├── AR/
│   └── ARSessionManager.swift    — reuse from v1 (same ARKit setup)
├── Recording/
│   ├── DualVideoRecorder.swift   — records both streams simultaneously
│   └── PixelBufferPool.swift     — reuse/adapt from v1
├── UI/
│   ├── CameraPreviewView.swift   — shows live RGB camera feed (MTKView blit or ARSCNView)
│   └── ControlBar.swift          — record button + timer
└── ContentView.swift             — root view
```

### Key implementation notes

**RGB video**: `frame.capturedImage` is `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`.
Pass it directly to `AVAssetWriterInput` — no conversion needed, H.264 accepts YCbCr natively.
Set `AVVideoColorPropertiesKey` if colour accuracy matters.

**Depth map video**: `frame.sceneDepth?.depthMap` is `kCVPixelFormatType_DepthFloat32` (landscape ~256×192).
- Normalise: `pixel_u8 = UInt8(clamp(1 - depth/maxDepth, 0, 1) * 255)`
- Write as `kCVPixelFormatType_32BGRA` greyscale (R=G=B=pixel_u8, A=255)
- Max depth configurable, default 5 m

**Video orientation**: Set `input.transform = CGAffineTransform(rotationAngle: .pi / 2)` on BOTH `AVAssetWriterInput`s — this is required for portrait video on iOS to display correctly in AE and Photos without rotation.

**Synchronisation**: Both recorders use the same `frame.timestamp` as presentation time — guaranteed sync.

**Camera preview**: Blit `frame.capturedImage` to an MTKView each frame using a simple Metal blit pipeline, OR use `ARSCNView`/`ARCoachingOverlayView`. MTKView blit is cleanest.

**No Metal point cloud rendering needed** — v1 shaders/renderer can be deleted.

### Permission keys already in pbxproj
- `NSCameraUsageDescription` ✓
- `NSMicrophoneUsageDescription` ✓
- `NSPhotoLibraryAddUsageDescription` ✓

---

## ARKit depth notes
- `frame.sceneDepth` — raw depth, lower latency
- `frame.smoothedSceneDepth` — temporally smoothed, less flicker
- `depthMap` format: `kCVPixelFormatType_DepthFloat32`, landscape orientation (~256×192 on iPhone 16 Pro Max)
- `confidenceMap` format: `kCVPixelFormatType_OneComponent8`, values 0=low, 1=medium, 2=high
- Both depth map and capturedImage are in **landscape** orientation regardless of device orientation
- Intrinsics (`frame.camera.intrinsics`) are for the RGB camera resolution — scale to depth map res if needed for 3D math

## v1 known issues (archived, for reference)
1. **Video rotated 90°** — `AVAssetWriterInput.transform` was never set. Fix: `input.transform = CGAffineTransform(rotationAngle: .pi / 2)` for portrait.
2. Point cloud rendering worked but was computationally heavy.
