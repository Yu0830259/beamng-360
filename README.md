# BeamNG 360 Surround View Prototype

Experimental BeamNG.drive UI App for building a Mercedes-style 360-degree parking camera system.

## Current version: v0.1

This first prototype provides:

- FRONT camera panel
- REAR camera panel
- LEFT camera panel
- RIGHT camera panel
- Top-down vehicle visualization
- Parking guide graphics
- Layout prepared for future live camera/render-target integration

**Important:** v0.1 is currently a UI prototype. The four panels do not yet display real BeamNG camera feeds.

## Install for testing

Copy the included `ui` directory into a BeamNG mod ZIP while preserving this path:

`ui/modules/apps/SurroundView/`

Then place the ZIP in your BeamNG.drive mods folder, start the game, open UI Apps and look for **Surround View Prototype**.

## Planned work

1. Verify UI App loading in current BeamNG.drive versions.
2. Add Lua-side camera management.
3. Create front/rear/left/right cameras attached to the active vehicle.
4. Investigate render-target/sensor output integration with the UI.
5. Add reverse-gear activation.
6. Add steering-linked parking guidelines.
7. Experiment with perspective correction and bird's-eye stitching.

## Status

Proof of concept — expect changes while BeamNG camera rendering integration is tested.
