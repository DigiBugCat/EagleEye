# VoiceOS integration contract

Read `README.md` and `voiceos.integration.json` before editing.

- Keep manifest tool names and `server.ts` registrations exactly synchronized.
- This is a `schemaVersion: 1`, `local-mcp` integration using standard MCP over
  stdio.
- Keep the generated-style `/bin/zsh run.sh` runtime; it makes Bun discovery
  reliable when VoiceOS launches from a GUI environment.
- Keep network permission restricted to `127.0.0.1`.
- Treat `local-mcp` as trusted local executable code. Do not add filesystem
  reads, child processes, shell execution, telemetry, or external fetches.
- Read-only tools have no confirmation. Any tool that changes EagleGaze state
  must declare a confirmation card in the manifest.
- Never return raw ARKit data, gaze coordinates, face transforms, blink values,
  or UI-only facts to VoiceOS.
- Keep v0.1 free of setup fields. If a future feature is high-impact enough to
  require authentication, stop and design that boundary explicitly.
- The Swift app remains the calibration source of truth. TypeScript is a narrow
  control/status adapter, not a second calibration implementation.
- Run `bun run verify` after every change.
