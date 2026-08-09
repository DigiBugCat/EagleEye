# Privacy

EagleGaze uses ARKit face tracking on the iPhone to estimate gaze direction.
That output is face-derived data and should be treated as sensitive even though
the app does not transmit a camera image or face mesh.

## Current MVP data flow

- The iPhone camera is processed on-device by ARKit.
- With an accepted phone consent, the phone sends gaze direction, eye-blink
  estimates, tracking state, sequence numbers, timestamps, and transforms
  needed by the prototype directly to a Mac discovered on the local network.
- The Mac uses those samples for calibration, visualization, and an accuracy
  exercise.
- Neither app stores gaze samples or sends them to a cloud service.
- There are no analytics, advertising SDKs, accounts, or third-party trackers.

The phone app must remain in the foreground while tracking. Stopping the app or
revoking camera or local-network permission stops the data flow.

## Consent foundation (implemented, not yet wired)

`Phone/Privacy/PhonePrivacyConsent.swift` defines version 1 of the explicit
off-device disclosure. It names the destination as an opaque paired-Mac ID and
lists only the face-derived categories that may leave the phone. It contains no
camera image, face mesh, raw gaze sample, eye transform, or network address.
`Phone/Privacy/PhonePrivacyConsentStore.swift` provides a UserDefaults adapter
and an in-memory fake, plus `PhonePrivacyConsentCoordinator`. The coordinator
creates a short-lived `PhoneStreamingAuthorization` only after a consent is
saved, scopes that capability to one destination, and clears it on revoke while
calling the app-supplied stop callback.

`Mac/Privacy/` contains the corresponding coarse, versioned disclosure
acknowledgement for the Mac presentation surface. It stores only the current
disclosure version and acknowledgement time; it never stores gaze data.

The new foundation is deliberately separate from app composition. The current
phone `PhoneAppModel`/`GazeSender` path has not yet been wired to require the
authorization, and no consent screen has been added in this bounded change.
Until that wiring exists, this repository remains a prototype and must not be
distributed as if the consent gate were active.

### Required runtime integration

1. Compose a `PhonePrivacyConsentCoordinator` with a protected production
   store (the included UserDefaults adapter is MVP-only).
2. Present the disclosure before starting ARKit or network streaming. After an
   explicit accept, call `grant` and retain the returned authorization in the
   streaming composition.
3. Before every `GazeSender.start`, require an authorization whose
   `destinationID` matches the selected paired Mac. Do not make authorization
   decisions from a gaze sample or from a network address.
4. Register `setRevocationHandler` to stop ARKit and the sender, clear any
   pending sample, and return the UI to the undisclosed state. Revoke when the
   user withdraws consent, removes the paired Mac, or changes the disclosure
   version.
5. On app launch, use `authorizeStreaming(to:)` only after the user has
   selected the same paired Mac; a missing, corrupt, or unsupported record
   must fail closed and show the disclosure again.
6. Add a Mac disclosure acknowledgement before presenting received gaze and
   keep VoiceOS limited to its existing coarse state contract.

## Prototype limitation

This repository does not yet contain a polished, explicit consent screen or
the runtime wiring described above. Anyone distributing a derived build must
finish that work and independently confirm compliance with Apple's current
developer terms and applicable privacy law. UserDefaults is not a suitable
long-term secret store; migrate the consent record to a device-only protected
store as part of release hardening.

Report a suspected privacy issue using the private process in
[SECURITY.md](SECURITY.md), not a public issue.
