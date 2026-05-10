#!/bin/bash
# Patch chrome-devtools-mcp plugin.json with custom MCP args.
# Idempotent: only writes if current args differ from desired.
# Runs at SessionStart to survive `claude plugin update`.

set -euo pipefail

PLUGIN_JSON="$HOME/.claude/plugins/cache/claude-plugins-official/chrome-devtools-mcp/latest/.claude-plugin/plugin.json"

[ -f "$PLUGIN_JSON" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

DESIRED_ARGS='["-y","chrome-devtools-mcp@latest","--no-usage-statistics","--isolated","--viewport","1280x720"]'
CURRENT_ARGS=$(jq -c '.mcpServers."chrome-devtools".args // []' "$PLUGIN_JSON")

[ "$CURRENT_ARGS" = "$DESIRED_ARGS" ] && exit 0

TMP=$(mktemp)
jq --argjson args "$DESIRED_ARGS" \
   '.mcpServers."chrome-devtools".args = $args' \
   "$PLUGIN_JSON" > "$TMP" && mv "$TMP" "$PLUGIN_JSON"
