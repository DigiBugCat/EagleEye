# EagleGaze for VoiceOS

This folder is a VoiceOS developer-preview integration. VoiceOS launches
`run.sh` as a local MCP server over stdio; the Studio-compatible launcher finds
Bun even when VoiceOS has a restricted GUI-app PATH, with a bundled Node/tsx
fallback. Dependencies are an install-time contract: the launcher never runs
`bun install`, `npm install`, or `npx` and never fetches unpinned code at
runtime. Run `bun install --frozen-lockfile` once when packaging or developing
the integration. TypeScript talks to the running
EagleGaze Mac app through a loopback-only bridge on `127.0.0.1:47474`.

## First-run install

1. Install the EagleGaze integration from its VoiceOS share link, or use
   **Settings → Agent Mode → Integrations → Install from folder** during
   development.
2. Ask “Is EagleGaze ready?”
3. If the Mac companion is not reachable, VoiceOS shows a one-time setup card.
   Select **Get EagleGaze for Mac**, install the signed release, and open it.
4. Ask VoiceOS to check again, then start calibration.

The integration does not silently download or execute software. The setup card
opens `https://github.com/DigiBugCat/EagleGaze/releases/latest` only after the
user selects the link. Because the repository is currently private, the user
must be an invited collaborator and signed into GitHub until a public download
channel exists.

For local development, run `bun install --frozen-lockfile` and `bun run verify`
in this folder before installing or reloading it in VoiceOS.

There are no setup fields, secrets, hostnames, or ports to enter.

After editing, use **Reload** on the integration detail page.

## Publishing

VoiceOS's share publisher packages only `voiceos.integration.json`,
`server.ts`, `package.json`, an optional `widgetKit.ts`, and the manifest icon.
Consequently, the production server intentionally contains its loopback bridge
client in `server.ts`; `bridge.ts` remains a development and unit-test module.
`bun run verify` rejects a future change that makes the published server import
that omitted file.

## Automatic discovery

There are two local hops, and neither requires entering an IP address:

1. EagleGazePhone browses for `_eagle-gaze._udp` with Bonjour and automatically
   connects to EagleGazeMac on the same local network.
2. The VoiceOS TypeScript integration runs on that Mac and connects through
   fixed loopback (`127.0.0.1`), which is not advertised to the LAN.

The status tool reports whether a Bonjour-discovered iPhone has sent a recent
gaze packet. It intentionally does not expose the phone's user-assigned name.

## Boundary

- Swift owns the calibration model and full-display overlay.
- TypeScript can read coarse state and request start/reset actions.
- The Swift composition root injects `GazeApplicationService` into
  `VoiceOSBridge`. Its `GazeApplicationSnapshot` contains only source kind,
  connection, calibration, evaluation, sample/trial counts, and overlay
  visibility. It deliberately has no source IDs, names, coordinates, rays,
  matrices, or blink values. The deprecated untyped initializer fails closed
  and exists only while older app composition code migrates.
- Acting tools have VoiceOS confirmation cards before their handlers run.
- The bridge accepts only loopback TCP. Any process already running as this Mac
  user can request these narrow, reversible commands; VoiceOS still confirms
  acting tools before it calls them.
- The manifest declares only `127.0.0.1`, but a `local-mcp` server is still
  executable code running as the signed-in user. Treat the folder as trusted
  code; the manifest permission is not a substitute for OS process sandboxing.
- MCP results exclude raw ARKit transforms, blink values, gaze rays, and mapped
  gaze coordinates. VoiceOS receives connection and calibration state only.
- When the Mac companion cannot be reached, the adapter returns an install/open
  card with a user-selected HTTPS link. It performs no download, installation,
  shell command, or application launch itself.
- Calibration cannot live inside a custom notch widget: VoiceOS widgets are
  sandboxed, limited to 60–420 px, have no network access, and have no
  programmatic approval message.

Do not add pointer control, raw gaze export, cloud transport, persistence,
high-impact commands, or a broader listener address without a separate privacy
and threat-model review. High-impact capabilities would require authentication.
See [`BOUNDARIES.md`](BOUNDARIES.md) for the complete data-flow matrix.
