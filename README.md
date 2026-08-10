# EagleEye

[![License: MPL-2.0](https://img.shields.io/badge/License-MPL--2.0-blue.svg)](LICENSE)

EagleEye is an experimental two-app system that uses an iPhone's ARKit face
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
- **Cloud dependency:** none for tracking or cropping; optional user-enabled
  Cerebras enrichment for individually approved captures
- **Storage:** gaze samples are not persisted

## Success gate

At roughly 50–75 cm, with the iPhone rigidly mounted and centered near the
display and its TrueDepth camera aimed at the user, the independent validation
run should identify the intended 3x3 cell at least 90% of the time under modest
natural head movement. Placement is learned by calibration rather than selected
as an above/below mode; moving either device still requires a new acceptance run.

## Data flow

1. `EagleGazePhone` keeps an ARKit face-tracking session active in the foreground.
2. It discovers a nearby Mac through Bonjour, pairs once with a six-digit
   confirmation, and saves that Mac in the device-only Keychain.
3. On later launches it authenticates the saved Mac automatically and sends
   encrypted, versioned gaze datagrams over the local network. No cloud service
   is involved.
4. `EagleGazeMac` presents nine calibration targets, collects only stable
   both-eyes-open samples, fits affine and projective candidates with outlier
   evidence, then checks the winner on five off-grid validation targets. The
   prior saved profile remains active unless the replacement passes.
5. The Mac renders the accepted mapping through a presentation-only 1-Euro
   stabilizer with a dead zone and saccade snapping. Raw samples—not the
   stabilized dot—always drive calibration.

## Calibration acceptance

Each target has a settling period followed by quality-gated collection. Blinks,
limited eye visibility, fast head movement, unstable gaze dispersion, frames
from an earlier tracking run, and frames predating the target epoch do not
advance the target. A failed point is recollected instead of silently entering
the fit. The UI's teal progress ring shows stable collection progress.

After the 3x3 training grid, five spatially distinct targets measure RMS and
worst-case error. A failed validation selectively recollects the nearest weak
training point; a candidate that still fails is rejected without overwriting
the last known-good profile. **Recenter** performs a one-point center correction
for ordinary drift; **Recalibrate** always starts a full new candidate run.

## Rolling attention estimate

The live gaze dot and the attention estimate serve different purposes. The dot
uses an adaptive 1-Euro filter, dead zone, and saccade snapping so it can remain
still during fixation without visibly dragging across a genuine eye jump. Separately,
the Mac keeps an in-memory 550 ms rolling window and reports the coordinate-wise
median as a more stable estimate of where the user has recently been looking.

The window has a hard horizon based on each sample's capture time: samples older
than 550 ms relative to the newest accepted sample are removed, regardless of
packet rate. It expires after a long sample gap and resets when tracking is
lost, the phone starts a new session, or calibration is reset or replaced. This
history is transient and is never persisted or exported as individual samples.
An approved capture may expose only bounded aggregate evidence—sample count,
confidence, coverage duration, newest-sample age, and image-relative
uncertainty—needed to interpret that capture.

The estimate remains a normalized screen location. During an approved capture,
the Mac can combine it with a bounded, geometry-only Accessibility hit test to
select a complete nearby text/control region. It falls back to a fixed local
crop when permission or useful geometry is unavailable.

## Run

1. Open `EagleGaze.xcodeproj` in Xcode.
2. Build and run the `EagleGazeMac` scheme on the Mac. It produces `EagleEye.app`.
3. Select the `EagleGazePhone` scheme, choose a supported physical iPhone, and
   configure the signing team if Xcode requests it. ARKit face tracking does not
   work in Simulator.
4. Allow local-network access on both devices and camera access on the phone.
5. In the iPhone app, choose the nearby Mac. Confirm the same six-digit code on
   the Mac and approve the pairing. This is required only once for that Mac;
   later launches reconnect automatically unless the saved pairing is removed
   or the Mac identity changes.
6. Mount the phone rigidly and centered near the display, with its TrueDepth
   camera aimed at the user about 60 cm away, then follow the Mac
   calibration prompts. Keep looking at each teal target until it advances on
   its own. After calibration, use **Show gaze dot over Mac apps** to toggle the
   system-wide indicator. Use **Recenter** for a small seating shift; choose
   **Recalibrate** whenever the phone, display, chair, or viewing distance moves
   materially. The app also compares live camera/face geometry with the accepted
   profile and prompts after a sustained shift rather than reacting to one frame.
7. Open **Fine alignment and integrations** to control smart cropping, grant
   optional Accessibility geometry access, or save a Cerebras API key in
   Keychain and enable `gemma-4-31b` enrichment. Cerebras is off by default.

Both devices should be on the same local network. The Network framework also
allows Apple peer-to-peer discovery when infrastructure Wi-Fi is unavailable.
The phone app must remain in the foreground because backgrounding interrupts
camera-based ARKit tracking.

## Verify without a phone

The wire format, packet gate, robust affine/projective fitting, transactional
validation, geometry monitor, and smoothing are a standalone Swift package:

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

Those unsigned commands are compile checks only. Run the Mac app through Xcode
or another correctly signed build for live pairing: its App Sandbox network
client/server entitlements are part of the signature. An unsigned sandboxed
build can compile successfully but Bonjour will reject publication with
`NWError NoAuth`.

## Debug logs

EagleGaze uses Apple's unified logging with separate subsystems for the Mac and
iPhone. Logs cover discovery, control connections, pairing approval, saved-pair
authentication, gaze-session activation, calibration run/target epochs,
accepted and rejected sample counts, target retries, fit selection, validation
metrics, geometry prompts, recenter corrections, and teardown. They
intentionally exclude verification codes, cryptographic keys, camera data, and
individual gaze samples.

Tail the Mac app while reproducing a problem:

```sh
log stream --style compact --level debug \
  --predicate 'subsystem == "com.aviary.EagleGazeMac"'
```

Read the Mac app's recent history:

```sh
log show --last 10m --style compact \
  --predicate 'subsystem == "com.aviary.EagleGazeMac"'
```

For a USB-connected iPhone, open **Xcode → Window → Devices and Simulators**,
select the phone, and choose **Open Console**. Start streaming and search for:

```text
subsystem:com.aviary.EagleGazePhone
```

This reads the phone's unified `Logger` events directly over USB. The
`devicectl ... process launch --console` option is still useful for process
stdout/stderr, but it is not a substitute for the unified-log stream above.

## VoiceOS integration

The [`VoiceOS`](VoiceOS) folder is a developer-preview VoiceOS integration. It
runs as a local TypeScript MCP server and talks to the Mac app through a
loopback-only bridge bound to `127.0.0.1:47474`. EagleGazePhone continues to
discover the Mac automatically through Bonjour, so users do not enter an IP
address for either hop.

VoiceOS can report coarse connection/calibration state and, after a confirmation
card, start or reset calibration. It does not receive raw ARKit data or gaze
coordinates. See [`VoiceOS/README.md`](VoiceOS/README.md) for installation and
[`VoiceOS/BOUNDARIES.md`](VoiceOS/BOUNDARIES.md) for the explicit trust and data
boundary.

## Privacy boundary

Gaze and face-derived transforms leave the phone only to provide this feature
to the explicitly paired local Mac. Pairing is the runtime authorization: the
apps save the trusted peer identity, authenticate it again on every launch,
derive fresh encryption keys, and reject an identity mismatch. The MVP does not
store gaze samples or send them to a cloud service.

See [PRIVACY.md](PRIVACY.md) for the full data boundary and [SECURITY.md](SECURITY.md)
for reporting security or privacy issues.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The highest-value early contributions
are measurement methodology, calibration robustness, accessibility review, and
privacy-preserving transport improvements.

## License

Except where otherwise noted, EagleEye is open source under the
[Mozilla Public License 2.0](LICENSE). If you distribute changes to existing
EagleEye source files, those modified files remain available under MPL-2.0;
separate files may be combined into a larger work under other terms. See
[NOTICE](NOTICE) for attribution and trademark information.
