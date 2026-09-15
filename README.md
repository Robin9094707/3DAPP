# RJ Spatial

Native iPhone and iPad app for RoomPlan room scanning, AR measurements and LiDAR surface meshes. German interface, local storage, no account, no subscription and no third-party analytics.

## Included in 1.0

- **Room scan:** Apple's guided RoomCaptureView captures walls, doors, windows, openings, floor polygons and furniture categories.
- **Area & volume:** dedicated entry point into room capture with floor area, representative wall height, estimated volume, total wall lengths and gross/net wall areas in the result.
- **Interactive 3D:** orbit, zoom, top view, wireframe, element selection, dimension labels, category visibility and an exploded view. USDZ can also be opened with Apple's AR Quick Look.
- **Floor plan:** vector rendering, wall dimensions, door/window colors, furniture footprints, pinch zoom, pan and element selection.
- **AR measuring:** two-point distances, polylines and horizontal floor polygons, with live raycasts, visible markers, undo, multiple measurements and saved projects.
- **LiDAR surfaces:** live wireframe reconstruction and an untextured triangle mesh exported to OBJ in meters.
- **Project archive:** local atomic saves, search, favorites, sorting, renaming, notes, custom measurement/element names and a manual room-height correction.
- **Exports:** complete JSON archive with import, USDZ for rooms, OBJ for meshes, vector SVG floor plans, paginated PDF reports and CSV measurements in SI units.
- **Appearance:** native Liquid Glass on iOS 26+ when built with Xcode 26+, system materials on iOS 17–18, light/dark/system mode, reduced-transparency support, accessible labels, metric/imperial display and optional haptics.

## Device requirements

iOS 17 or later. RoomPlan and mesh capture require supported LiDAR hardware. The app checks runtime capabilities; AR measuring is available on supported ARKit devices without LiDAR. Camera permission is requested when entering a capture mode. No location permission is required.

## Measurement behavior and limits

These are **sensor-derived estimates**, not certified survey measurements. Floor area uses native floor polygons, with a closed-wall-contour fallback (maximum endpoint gap 25 cm). No bounding-box or convex-hull area is silently substituted for an incomplete contour. Volume is floor area multiplied by the median detected wall height, or the user's height override. Sloping ceilings, obstructions, reflective surfaces and incomplete room scans affect results. Wall-net area subtracts recognized door/window/opening rectangles and is approximate.

Furniture is represented by semantic categories and simplified boxes. The surface scanner creates an **untextured** LiDAR mesh, not a photogrammetry model. Mesh capture stops accepting new data at approximately 400,000 vertices to bound memory. Floors measured manually in AR must be horizontal, with points on the same height within 12 cm; crossing polygons are rejected. Captures interrupted by backgrounding are stopped rather than silently mixing coordinate systems.

Single-room projects are supported. Multiple rooms are separate projects; this version does not stitch a whole building into one coordinate system or resume an old AR session. Measurement and mesh projects retain their geometry for viewing, not an AR relocalization map.

Projects live in the app's Documents/Projects directory and may be included in the user's device backup. Export JSON archives before deleting the app. Sharing is explicit. JSON import creates a new project ID to preserve existing projects. On USDZ conversion failure the native room JSON and measured geometry are still saved.

## Build the IPA

GitHub Actions runs on every push to `main`, and can also be started with **Actions → Build RJ Spatial IPA → Run workflow**.

The workflow uses `macos-26`, the runner's latest stable Xcode, XcodeGen and an arm64 iPhone Release build. It creates the geometric app icon from the checked-in Python script (no Python packages needed), generates the Xcode project, builds without code signing, packages `Payload/RJSpatial.app` and uploads:

**Artifact:** `RJ-Spatial-unsigned-IPA`  
**File:** `RJ-Spatial-unsigned.ipa`

The IPA is **unsigned**, following the existing sideloading workflow. It must be signed with your chosen sideloading/signing tool before installation. No signing certificates or Apple account secrets are stored here. A successful GitHub build checks compilation; LiDAR, camera, recognition quality and interactive rendering require a real-device check.

For a local Mac build:

```sh
brew install xcodegen
python3 Scripts/make_icon.py
xcodegen generate
open RJSpatial.xcodeproj
```

Select your development team to run directly on an iPhone. No external Swift packages are required.

## Source layout

`SpatialApp.swift` (studio/archive/settings), `RoomCapture.swift` (RoomPlan), `ARMeasurement.swift` (raycast measurements), `MeshCapture.swift` (surface scanning), `Models.swift` (geometry/metrics), `ProjectStore.swift` (persistence), `RoomScene.swift` (interactive 3D), `FloorPlan.swift` (vector renderer), `ProjectDetail.swift` (project inspection/editing), `Exporter.swift` (reports), `Design.swift` (shared UI).

Built with [RoomPlan](https://developer.apple.com/documentation/roomplan), [ARKit](https://developer.apple.com/documentation/arkit), SceneKit and SwiftUI. Native glass uses [`glassEffect`](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)).
