# GazeCropKit

`GazeCropKit` is a standalone, independently testable macOS Swift package for
turning a transient gaze fixation into the smallest useful screenshot region.
EagleGazeMac integrates it behind app-owned privacy and approval controls.

## What is included

- a robust, bounded 550 ms attention estimator that keeps fixation evidence
  separate from the smoothing used to animate a gaze dot;
- explicit normalized-display, global-display, captured-image, and crop-image
  coordinate transforms;
- a read-only, geometry-only macOS Accessibility resolver with bounded ancestor
  and relationship queries;
- provider-neutral region selection and a segmentation fallback protocol;
- image-relative crop metadata suitable for approval and downstream models;
- an optional `gemma-4-31b` Cerebras image-enrichment client with strict JSON,
  image limits, prompt-injection framing, response sanitization, and an API key
  supplied per call rather than persisted.

## Privacy boundary

Accessibility is used only to derive geometry and broad roles. The resolver does
not read or export control values, text, URLs, paths, application names, window
titles, identifiers, or actions. `GazeCropEnvelope` contains image-relative
coordinates only.

The Cerebras client is a post-approval option. Crop selection remains fully
local and does not require an external provider. A caller must preview and
approve every outgoing image before calling `enrich(_:apiKey:)`.

API keys must come from an application-owned secret source such as macOS
Keychain or a development-only environment variable. Never place a key in this
package, an Info.plist, UserDefaults, source control, or logs.

## EagleGaze integration

EagleGazeMac now:

1. feed accepted calibrated points into `AttentionEstimator`;
2. freeze an eligible `AttentionSnapshot` when capture is requested;
3. use `CGDisplayBounds` plus the returned screenshot dimensions to construct
   `CaptureGeometry`;
4. request bounded Accessibility candidates and use `RegionSelector`;
5. uses a fixed local context when Accessibility is missing or too coarse; the
   package exposes `SegmentationRegionResolving` for a later on-device visual
   segmentation implementation;
6. create and preview the exact crop and metadata;
7. optionally calls Cerebras only after approval, using a Keychain-held key and
   a clearly disclosed second focus preview.

No Accessibility actions, cursor control, automatic scrolling, full-tree
scraping, silent export, or API-key persistence belong in this package.

## Verify

```sh
cd arkit-mvp/Packages/GazeCropKit
swift test
```
