#!/usr/bin/env bash
# [T0-3] guard 薄 wrapper —— 判定邏輯在 ~/.agents/hooks/guard-git-push.sh
exec bash "$HOME/.agents/hooks/guard-git-push.sh" --format=claude
