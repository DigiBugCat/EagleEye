# Privacy

EagleGaze uses ARKit face tracking on the iPhone to estimate gaze direction.
That output is face-derived data and should be treated as sensitive even though
the app does not transmit a camera image or face mesh.

## Current MVP data flow

- The iPhone camera is processed on-device by ARKit.
- After the user explicitly pairs a Mac, the phone sends gaze direction, eye-blink
  estimates, tracking state, sequence numbers, timestamps, and transforms
  needed by the prototype directly to a Mac discovered on the local network.
- The Mac uses those samples for calibration, visualization, and an accuracy
  exercise.
- Neither app stores gaze samples. On an explicitly approved `capture_gaze`
  request, however, the Mac may return one annotated screenshot and
  image-relative gaze coordinates to the local TypeScript MCP adapter, which
  then supplies them to VoiceOS. If the user separately enables Cerebras in the
  Mac UI, the exact previewed context and focus images are sent to Cerebras
  after approval for optional `gemma-4-31b` labeling.
- There are no analytics, advertising SDKs, accounts, or third-party trackers.

The phone app must remain in the foreground while tracking. Stopping the app or
revoking camera or local-network permission stops the data flow.

## Screen-capture disclosure and retention

`capture_gaze` can reveal whatever is visible in the captured screen context,
including messages, documents, credentials, health or financial information,
and the approximate place the user was looking. Before releasing an image,
EagleGazeMac shows an app-owned preview of the exact frozen, annotated capture
and requires approval for that individual request. VoiceOS or model-generated
arguments cannot approve it, and the app does not support blanket approval.
When Cerebras enrichment is enabled, the same approval sheet identifies that
external destination and previews every image that will be uploaded.

Before approval, the image exists in memory only. EagleGazeMac does not save it
to disk, add metadata such as window titles or application names, log its bytes,
or retain it after approve, reject, timeout, disconnect, or failure. The result
may include gaze coordinates only relative to the returned image, with a
top-left origin and optional uncertainty radius. It does not include absolute
screen coordinates, display identifiers, calibration transforms, or raw gaze
samples.

Smart crop selection is local. With Accessibility permission, EagleGaze reads a
bounded chain of roles and rectangles around the gaze point plus a small
allowlist of geometric relationships. It does not read element text or values,
application names, window titles, URLs, paths, identifiers, supported actions,
or the full Accessibility tree. If that geometry is unavailable or unsuitable,
it falls back to a fixed local screenshot region.

Approval permits the image and its image-relative coordinates to leave
EagleGazeMac. After the adapter returns them as MCP content, they may be stored
in VoiceOS conversation history or processed and retained by downstream model
or service providers according to those products' settings and policies. The
Mac app's in-memory-only guarantee does not extend to those downstream copies.
Users should cancel the preview whenever the capture contains information they
do not intend to share.

## Pairing and data control

The phone does not present a second consent gate after pairing. Pairing itself
is the explicit user action that authorizes a specific Mac: the user selects the
Mac, checks a six-digit code, and approves it. The trusted identity is saved in
device-only Keychain storage so later launches can reconnect without repeating
the ceremony. Each reconnect still authenticates that identity and creates a
fresh encrypted session; a name, IP address, or Bonjour result alone is never
enough to receive gaze data.

Users can remove a saved Mac from the phone to revoke it. Streaming also stops
when the phone app backgrounds or camera/local-network permission is removed.
The pairing record contains identity and cryptographic material but no camera
frames, face mesh, raw eye transforms, or gaze history.

## Prototype limitation

EagleGaze remains an experimental prototype. Anyone distributing a derived
build must independently confirm compliance with Apple's current developer
terms and applicable privacy law.

Report a suspected privacy issue using the private process in
[SECURITY.md](SECURITY.md), not a public issue.
