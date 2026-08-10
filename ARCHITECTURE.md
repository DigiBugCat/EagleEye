# EagleGaze production architecture

This document is the boundary contract for the iPhone app, Mac app, shared
package, VoiceOS adapter, and future tracker integrations. Dependencies point
inward toward `GazeCore`; source-specific SDK and transport details never leak
into calibration or presentation code.

## Product invariants

- A Mac may remember multiple paired phones and tracker devices, but exactly one
  gaze source is active for a calibration or evaluation session.
- Switching the active source is explicit. It pauses the current session and
  selects a calibration profile for the new source and display.
- Pairing authenticates a device. Calibration describes a physical setup. They
  are separate records with separate reset and revocation actions.
- Raw ARKit face and eye transforms remain inside the ARKit ingestion boundary.
  Canonical consumers receive only a validity state, point, timing, sequence,
  source identity, coordinate space, and optional blink confidence.
- Release builds do not accept unauthenticated gaze packets. A debug-only
  compatibility path, if retained during migration, must be explicit.
- The iPhone camera is foreground-only. Backgrounding invalidates stream
  freshness; foregrounding creates a new authenticated stream session.
- VoiceOS receives coarse connection, source, and calibration state. A bounded,
  explicitly approved `capture_gaze` call may additionally return one annotated
  image, coordinates relative to that returned image, uncertainty/fixation
  aggregates, semantic-region selection metadata, and optional untrusted
  provider enrichment. It never receives individual raw samples, global or
  continuous gaze coordinates, display identity, or ARKit transforms.

## Module boundaries

### `Packages/GazeCore`

Pure Swift domain and algorithms shared by iOS and macOS:

- source identity, capabilities, coordinate spaces, and canonical gaze frames;
- ARKit wire models and an ARKit-to-canonical feature extractor;
- calibration plans, profiles, quality, affine fitting, and fine adjustments;
- smoothing, rolling attention, freshness, ordering, and replay gates;
- versioned pairing offers and records;
- CryptoKit key derivation and authenticated gaze envelopes;
- deterministic codecs with unit and tamper tests.

`GazeCore` does not import SwiftUI, AppKit, UIKit, ARKit, Network, Security, a
vendor SDK, or persistence APIs.

### `Phone`

- **Application:** scene lifecycle and dependency composition.
- **Tracking:** `ARKitFaceTracker` owns `ARSession` and emits ARKit captures.
- **Pairing:** nearby-Mac discovery, numeric confirmation, pairing state, and paired-Mac selection.
- **Persistence:** Keychain-backed paired-device records.
- **Transport:** Bonjour discovery, authenticated session establishment, and
  encrypted latest-only gaze delivery.
- **Presentation:** status, saved-Mac picker, nearby-Mac pairing, and numeric confirmation.

The phone stops camera and network streaming only on `.background`; transient
`.inactive` state is handled by ARKit interruption callbacks.

### `Mac`

- **Application:** dependency composition only.
- **Sources:** `GazeSource` adapters and a `GazeSourceManager` that owns the one
  active source rule.
- **ARKit network source:** pairing-aware Bonjour listener, secure datagram
  decoding, freshness, and ARKit feature extraction.
- **Vendor sources:** future adapters such as Tobii implement the same source
  contract and translate vendor coordinates/capabilities at the edge.
- **Pairing:** expiring nearby offer, explicit approval, paired-device inventory,
  revocation, and Keychain persistence.
- **Calibration:** a UI-independent coordinator around the shared calibration
  engine and profile store.
- **Presentation:** main window and overlay render published state; they do not
  fit transforms, decode packets, or choose sources.
- **VoiceOS bridge:** observes coarse application state, requests bounded
  commands through application services, and owns the Mac-side capture/preview
  authorization boundary. It exports no screenshot until the user approves the
  exact frozen and annotated image.

### `VoiceOS` adapter

The TypeScript adapter exposes four MCP tools:

- `get_gaze_status` for coarse readiness and session state;
- `recalibrate_eagleeye` for starting a new calibration, replacing separately
  advertised start/reset tools;
- `start_gaze_evaluation`, always registered so clients see a stable surface;
  the adapter returns `feature_disabled` unless
  `EAGLEGAZE_ENABLE_EVALUATION=1`; and
- `capture_gaze` for one approved annotated screen-context image plus its image
  identity, explicit coordinate system, image-relative gaze and uncertainty,
  bounded fixation evidence, region-selection metadata, and optional untrusted
  enrichment.

If a loopback connection is refused, the adapter may ask a host-provided,
bundle-identifier-scoped capability to open EagleGazeMac, wait for readiness,
and retry the original request once. Arbitrary shell commands, executable paths,
URLs, and process arguments are not part of this API. If no bounded host action
exists, the adapter returns the existing install-or-open guidance.

The Mac bridge remains at `127.0.0.1:47474`. Existing v1 newline-delimited JSON
commands may remain for compatibility. Version 2 carries tool-shaped requests;
successful image responses consist of a newline-terminated JSON header and
exactly the declared number of raw image bytes. The header binds the response
to its request and declares media type, dimensions, and SHA-256. Errors have no
binary body. Size, timeout, integrity, and single-pending-capture limits are
enforced on both sides.

`capture_gaze` coordinates use the returned image's top-left as `(0, 0)`, with
X increasing right and Y increasing down. Pixel and normalized image values may
be returned. Global display coordinates, display identifiers, raw samples,
calibration transforms, window titles, application names, and local paths must
not cross this boundary.

## Canonical source contract

A source descriptor contains a stable source ID, kind, display name, and
capabilities. A canonical gaze frame contains:

- source ID and source session ID;
- monotonically increasing sequence and capture uptime;
- validity/confidence;
- a 2D point;
- coordinate space (`source` or `displayNormalized`);
- optional blink state.

ARKit produces `source` coordinates that require calibration. A Tobii adapter
may produce `displayNormalized` coordinates, but it may still use a per-source
fine-adjustment profile. Source adapters must never claim display-normalized
coordinates unless the vendor SDK defines the display mapping.

## Calibration contract

A profile key is `(sourceID, displayID, setupID)`. `setupID` distinguishes a
physical mount or vendor configuration; moving a phone requires a new or
revalidated setup.

A profile contains a versioned base mapping, fine adjustment, creation/update
times, source coordinate space, and quality summary. Fine adjustment is applied
after the base mapping around display center:

1. base affine mapping or identity;
2. center-relative X/Y scale;
3. X/Y offset;
4. smoothing;
5. output clamp for presentation only.

Calibration collection and evaluation use injected monotonic time so the state
machine is deterministic in tests. UI supplies targets and renders progress;
it does not own calibration math.

## Pairing and transport contract

- The Mac continuously advertises `_eagle-gaze-pair._tcp` on the local network.
  After the user selects that Bonjour result, the phone requests an expiring
  offer on the selected connection. The offer contains a version, offer ID,
  receiver fingerprint, ephemeral public key, one-time secret, service identity,
  and expiry—not an IP address or durable stream key.
- Pairing uses CryptoKit P-256 key agreement plus HKDF transcript binding. Both
  sides prove key possession, show the same short verification code, and the Mac
  requires explicit approval before storing the record.
- Durable records are stored with device-only Keychain accessibility.
- Each reconnect exchanges fresh nonces and derives a new stream key.
- A successful pairing is the runtime authorization boundary; there is no
  separate per-launch consent gate. Removing the saved peer revokes access.
- Gaze UDP envelopes use ChaCha20-Poly1305. Version, pair ID, session ID, and
  sequence are authenticated associated data. Session nonce prefix plus sequence
  forms a unique nonce. Unknown pairs, invalid tags, replay, and out-of-order
  packets are rejected before decoding gaze data.
- The Mac gaze listener uses the fixed application port `47475`. Bonjour still
  discovers the host and verifies its receiver fingerprint, while a stable port
  prevents an otherwise-valid cached service from targeting a dead prior process.

## Multi-device behavior

- Both apps may remember multiple peers.
- The phone automatically reconnects only when its intended receiver is
  unambiguous; otherwise it presents a paired-Mac picker.
- The Mac never replaces an active source silently. A second paired source is
  shown as available and requires a switch action.
- Revoking a device deletes its durable pairing material and invalidates active
  sessions. Calibration records may be deleted separately or retained as
  inactive history according to an explicit user choice.

## Validation gates

- `swift test` covers domain invariants, calibration state and adjustments,
  pairing expiry/transcripts, authenticated round trips, wrong-key/tamper/replay
  rejection, and source switching.
- Phone and Mac schemes compile under Swift 6 strict concurrency.
- Lifecycle tests cover inactive, background, foreground, stale stream, and
  source replacement behavior.
- Integration tests cover pairing, reconnect, revocation, and encrypted
  latest-only delivery with deterministic local transports.
- VoiceOS verification remains green; the evaluation tool stays advertised but
  returns `feature_disabled` while its feature flag is off; legacy tools are not
  advertised; and no continuous or global gaze data is exposed. The direct
  Swift TCP evaluation operation remains available regardless of that adapter
  feature flag.
- Capture tests prove that no image bytes leave before app-owned approval, that
  cancel/timeout/disconnect discard the pending image, that coordinates match
  the returned image and marker, and that v2 rejects malformed, truncated,
  oversized, trailing, or digest-mismatched bodies.
- Release documentation and privacy disclosures match the implemented data
  flow and permissions.
