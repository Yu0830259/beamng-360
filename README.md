# BeamNG 360 Surround View Prototype

Experimental BeamNG.drive UI App for building a Mercedes-style surround-view parking camera system.

## Current version: v0.4.0

v0.4.0 removes the BeamNG.tech-only Camera Sensor approach and replaces the rear-camera experiment with the retail BeamNG.drive `RenderView` path.

Current prototype provides:

- FRONT camera placeholder
- REAR retail RenderView experiment
- LEFT camera placeholder
- RIGHT camera placeholder
- Top-down vehicle visualization
- Parking guide graphics
- Full in-app status/error diagnostics

## What changed in v0.4.0

The old `tech_sensors.createCamera()` implementation failed in normal BeamNG.drive because the sensor code attempted to access BeamNG.tech-only Research functionality.

The new route uses the retail game-engine RenderView screenshot API instead:

1. Game Engine Lua follows the active vehicle.
2. A generic camera position is calculated behind and above the vehicle.
3. `render_renderViews.takeScreenshot()` renders a 320×180 rear-facing frame.
4. The latest frame is written to `screenshots/beamng-360/rear.png` in the BeamNG user filesystem.
5. The UI App reloads that image approximately four times per second and keeps the previous valid frame while a new PNG is being written.

This is deliberately a first retail-compatible proof of concept, not the final 360° implementation. The screenshot-based path may have more latency and performance cost than a direct render texture.

## Correct ZIP structure

Because v0.4.0 includes Game Engine Lua, both `lua` and `ui` must be at the ZIP root.

```text
beamng-360.zip
├─ lua
│  └─ ge
│     └─ extensions
│        └─ surroundView.lua
└─ ui
   └─ modules
      └─ apps
         └─ SurroundView
            ├─ app.json
            ├─ app.js
            ├─ app.html
            └─ app.css
```

Do **not** put a wrapper such as `beamng-360-main/` around those folders.

## Test procedure

1. Download or clone this repository.
2. Open the repository folder.
3. Select the `lua` and `ui` folders together.
4. Compress those two folders into `beamng-360.zip`.
5. Open the ZIP and confirm its first level contains exactly `lua` and `ui`.
6. Replace the previous BeamNG 360 ZIP in your active BeamNG user folder's `mods` directory.
7. Restart BeamNG.drive.
8. Add **Surround View Prototype** from UI Apps.
9. Check the diagnostic strip near the top of the app.

A successful first test should progress toward `REAR RENDERVIEW READY` and then `REAR RENDERVIEW LIVE` once the UI can load the generated PNG.

## Current limitations

- Rear view currently updates at roughly 4 FPS.
- Generic camera offsets are not calibrated per vehicle.
- The front, left and right camera panels are still placeholders.
- The parking guide lines are not yet steering-linked.
- It does not yet stitch four views into a true bird's-eye image.
- RenderView screenshot capture may cost noticeable performance and writes temporary camera frames to the user screenshots directory.

## Planned work

1. Validate the retail RenderView rear feed on the target BeamNG.drive build.
2. Tune rear-camera position/FOV and orientation.
3. Add reverse-gear activation.
4. Add steering-linked parking guidelines.
5. Experiment with front/left/right RenderViews.
6. Reduce disk/CEF latency or move to a more direct RenderView texture path if practical.
7. Experiment with perspective correction and bird's-eye stitching.
