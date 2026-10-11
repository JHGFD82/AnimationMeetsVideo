# Animation Meets Video

Native macOS video animation and editing foundation for Apple silicon.

## Direction

The application is intentionally built around system frameworks so it can scale
from an editor shell into a high-performance media tool:

- **SwiftUI** for the native editor interface and non-destructive controls.
- **AVFoundation/CoreMedia** for media assets, timelines, timebases, and export.
- **Metal/MetalKit** for the preview and future vector, compositing, and effects
  pipelines.
- **Core Image, Vision, and Accelerate** are planned integration points for
  auto-matting, image processing, and color workflows.

The initial project includes a runnable editor shell with a library, viewer,
inspector, and timeline. The media items are demo data until import and project
persistence are implemented.

## Requirements

- macOS 15 or newer
- Xcode with the macOS 27 SDK
- Apple silicon recommended; the renderer is designed for Metal-capable Macs

## Run

Open `Package.swift` in Xcode and run the `AnimationMeetsVideo` scheme, or use:

```sh
swift run
```

## Planned milestones

1. Import and persist media assets and project metadata.
2. Build a frame-accurate, multi-track timeline and ProRes-preserving export.
3. Add HDR-aware color management and Metal compositing.
4. Add Vision-backed auto-matting and vectorization experiments.
5. Add editable vector strokes, fills, gradients, patterns, and live text effects.
