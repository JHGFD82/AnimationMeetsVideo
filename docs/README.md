# Design docs

Design notes for AnimationMeetsVideo. Each document says whether it
describes something that exists today or a planned design. Unless a
document says otherwise, treat it as **planned, not implemented**.

| Document | Covers |
| --- | --- |
| [scene-cuts.md](scene-cuts.md) | Detecting scene cuts in a media file and treating each scene as a virtual clip in the browser, without touching the file. |
| [media-replacement.md](media-replacement.md) | Replacing a file with a different version ("bait and switch"), the reference data that makes it safe, and how mismatches are handled. |
| [project-package.md](project-package.md) | The on-disk project format: a package folder with a JSON project file, assets, reference data, and a render cache. |

## Shared principles

- **Media files are never modified.** Everything the app learns about a
  file (scene cuts, thumbnails, signatures) is stored as metadata next to
  the project, never in or beside the original footage.
- **Storage is a first-class concern.** The app does not generate proxy or
  transcoded copies of footage. Anything it stores per asset is small, and
  disposable data is kept separate from data that cannot be regenerated.
- **The person is responsible for the footage.** The app detects and reports
  mismatches, auto-adjusts what is safe to adjust, and only blocks on
  things that would silently break sync.
- **Open and hand-editable.** Project data is plain text with stable IDs, so
  it can be read, diffed, and edited outside the app.
