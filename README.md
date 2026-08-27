# BeamNG 360 Surround View Prototype

Experimental BeamNG.drive UI App for building a Mercedes-style 360-degree parking camera system.

## Current version: v0.2.1

Current prototype provides:

- FRONT camera panel
- REAR camera panel
- LEFT camera panel
- RIGHT camera panel
- Top-down vehicle visualization
- Parking guide graphics
- Layout prepared for future live camera/render-target integration

**Important:** this is still a UI prototype. The four panels do not yet display real BeamNG camera feeds.

## Important: correct ZIP structure

BeamNG requires the mod ZIP to have `ui` at the ZIP root.

Correct:

```text
beamng-360.zip
└─ ui
   └─ modules
      └─ apps
         └─ SurroundView
            ├─ app.json
            ├─ app.js
            ├─ app.html
            └─ app.css
```

Incorrect:

```text
beamng-360-main.zip
└─ beamng-360-main
   └─ ui
      └─ modules
```

GitHub's normal **Download ZIP** adds the repository folder around the files, so do not place that ZIP directly into BeamNG's mods folder.

## Easiest test method

1. Download or clone this repository.
2. Open the repository folder.
3. Select the `ui` folder itself.
4. Compress **the `ui` folder** into a new ZIP named `beamng-360.zip`.
5. Open the ZIP and verify the first thing you see is `ui`.
6. Put `beamng-360.zip` in the current BeamNG user folder's `mods` directory.
7. Start/restart BeamNG.drive.
8. Open `UI Apps` → `Add App` and search for `Surround View Prototype`.

For development, another easy method is to copy `SurroundView` directly to:

```text
<Userfolder>/ui/modules/apps/SurroundView/
```

BeamNG's UI app documentation uses this user-folder method for testing custom apps.

## v0.2.1 compatibility changes

- Uses `restrict: 'EA'` for the AngularJS directive.
- Adds isolated app scope expected by common BeamNG UI app examples.
- Keeps `directive` and `domElement` names matched exactly.
- Adds current UI app metadata/category fields.
- Removes the unnecessary extra category from the manifest.

## Planned work

1. Confirm the UI selector loads the app on the target BeamNG version.
2. Add Lua-side camera management.
3. Create front/rear/left/right cameras attached to the active vehicle.
4. Investigate render-target/sensor output integration with the UI.
5. Add reverse-gear activation.
6. Add steering-linked parking guidelines.
7. Experiment with perspective correction and bird's-eye stitching.
