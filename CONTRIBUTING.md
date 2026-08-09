# Contributing

EagleGaze is an experimental iPhone-to-Mac gaze-tracking prototype. Changes
should preserve its local-only data boundary and distinguish measured results
from assumptions.

## Development setup

1. Use a Mac with Xcode and an ARKit face-tracking-capable iPhone.
2. Run the shared package tests:

   ```sh
   swift test --package-path Packages/GazeCore
   ```

3. Compile both app targets without signing:

   ```sh
   xcodebuild -project EagleGaze.xcodeproj -scheme EagleGazeMac \
     -destination 'platform=macOS' ONLY_ACTIVE_ARCH=YES \
     CODE_SIGNING_ALLOWED=NO build

   xcodebuild -project EagleGaze.xcodeproj -scheme EagleGazePhone \
     -destination 'generic/platform=iOS Simulator' \
     CODE_SIGNING_ALLOWED=NO build
   ```

ARKit face tracking itself requires a supported physical device and does not
run in Simulator.

## Pull requests

- Keep changes focused and include tests for protocol, calibration, filtering,
  or sample-gating behavior.
- Document the device, OS, mounting position, distance, and evaluation method
  behind accuracy claims.
- Do not add analytics, cloud transmission, persistence of gaze samples, or
  cursor injection without an explicit design and privacy review.
- Never commit signing certificates, provisioning profiles, captured face data,
  or Apple account credentials.
