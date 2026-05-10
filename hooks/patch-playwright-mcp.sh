#!/bin/bash
# Patch playwright plugin .mcp.json to load custom config (headed mode + viewport).
# Idempotent: only writes if current args differ from desired.
# Runs at SessionStart to survive `claude plugin update`.

set -euo pipefail

MCP_JSON="$HOME/.claude/plugins/cache/claude-plugins-official/playwright/unknown/.mcp.json"
CONFIG_PATH="$HOME/.claude/playwright-mcp-config.json"

[ -f "$MCP_JSON" ] || exit 0
[ -f "$CONFIG_PATH" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

DESIRED_ARGS=$(jq -nc --arg cfg "$CONFIG_PATH" '["@playwright/mcp@latest","--config",$cfg]')
CURRENT_ARGS=$(jq -c '.playwright.args // []' "$MCP_JSON")

[ "$CURRENT_ARGS" = "$DESIRED_ARGS" ] && exit 0

TMP="${MCP_JSON}.tmp.$$"
jq --argjson args "$DESIRED_ARGS" \
   '.playwright.args = $args' \
   "$MCP_JSON" > "$TMP" && mv "$TMP" "$MCP_JSON"
