#!/bin/sh
# Removes the Claude Pill hooks from ~/.claude/settings.json, the app, and its data.
set -e
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  /usr/bin/jq '
    def ours: (.command // "") | contains("pill-hook.sh");
    if .hooks then
      .hooks |= (with_entries(.value |= (map(.hooks |= map(select(ours | not))) | map(select(.hooks | length > 0))))
                 | with_entries(select(.value | length > 0)))
      | if .hooks == {} then del(.hooks) else . end
    else . end
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi
CODEX_HOOKS="$HOME/.codex/hooks.json"
if [ -f "$CODEX_HOOKS" ]; then
  /usr/bin/jq '
    def ours: (.command // "") | contains("pill-hook.sh");
    if .hooks then
      .hooks |= (with_entries(.value |= (map(.hooks |= map(select(ours | not))) | map(select(.hooks | length > 0))))
                 | with_entries(select(.value | length > 0)))
      | if .hooks == {} then del(.hooks) else . end
    else . end
  ' "$CODEX_HOOKS" > "$CODEX_HOOKS.tmp" && mv "$CODEX_HOOKS.tmp" "$CODEX_HOOKS"
fi
pkill -x ClaudePill 2>/dev/null || true
rm -rf "/Applications/Claude Pill.app" "$HOME/.claude/pill"
echo "Claude Pill removed."
