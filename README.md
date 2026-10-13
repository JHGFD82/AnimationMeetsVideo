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

macOS-only is a deliberate constraint: the UI can assume a resizable, chrome-rich
single-window editor (no touch-first compromises), and it can lean on
`NSScreen`/multi-window APIs to treat a second display as a dedicated,
full-screen viewport rather than squeezing everything onto one panel.

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

0. **Foundation (done).** Editor shell, demo project model, placeholder Metal
   preview view.

1. **Real media I/O.** Replace demo data with actual import via
   `AVAsset`/`AVAssetReader`; drive the viewer and timeline from real clip
   metadata (duration, frame rate, codec, color space). Persist projects to
   disk (Codable project file referencing media by security-scoped bookmark).

2. **Assembly + ProRes export.** Multi-track timeline backed by
   `AVMutableComposition` (video/audio tracks, trim, reorder, split). Export
   via `AVAssetExportSession`/`AVAssetWriter` with ProRes 422/4444 presets,
   relying on M2 Max's hardware ProRes encode/decode. This is the first
   milestone that produces a usable edit-and-export loop.

3. **Dual-display viewer.** `NSScreen`-aware full-screen output window for an
   external display, playhead-synced with the main editor, plus a lightweight
   freehand draw-over/annotation layer for review and directing. This is
   scoped as simple markup ink, not the full vector engine from milestone 8 —
   it exists so the editor is useful on a two-monitor desk early.

4. **HDR color pipeline.** Metal preview path driven by `rgba16Float`
   textures, EDR-aware `MTKView` configuration, and CoreVideo/ColorSync tagging
   so Rec. 2020 PQ/HLG sources preview and export without clipping. Applies to
   both the main viewer and the milestone-3 external display.

5. **Auto-matting.** Vision-backed foreground/person segmentation
   (`VNGenerateForegroundInstanceMaskRequest`) exposed as a non-destructive
   clip effect, composited in the Metal pipeline rather than baked into
   pixels.

6. **Non-destructive text effects.** Live CoreText/attributed text layers with
   effects (stroke, glow, gradient fill, etc.) applied as Metal
   shaders/layer filters — text stays editable and re-flowable, never
   converted to outlines.

7. **Foundational polish & integration.** Deliberately placed *before* the two
   highest-risk R&D milestones: undo/redo across milestones 1–6, project
   templates, performance tuning for 4K/HDR/ProRes timelines, window/display
   management hardening, and editor UX passes (multi-select, snapping,
   keyboard shortcuts). The goal is a solid, shippable "basic" editor before
   taking on the hard work below.

8. **Vector animation engine.** The biggest build: a custom scene graph for
   paths with multiple strokes, solid/gradient/pattern fills, keyframed over
   time, rendered on Metal. This is effectively a small vector-illustration
   engine in its own right and should be scoped and prototyped independently
   of the editor shell before deep integration. Later reconciles with the
   milestone-3 annotation layer.

9. **Video vectorization.** Frame-by-frame raster-to-vector conversion
   (edge/contour extraction, e.g. Core Image + Accelerate feeding a
   potrace-style tracer) that emits paths into the milestone-8 vector engine.
   Highest R&D risk in the project; plan for throwaway prototypes.

10. **Final polish & integration.** Undo/redo and UX passes extended to cover
    the vector engine and vectorization, end-to-end performance pass across
    the full feature set.
