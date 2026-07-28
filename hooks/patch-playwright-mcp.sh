#!/bin/bash
# Patch playwright plugin .mcp.json to load custom config (headed mode + viewport).
# Idempotent: appends --config only if absent; keeps the plugin's own package spec.
# Loops every cached version dir (git-hash-named) so it survives `claude plugin update`.

set -euo pipefail

CACHE_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/playwright"
CONFIG_PATH="$HOME/.claude/playwright-mcp-config.json"

[ -d "$CACHE_DIR" ] || exit 0
[ -f "$CONFIG_PATH" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

for dir in "$CACHE_DIR"/*/; do
  MCP_JSON="${dir}.mcp.json"
  [ -f "$MCP_JSON" ] || continue

  # 已含 --config 視為已 patch 過，跳過
  jq -e '(.playwright.args // []) | index("--config")' \
    "$MCP_JSON" >/dev/null 2>&1 && continue

  TMP="${MCP_JSON}.tmp.$$"
  jq --arg cfg "$CONFIG_PATH" \
     '.playwright.args = ((.playwright.args // []) + ["--config", $cfg])' \
     "$MCP_JSON" > "$TMP" && mv "$TMP" "$MCP_JSON"
done
