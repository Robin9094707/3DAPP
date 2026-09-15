# RJ Spatial

Native iPhone and iPad app for RoomPlan room scanning, AR measurements and LiDAR surface meshes. German interface, local storage, no account, no subscription and no third-party analytics.

## New in 2.0 — photo rooms and objects

### Photo room & walkthrough

The separate **Foto-Raum & Rundgang** mode records an ARKit scene mesh together with calibrated camera keyframes and synchronized scene depth. It assigns each observed triangle to a suitable photo using camera projection, viewing angle, distance and depth visibility checks. Unobserved triangles remain neutral rather than receiving invented textures. This is projective image texturing, not neural rendering or room photogrammetry; seams, holes and reflective-surface errors can remain.

The detail preset retains up to 80 camera images, at up to 1920 pixels wide, and approximately 600,000 mesh vertices. The balanced preset retains 48 images at up to 1280 pixels and approximately 350,000 vertices. The supported 30 fps camera formats come from ARKit; this does not enable unrestricted 48 MP recording. Poor tracking, fast movement, low light and serious thermal pressure prevent automatic photo capture. Native depth confidence and depth agreement reject unsuitable texture samples.

Open the project to rotate the textured model, enter a free walkthrough with a thumb joystick and drag-to-look, adjust eye height, or jump to a recorded photo viewpoint. Movement is free navigation without collision detection. Viewpoints and raw room pictures are available in a gallery. The visible model can be shared as a PNG screenshot. A portable textured OBJ/MTL/JPEG package can be exported as a ZIP from the viewer. The image-texture percentage describes assigned mesh triangles, **not** measurement accuracy or room completeness.

### Object photo scan

**Objekt-Fotoscan** uses Apple's `ObjectCaptureSession` and `ObjectCaptureView`, followed by local `PhotogrammetrySession` reconstruction. It supports automatic and additional manual shots, bounding-box selection, repeated scan passes at different heights, and an explicit flipped-object pass for suitable objects. Optional high feature sensitivity and foreground masking are exposed. On-device input-image limits are respected.

iOS currently supports the `.reduced` reconstruction detail tier. The app uses that supported tier; it does not promise desktop raw-quality geometry on an iPhone. The output is a genuinely textured USDZ object, with native 3D viewing, screenshot sharing and AR viewing through Quick Look. For a scooter, keep the object stationary and photograph it from several heights with clearance around it; thin, shiny or low-texture parts may be incomplete.

Original object input images and checkpoints remain in Documents/ObjectDrafts until the completed model and its inputs move together into the project directory. A failed or interrupted reconstruction can be restarted from saved drafts in the object mode. Reconstruction stops on backgrounding; the photos are kept. Unneeded drafts can be deleted in that mode. The original input dataset can be exported with the model as a streaming ZIP for later desktop processing. A large ZIP is an export package, not an in-app import format.

### Compatibility and validation

Version 1 projects remain readable: photo metadata is an optional addition to the existing schema. JSON project archives include room textures and model data. Object JSON archives include the USDZ, **not** the original reconstruction inputs; the ZIP export retains those. JSON export limits photo assets to 100 MB before base64 encoding, and JSON import retains the existing 150 MB limit. ZIP export is streamed and rejects classic ZIP limits above 4 GB.

The 1.0 PDF compiler fix is retained. Room-height estimation now averages the two middle values for an even wall count. The IPA workflow still builds an unsigned arm64 Release IPA. Actual color alignment, LiDAR quality, memory behavior and object reconstruction must be checked on a compatible physical device.

Apple references: [Object Capture](https://developer.apple.com/documentation/realitykit/objectcapturesession), [supported photogrammetry detail levels](https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/detail), and [ARFrame camera images](https://developer.apple.com/documentation/arkit/arframe/capturedimage).

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
