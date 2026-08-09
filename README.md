# EagleGaze

EagleGaze is an experimental two-app system that uses an iPhone's ARKit face
and eye estimates as coarse gaze input for a Mac. It renders a gaze dot and
measures a 3x3 target hit rate; it intentionally does not control the macOS
pointer.

> [!IMPORTANT]
> This is a feasibility prototype, not an accessibility device or a precise
> eye tracker. Do not rely on it for safety-critical input.

## Repository status

- **Stage:** experimental MVP
- **Platforms:** iOS 17+ and macOS 14+
- **Transport:** direct local-network UDP discovered through Bonjour
- **Cloud dependency:** none
- **Storage:** gaze samples are not persisted

## Success gate

At roughly 50–75 cm, with the iPhone rigidly mounted below the display's center
and its front camera aimed at the user, the separate evaluation run should identify the intended 3x3 cell at
least 90% of the time under modest natural head movement.

## Data flow

1. `EagleGazePhone` keeps an ARKit face-tracking session active in the foreground.
2. It advertises no service and discovers `_eagle-gaze._udp` receivers with Bonjour.
3. It sends versioned, timestamped gaze datagrams directly to the Mac over the
   local network. No cloud service is involved.
4. `EagleGazeMac` advertises the receiver, presents nine calibration targets
   across the entire Mac display, fits a 2D affine mapping, and renders a
   smoothed, click-through gaze dot above other Mac apps.

## Run

1. Open `EagleGaze.xcodeproj` in Xcode.
2. Build and run `EagleGazeMac` on the Mac.
3. Select the `EagleGazePhone` scheme, choose a supported physical iPhone, and
   configure the signing team if Xcode requests it. ARKit face tracking does not
   work in Simulator.
4. Allow local-network access on both devices and camera access on the phone.
5. Mount the phone directly below the display center with its front camera near
   the lower bezel and aimed at the user, about 60 cm away, then follow the Mac
   calibration prompts. Keep looking at each teal target until it advances on
   its own. After calibration, use **Show gaze dot over Mac apps** to toggle the
   system-wide indicator; choose **Recalibrate** whenever the phone, display,
   chair, or viewing distance moves.

Both devices should be on the same local network. The Network framework also
allows Apple peer-to-peer discovery when infrastructure Wi-Fi is unavailable.
The phone app must remain in the foreground because backgrounding interrupts
camera-based ARKit tracking.

## Verify without a phone

The wire format, packet gate, affine fit, and smoothing are a standalone Swift
package:

```sh
cd Packages/GazeCore
swift test
```

App compilation can be checked with Xcode:

```sh
xcodebuild -project EagleGaze.xcodeproj -scheme EagleGazeMac \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project EagleGaze.xcodeproj -scheme EagleGazePhone \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Privacy boundary

Gaze and face-derived transforms leave the phone only to provide this feature
to the paired local Mac. The MVP does not store samples or send them to a cloud
service. Any distributable version needs an explicit face-data disclosure and
consent flow before transmission.

See [PRIVACY.md](PRIVACY.md) for the full data boundary and [SECURITY.md](SECURITY.md)
for reporting security or privacy issues.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The highest-value early contributions
are measurement methodology, calibration robustness, accessibility review, and
privacy-preserving transport improvements.
