# Contributing to EagleEye

EagleEye is an experimental gaze-tracking project. Contributions are welcome,
especially when they improve measurement quality, calibration robustness,
accessibility, local-network security, or privacy boundaries.

## License for contributions

The project is licensed under the Mozilla Public License 2.0. By submitting a
contribution, you agree that your contribution is licensed under MPL-2.0 and
that you have the right to provide it under those terms. No copyright assignment
or contributor license agreement is required.

Do not submit third-party code, assets, research datasets, or generated material
unless its license permits inclusion under this repository's terms. Preserve
existing copyright and attribution notices.

## Security and sensitive data

Never commit API keys, signing certificates, provisioning profiles, pairing
secrets, device captures, face-derived data, or real gaze-session payloads.
Provider credentials belong in the operating-system Keychain. Use synthetic
fixtures in tests.

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
Do not open a public issue containing a credential or another person's
face-derived data.

## Development workflow

Keep changes focused and explain any user-visible tradeoff. Calibration changes
should include independent validation rather than only training-set accuracy.
Security or wire-format changes should include negative tests for malformed,
replayed, stale, or unauthenticated input.

Before opening a pull request, run:

```sh
cd Packages/GazeCore
swift test

cd ../..
xcodebuild -project EagleGaze.xcodeproj -scheme EagleGazeMacTests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test

xcodebuild -project EagleGaze.xcodeproj -scheme EagleGazePhoneTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_ALLOWED=NO test

cd VoiceOS
bun run verify
```

Physical-device validation remains necessary for ARKit behavior because face
tracking is unavailable in Simulator. State clearly which platforms and devices
you actually tested.
