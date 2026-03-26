# pointcloud-lidar

iOS app for recording LiDAR depth data alongside RGB video on iPhone 12 Pro and later.

**Repo:** https://github.com/immanuel-lam/pointcloud-lidar
**Requires:** iPhone with LiDAR (iPhone 12 Pro+), iOS 16+, Xcode 15+

---

## Branches

| Branch | Status | Description |
|--------|--------|-------------|
| `main` (tag: `alpha`) | Working with bugs | RGB point cloud video recorder — records the scene as coloured 3D dots to MP4. Video rotation bug unresolved. |
| `v2` | In development | Records standard RGB camera video + separate greyscale depth map video as two MP4 files. AE-friendly output. |

---

## v1 / alpha — Point Cloud Recorder

Records the LiDAR scene as an RGB-coloured point cloud rendered in real time using Metal, then writes the result to an H.264 MP4.

**Output:** Single MP4. Black background. Use **Screen** or **Add** blending mode in After Effects. Point positions are geometrically correct — 3D Camera Tracker works well.

**Known issues:**
- Recorded video is rotated 90° (live preview is correct)

---

## v2 — Dual Video Recorder (in development)

Records two synced MP4 files simultaneously:

1. **`rgb_<timestamp>.mp4`** — standard H.264 colour video
2. **`depth_<timestamp>.mp4`** — greyscale depth map (white = near, black = far)

Use the depth video as a Z-depth/luma matte pass in After Effects.

---

## After Effects usage (alpha)

1. Import the MP4 normally (File → Import)
2. Set layer blending mode to **Screen** or **Add** to composite over other footage
3. Use **Keylight** or **Extract** to key out the black background
4. **3D Camera Tracker** works on the footage — point positions are geometrically accurate

## After Effects usage (v2)

1. Import both MP4 files
2. RGB layer goes on main track
3. Depth layer → use as **Luma Matte** or feed into a depth-of-field effect / Z-depth pass

---

## Tech stack

- Swift 5.9, SwiftUI
- ARKit (`ARWorldTrackingConfiguration` + `sceneDepth`)
- Metal (v1 only — point cloud rendering)
- AVFoundation (`AVAssetWriter`)
- iOS 26.2+ deployment target
