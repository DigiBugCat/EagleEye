# Security policy

## Supported versions

EagleGaze is currently an experimental MVP. Only the latest revision on the
default branch receives security and privacy fixes.

## Saved-pair authorization boundary

The explicit pairing ceremony is the phone's authorization to stream to one
Mac. The user chooses a nearby Mac, verifies the six-digit transcript code, and
approves the request on the Mac. Both apps then save the peer identity and
long-lived pairing secret in device-only Keychain storage. Removing the saved
Mac revokes that authorization.

Every foreground launch and reconnect performs a fresh challenge-response
against the saved identity and derives a new short-lived gaze-session key. Gaze
packets are encrypted and authenticated. A discovered endpoint is never trusted
by its name, IP address, or Bonjour order; if the cryptographic Mac identity no
longer matches, streaming fails closed and the user must explicitly repair the
pairing. Camera frames, face meshes, raw eye transforms, and gaze samples are
not persisted in the pairing record.

## VoiceOS screen-capture authorization boundary

The VoiceOS-facing API consists of `get_gaze_status`,
`recalibrate_eagleeye`, feature-flagged `start_gaze_evaluation`, and
`capture_gaze`. Opening EagleGazeMac, when supported by the host, is bounded
adapter behavior tied to the fixed application bundle identifier; it is not a
general process-launch tool.

`capture_gaze` changes the risk of the loopback bridge. Loopback restricts the
network path, but it does not authenticate the TypeScript adapter against other
processes running as the signed-in macOS user. Manifest confirmation is useful
for expressing intent but must not authorize pixel release by itself. Every
capture requires an EagleGazeMac-owned preview and explicit approval. The app
freezes and annotates the image before showing the preview, releases only that
approved image, permits only one pending capture, and discards it on rejection,
timeout, requester disconnect, or failure.

The TCP v2 image response uses a newline-terminated JSON header followed by an
exact, length-bounded binary body. The adapter must verify the request ID,
declared media type, dimensions, byte length, SHA-256 digest, maximum size, and
connection close. It must reject truncation, extra bytes, unsupported encodings,
and mismatched metadata before constructing MCP image content. Neither side may
log image bytes or their Base64 representation, accept caller-supplied approval,
or write captures to a temporary file.

Only coordinates relative to the approved returned image may accompany it.
Bounded aggregate fixation evidence—confidence, sample count, coverage
duration, newest-sample age, and image-relative uncertainty—may describe that
one capture. Global desktop/display coordinates, individual gaze samples,
display identifiers, window titles, application names, calibration transforms,
and source/session identifiers remain outside the bridge contract. The pixels themselves can
contain secrets or personal information, so callers and reviewers must treat an
approved response as sensitive even when metadata is minimal.

Smart crop may use macOS Accessibility permission for a bounded, geometry-only
hit test. It reads broad element roles and rectangles needed to select a useful
region, but not values, text, URLs, paths, application names, window titles,
identifiers, actions, or the full Accessibility tree. Failure or denial falls
back to a fixed local crop and does not weaken the capture approval requirement.

Optional Cerebras enrichment is controlled only from EagleGazeMac, is off by
default, and uses a device-only Keychain credential that never crosses the TCP
or MCP boundary. After app-owned approval, the exact previewed context and
optional enlarged-focus images may be sent over HTTPS to Cerebras. Returned
summary, focused-text, label, confidence, and warning fields are external,
untrusted advisory data: neither screen text nor provider output may authorize
an action. Swift bounds these fields before the bridge, and the TypeScript
adapter validates the same limits before constructing MCP content.

## Reporting an issue

Do not open a public issue for a vulnerability or a disclosure involving face-
derived data. Use GitHub's private vulnerability reporting feature for this
repository. Include:

- the affected commit and platform versions;
- reproduction steps and observed impact;
- whether gaze or face-derived data can leave the intended local connection;
- any suggested mitigation.

Please avoid collecting or attaching another person's face-derived data while
investigating.
