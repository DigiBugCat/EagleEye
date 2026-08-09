#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/opt/homebrew/opt/node@22/bin:/usr/local/bin:$PATH"

BUN=""
for candidate in "$HOME/.bun/bin/bun" /opt/homebrew/bin/bun "$(command -v bun 2>/dev/null || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    BUN="$candidate"
    break
  fi
done

if [[ ! -f "$SCRIPT_DIR/node_modules/@modelcontextprotocol/sdk/package.json" || ! -f "$SCRIPT_DIR/node_modules/zod/package.json" ]]; then
  print -u2 "EagleGaze VoiceOS dependencies are not installed. Run 'bun install --frozen-lockfile' in $SCRIPT_DIR before launching the integration."
  exit 78
fi

if [[ -n "$BUN" ]]; then
  exec "$BUN" "$SCRIPT_DIR/server.ts" "$@"
fi

if [[ -x "$SCRIPT_DIR/node_modules/.bin/tsx" ]]; then
  exec "$SCRIPT_DIR/node_modules/.bin/tsx" "$SCRIPT_DIR/server.ts" "$@"
fi
print -u2 "EagleGaze VoiceOS requires Bun or the bundled node_modules/.bin/tsx runtime."
exit 78
