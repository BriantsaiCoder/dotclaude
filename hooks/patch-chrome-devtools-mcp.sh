#!/bin/bash
# Patch chrome-devtools-mcp plugin.json with custom MCP args.
# Idempotent: appends missing flags only; keeps the plugin's own package pin.
# Loops every cached version dir (semver-named) so it survives `claude plugin update`.

set -euo pipefail

CACHE_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/chrome-devtools-mcp"

[ -d "$CACHE_DIR" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

EXTRA_FLAGS='["--no-usage-statistics","--isolated","--viewport","1280x720"]'

for dir in "$CACHE_DIR"/*/; do
  PLUGIN_JSON="${dir}.claude-plugin/plugin.json"
  [ -f "$PLUGIN_JSON" ] || continue

  # 已含 --isolated 視為已 patch 過，跳過
  jq -e '(.mcpServers."chrome-devtools".args // []) | index("--isolated")' \
    "$PLUGIN_JSON" >/dev/null 2>&1 && continue

  TMP="${PLUGIN_JSON}.tmp.$$"
  jq --argjson flags "$EXTRA_FLAGS" \
     '.mcpServers."chrome-devtools".args = ((.mcpServers."chrome-devtools".args // []) + $flags)' \
     "$PLUGIN_JSON" > "$TMP" && mv "$TMP" "$PLUGIN_JSON"
done
