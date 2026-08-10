# VoiceOS integration boundaries

This document defines the v0.2 trust and data boundaries. Expanding any row is
a design change, not a small implementation detail.

| Boundary | Transport | Data allowed in v0.2 | Explicitly excluded |
| --- | --- | --- | --- |
| iPhone → EagleGazeMac | Bonjour-discovered UDP on the local link, authenticated with a per-reconnect session key and replay-checked sequence | Ephemeral canonical gaze point, validity/confidence, blink state, source/session identity, sequence, and capture uptime | Raw face/eye matrices, cloud relay, gaze persistence, background capture, unauthenticated release packets |
| EagleGazeMac → TypeScript bridge | Versioned RPC over `127.0.0.1:47474`; v1 newline-delimited JSON remains compatible and v2 uses a JSON header followed by a length-bounded binary body | Coarse state; bounded calibration/evaluation commands; for an approved `capture_gaze` call, one annotated image plus image-relative coordinates, bounded region metadata, and optional untrusted provider summary, focused subject/text, labels, confidence, and warnings | Source IDs or user names, ARKit matrices, blink values, gaze rays, global desktop coordinates, continuous gaze, cursor events, unapproved or unannotated screen captures |
| TypeScript MCP → VoiceOS agent | MCP over stdio | `get_gaze_status`, `recalibrate_eagleeye`, feature-flagged `start_gaze_evaluation`, and `capture_gaze`; status/glance blocks; an approved annotated image with image-relative gaze coordinates | Raw samples, face-derived values, global screen coordinates, continuous streams, cursor control |
| VoiceOS confirmation → acting tool | Manifest-declared confirmation card | User intent for recalibration/evaluation and an initial warning for screen capture | Programmatic approval from a widget or the model; VoiceOS confirmation alone is not sufficient to release screenshot pixels |
| EagleGazeMac capture preview → `capture_gaze` response | App-owned, per-capture approval | Release of the frozen, annotated in-memory capture to the requesting loopback connection | Caller-supplied approval, blanket approval, releasing bytes before approval, silent capture export |
| EagleGazeMac capture preview → Cerebras | User-enabled HTTPS request after the same per-capture approval | Only the exact previewed context and focus images; image-relative gaze hint; broad local region role | Raw/global/continuous gaze, Accessibility text or values, application names, window titles, display IDs, silent or pre-approval uploads |
| VoiceOS widget | Sandboxed iframe/postMessage | Presentation, resize, HTTPS link opening, staged confirmation inputs | Network access, host DOM/API access, arbitrary filesystem access, approval messages, full-screen calibration |
| First-use setup card → GitHub | User-selected `voiceos:openUrl` HTTPS link | Opens the EagleGaze releases page so the user can inspect and choose a signed Mac download | Silent downloads, automatic installation, shell execution, bypassing macOS trust prompts |

## Trust decisions

- `local-mcp` is executable code launched as the signed-in user. Review the
  integration folder as trusted code even though its manifest declares only a
  loopback network destination.
- The coarse v1 commands have no setup token. Screenshot export is not treated
  as safe merely because the listener is loopback: another process running as
  the signed-in user can connect to it. `capture_gaze` therefore requires an
  EagleGazeMac-owned preview and explicit approval for every image before any
  image bytes cross the bridge.
- EagleGazeMac remains the only calibration authority. TypeScript sends commands
  and reports snapshots; it does not fit or persist calibration transforms.
- The public recalibration operation is `recalibrate_eagleeye`. It starts a new
  calibration and supersedes the separately advertised start/reset operations;
  legacy v1 commands may remain available only for compatibility.
- `start_gaze_evaluation` is always registered and advertised so the MCP surface
  is stable. The TypeScript adapter returns `feature_disabled` unless
  `EAGLEGAZE_ENABLE_EVALUATION=1`; the direct Swift TCP evaluation operation
  exists regardless of that adapter feature flag.
- A failed loopback connection means the companion is unavailable, not
  necessarily absent. Before returning an unavailable result, the adapter may
  use a host-approved, bundle-identifier-scoped action to open EagleGazeMac and
  retry once. It must not expose arbitrary process, path, URL, or shell launch.
  If the bounded open action is unavailable, the first-use card says “install or
  open” and never claims that VoiceOS inspected the user's Applications folder.
- “Phone connected” means a valid gaze packet arrived recently. v0.2 does not
  send the user-assigned iPhone name into VoiceOS.

## `capture_gaze` data contract

- The Mac freezes a fresh stabilized gaze point, captures the relevant screen
  context, annotates it, and presents that exact frozen result for approval.
  Looking at the approval UI must not move the marker in the pending capture.
- The result contains the annotated image and a structured gaze point in the
  returned image's coordinate space: top-left origin, X increasing right, and Y
  increasing down. Pixel coordinates, normalized image coordinates, and an
  image-relative uncertainty radius are allowed.
- The result also carries the returned image's media type, dimensions, digest,
  target and scope; an explicit coordinate-system descriptor; horizontal and
  vertical uncertainty radii plus clipped image-relative bounds; and bounded
  fixation evidence consisting of estimator kind, confidence, sample count,
  coverage duration, and newest-sample age. Region metadata may include role,
  resolver, confidence, fallback/user-adjustment state, topmost-at-gaze state,
  clipping, padding, and included geometric relationships.
- Absolute AppKit, Core Graphics, display, Retina backing, or global desktop
  coordinates do not cross the bridge. Display IDs, window titles, application
  names, filesystem paths, and raw gaze samples are also excluded.
- Region selection first uses a bounded, geometry-only Accessibility hit test
  and ancestor walk. It reads roles and rectangles, not textual content or the
  entire tree. A fixed local crop is used when permission or suitable geometry
  is unavailable.
- Provider enrichment is optional, externally generated, and untrusted advisory
  data. Screen-derived or provider-generated text must never authorize an
  action. If both `enrichment` and `enrichmentWarning` are absent, enrichment
  was disabled; `enrichment` means it succeeded; `enrichmentWarning` without
  `enrichment` means the approved local capture succeeded but enrichment did
  not.
- The Mac keeps the capture in memory only until approve, reject, timeout, or
  disconnect and does not write it to disk or log its body. Once approved and
  returned through MCP, the image and coordinates can be retained by VoiceOS,
  its conversation history, or downstream services under their own policies;
  EagleGaze cannot enforce deletion beyond its process boundary.

## TCP v2 response framing

Version 2 requests use a strict `tools/call` JSON envelope. A successful image
response is one UTF-8 JSON header terminated by `\n`, immediately followed by
exactly `bodyLength` binary bytes, then connection close. The header declares
the request ID, media type, dimensions, and SHA-256 digest. Errors have
`bodyLength: 0` and no binary body. Both peers enforce request, header, image,
and timeout limits; reject mismatched request IDs, hashes, lengths, trailing
bytes, and unsupported media; and never log the image or its MCP Base64 form.

## Discovery model

EagleGaze uses discovery only where addresses vary: the iPhone browses for the
Mac's `_eagle-gaze._udp` Bonjour service. VoiceOS and EagleGazeMac are on the
same machine, so their bridge uses loopback directly and is never advertised to
the LAN. Normal setup therefore requires no IP address or hostname.

## Requires a separate review

- Exposing raw, global, or continuous gaze to VoiceOS, a widget, another app, or
  a remote MCP. The only approved mapped point is relative to the single image
  returned by an approved `capture_gaze` call.
- Continuous subscriptions or event streams instead of bounded request/response.
- Cursor control, clicking, accessibility actions, or input injection.
- Remembering calibration across launches or associating it with a person.
- Identifying, selecting, or supporting multiple simultaneous iPhones.
- Listening beyond loopback, adding high-impact commands without authentication,
  or adding telemetry.
