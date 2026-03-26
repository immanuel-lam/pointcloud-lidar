# pointcloud-lidar

iOS app for recording LiDAR depth data alongside RGB video on iPhone 12 Pro and later.

**Repo:** https://github.com/immanuel-lam/pointcloud-lidar
**Requires:** iPhone with LiDAR (iPhone 12 Pro+), iOS 16+, Xcode 15+

---

## Branches

| Branch | Status | Description |
|--------|--------|-------------|
| `v1` (tag: `alpha`) | Archived | RGB point cloud video recorder — records the live scene as coloured 3D dots to MP4. Video rotation bug unresolved. |
| `main` | Active development | Records standard RGB camera video + separate greyscale depth map video as two synced MP4 files. |

---

## main — Dual Video Recorder

Records two synced MP4 files simultaneously:

1. **`rgb_<timestamp>.mp4`** — standard H.264 colour video from the camera
2. **`depth_<timestamp>.mp4`** — greyscale depth map (white = near, black = far)

Both saved to Photos on stop.

### After Effects usage
1. Import both MP4 files
2. RGB layer → main footage track
3. Depth layer → use as **Luma Matte**, Z-depth pass, or depth-of-field input

---

## v1 — Point Cloud Recorder (archived)

Records the LiDAR scene as an RGB-coloured point cloud rendered in real time using Metal, written to H.264 MP4. Black background.

### After Effects usage (v1)
1. Import the MP4 (File → Import)
2. Set blending mode to **Screen** or **Add** to composite over footage
3. Use **Keylight** / **Extract** to key out black background
4. **3D Camera Tracker** works — point positions are geometrically accurate

---

## Tech stack

- Swift, SwiftUI
- ARKit (`ARWorldTrackingConfiguration` + `sceneDepth`)
- Metal (v1 only)
- AVFoundation (`AVAssetWriter`)
- iOS 26.2+ deployment target
