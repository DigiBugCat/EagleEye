# Security policy

## Supported versions

EagleGaze is currently an experimental MVP. Only the latest revision on the
default branch receives security and privacy fixes.

## Privacy authorization boundary

The phone's versioned consent model is in `Phone/Privacy/`. A valid consent is
scoped to one opaque paired-Mac identifier and is required to mint the
short-lived `PhoneStreamingAuthorization` used by the transport composition.
Revocation removes the persisted record, clears the active authorization, and
invokes the app callback so camera and network streaming can stop immediately.
The records contain category names and timestamps only; they do not contain
camera frames, face meshes, raw gaze, eye transforms, network addresses, or
pairing keys.

The included UserDefaults adapter is an MVP/testing adapter, not a security
boundary for release. Production composition must use a device-only protected
store, validate the consent version on every decode, fail closed on corruption
or an unknown version, and require a fresh explicit grant when the destination
or disclosure changes. The foundation is not yet wired into `PhoneAppModel` or
`GazeSender`; that integration is a release blocker.

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
