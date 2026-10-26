#!/bin/sh
# Installs Claude Pill:
#   1. copies the app to /Applications
#   2. copies the hook to ~/.claude/pill/pill-hook.sh
#   3. adds the hook to ~/.claude/settings.json (a backup is saved next to it first)
# Safe to run again; it replaces its own entries instead of duplicating them.
set -e
cd "$(dirname "$0")/.."

[ -d "build/Claude Pill.app" ] || ./scripts/build.sh

pkill -x ClaudePill 2>/dev/null || true
rm -rf "/Applications/Claude Pill.app"
# Screenshots and recordings used to be a separate app, Snappabl. Running both would fight over
# the same shortcuts, so the old one goes; its settings are carried over on first launch.
if [ -d "/Applications/Snappabl.app" ]; then
  pkill -x Snappabl 2>/dev/null || true
  rm -rf "/Applications/Snappabl.app"
  echo "Removed Snappabl.app: capture is part of Claude Pill now."
fi
cp -R "build/Claude Pill.app" /Applications/

mkdir -p "$HOME/.claude/pill/sessions"
cp hooks/pill-hook.sh "$HOME/.claude/pill/pill-hook.sh"
chmod +x "$HOME/.claude/pill/pill-hook.sh"

SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
[ -f "$SETTINGS.before-claudepill" ] || cp "$SETTINGS" "$SETTINGS.before-claudepill"

CMD="sh \"$HOME/.claude/pill/pill-hook.sh\""
/usr/bin/jq --arg cmd "$CMD" '
  def ours: (.command // "") | contains("pill-hook.sh");
  def strip: map(.hooks |= map(select(ours | not))) | map(select(.hooks | length > 0));
  def entry($e): {hooks: [{type: "command", command: $cmd, timeout: 5}]}
                 + (if ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied"] | index($e)
                    then {matcher: "*"} else {} end);
  .hooks = (.hooks // {})
  | reduce ("UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
            "PermissionDenied", "Notification", "Elicitation", "PreCompact", "PostCompact",
            "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd") as $e
      (.; .hooks[$e] = (((.hooks[$e] // []) | strip) + [entry($e)]))
' "$SETTINGS" > "$SETTINGS.tmp"
mv "$SETTINGS.tmp" "$SETTINGS"

# Codex reads the same kind of hooks from ~/.codex/hooks.json. Only touch it when Codex is set up.
if [ -d "$HOME/.codex" ]; then
  CODEX_HOOKS="$HOME/.codex/hooks.json"
  [ -f "$CODEX_HOOKS" ] || echo '{}' > "$CODEX_HOOKS"
  [ -f "$CODEX_HOOKS.before-claudepill" ] || cp "$CODEX_HOOKS" "$CODEX_HOOKS.before-claudepill"
  CODEX_CMD="sh \"$HOME/.claude/pill/pill-hook.sh\" codex"
  /usr/bin/jq --arg cmd "$CODEX_CMD" '
    def ours: (.command // "") | contains("pill-hook.sh");
    def strip: map(.hooks |= map(select(ours | not))) | map(select(.hooks | length > 0));
    .hooks = (.hooks // {})
    | reduce ("UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "PreCompact",
              "PostCompact", "SubagentStart", "SubagentStop", "Stop", "Interrupt", "SessionEnd") as $e
        (.; .hooks[$e] = (((.hooks[$e] // []) | strip) + [{hooks: [{type: "command", command: $cmd, timeout: 3}]}]))
  ' "$CODEX_HOOKS" > "$CODEX_HOOKS.tmp" && mv "$CODEX_HOOKS.tmp" "$CODEX_HOOKS"
fi

open "/Applications/Claude Pill.app"
echo "Installed. New Claude Code sessions will show up in the pill."
