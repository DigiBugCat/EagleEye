# Privacy

EagleGaze uses ARKit face tracking on the iPhone to estimate gaze direction.
That output is face-derived data and should be treated as sensitive even though
the app does not transmit a camera image or face mesh.

## Current MVP data flow

- The iPhone camera is processed on-device by ARKit.
- The phone sends gaze direction, eye-blink estimates, tracking state, sequence
  numbers, timestamps, and transforms needed by the prototype directly to a Mac
  discovered on the local network.
- The Mac uses those samples for calibration, visualization, and an accuracy
  exercise.
- Neither app stores gaze samples or sends them to a cloud service.
- There are no analytics, advertising SDKs, accounts, or third-party trackers.

The phone app must remain in the foreground while tracking. Stopping the app or
revoking camera or local-network permission stops the data flow.

## Prototype limitation

This repository does not yet contain a polished, explicit consent screen for
sending face-derived data off the iPhone. Anyone distributing a derived build
must add an appropriate disclosure and consent experience and independently
confirm compliance with Apple's current developer terms and applicable privacy
law.

Report a suspected privacy issue using the private process in
[SECURITY.md](SECURITY.md), not a public issue.
