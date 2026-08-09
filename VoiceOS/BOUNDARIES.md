# VoiceOS integration boundaries

This document defines the v0.1 trust and data boundaries. Expanding any row is
a design change, not a small implementation detail.

| Boundary | Transport | Data allowed in v0.1 | Explicitly excluded |
| --- | --- | --- | --- |
| iPhone → EagleGazeMac | Bonjour-discovered, versioned UDP on the local link | Ephemeral ARKit face/eye estimate required by the existing gaze prototype | Cloud relay, persistence, background capture |
| EagleGazeMac → TypeScript bridge | Newline-delimited JSON over `127.0.0.1:47474` | Coarse source kind, connection state, calibration state/progress, evaluation state/counts, overlay state; reversible calibration commands | Source IDs or user names, ARKit matrices, blink values, gaze rays, normalized gaze coordinates, cursor events |
| TypeScript MCP → VoiceOS agent | MCP over stdio | Coarse status plus 1–3 native glance blocks | Raw samples, face-derived values, continuous streams |
| VoiceOS confirmation → acting tool | Manifest-declared confirmation card | User approval for start/reset | Programmatic approval from a widget or the model |
| VoiceOS widget | Sandboxed iframe/postMessage | Presentation, resize, HTTPS link opening, staged confirmation inputs | Network access, host DOM/API access, arbitrary filesystem access, approval messages, full-screen calibration |
| First-use setup card → GitHub | User-selected `voiceos:openUrl` HTTPS link | Opens the EagleGaze releases page so the user can inspect and choose a signed Mac download | Silent downloads, automatic installation, shell execution, bypassing macOS trust prompts |

## Trust decisions

- `local-mcp` is executable code launched as the signed-in user. Review the
  integration folder as trusted code even though its manifest declares only a
  loopback network destination.
- v0.1 deliberately has no setup token. Loopback plus the signed-in macOS user
  is the trust boundary because commands are narrow and reversible. Any future
  pointer control, raw data access, persistence, or remote listener requires a
  real authorization design first.
- EagleGazeMac remains the only calibration authority. TypeScript sends commands
  and reports snapshots; it does not fit or persist calibration transforms.
- A failed loopback connection means the companion is unavailable, not
  necessarily absent. The first-use card therefore says “install or open” and
  never claims that VoiceOS inspected the user's Applications folder.
- “Phone connected” means a valid gaze packet arrived recently. v0.1 does not
  send the user-assigned iPhone name into VoiceOS.

## Discovery model

EagleGaze uses discovery only where addresses vary: the iPhone browses for the
Mac's `_eagle-gaze._udp` Bonjour service. VoiceOS and EagleGazeMac are on the
same machine, so their bridge uses loopback directly and is never advertised to
the LAN. Normal setup therefore requires no IP address or hostname.

## Requires a separate review

- Exposing raw or mapped gaze to VoiceOS, a widget, another app, or a remote MCP.
- Continuous subscriptions or event streams instead of bounded request/response.
- Cursor control, clicking, accessibility actions, or input injection.
- Remembering calibration across launches or associating it with a person.
- Identifying, selecting, or supporting multiple simultaneous iPhones.
- Listening beyond loopback, adding high-impact commands without authentication,
  or adding telemetry.
