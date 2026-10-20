#!/bin/sh
# Claude Pill hook. Claude Code and Codex pipe each hook event to this script as JSON on stdin;
# Codex calls it with "codex" as the first argument.
# It keeps the latest event per session in ~/.claude/pill/sessions/<session_id>.json,
# which the ClaudePill app watches. It must never fail or slow Claude down, so every
# error is swallowed and it always exits 0.

agent="${1:-claude}"
case "$agent" in claude | codex) ;; *) agent=claude ;; esac

JQ=/usr/bin/jq
[ -x "$JQ" ] || JQ=$(command -v jq 2>/dev/null) || exit 0

dir="$HOME/.claude/pill/sessions"
mkdir -p "$dir" 2>/dev/null || exit 0

input=$(cat)
# Codex can also run hooks meant for Claude Code; its transcripts live under ~/.codex.
case "$(printf '%s' "$input" | "$JQ" -r '.transcript_path // empty' 2>/dev/null)" in
  */.codex/*) agent=codex ;;
esac
sid=$(printf '%s' "$input" | "$JQ" -r '.session_id // empty' 2>/dev/null)
case "$sid" in "" | */* | .*) exit 0 ;; esac
file="$dir/$sid.json"

event=$(printf '%s' "$input" | "$JQ" -r '.hook_event_name // empty' 2>/dev/null)
if [ "$event" = "SessionEnd" ]; then
  rm -f "$file"
  exit 0
fi

prev=$("$JQ" -c 'if type == "object" then . else {} end' "$file" 2>/dev/null)
[ -n "$prev" ] || prev='{}'

# Once per session, find the app hosting Claude (Terminal, iTerm, VS Code, the Claude app...)
# and the terminal tab's tty, so clicking the pill can bring that exact window forward.
host_app=""
tty=""
if [ "$(printf '%s' "$prev" | "$JQ" -r 'has("host_app")')" != "true" ]; then
  pid=$PPID
  n=0
  while [ "${pid:-0}" -gt 1 ] && [ $n -lt 20 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$tty" ] && [ -n "$t" ] && [ "$t" != "??" ] && tty="/dev/$t"
    case "$comm" in
      *.app/Contents/*) host_app="${comm%%.app/Contents/*}.app" ;; # keep walking: the outermost app wins
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    n=$((n + 1))
  done
fi

printf '%s' "$input" | "$JQ" -c --argjson prev "$prev" --arg now "$(date +%s)" \
  --arg host "$host_app" --arg tty "$tty" --arg agent "$agent" '
  ($now | tonumber) as $t
  | {
      session_id,
      agent: $agent,
      cwd,
      transcript_path,
      event: .hook_event_name,
      tool: .tool_name,
      detail: (
        if (.tool_input | type) == "object" then
          (.tool_input | (.command // .cmd // .file_path // .path // .notebook_path // .pattern // .url
                          // .query // .description // .questions[0].question? // .questions[0].title? // .skill // .prompt // .input))
        elif (.tool_input | type) == "string" then .tool_input
        elif .agent_type then .agent_type
        else null end
        | if type == "string" then .[0:400] else null end
      ),
      options: (
        if .tool_name == "AskUserQuestion" then
          [.tool_input.questions[0].options[]?.label? | strings | .[0:60]] | .[0:6]
        else null end
      ),
      message,
      notification_type,
      error: (if (.error | type) == "string" then .error[0:400] else null end),
      error_details: (if (.error_details | type) == "string" then .error_details[0:400] else null end),
      is_interrupt: (.is_interrupt == true or .hook_event_name == "Interrupt"),
      reason: (if (.reason | type) == "string" then .reason[0:300] else null end),
      trigger: (if (.trigger | type) == "string" then .trigger else null end),
      last_message: (if (.last_assistant_message | type) == "string" then .last_assistant_message[-800:] else null end),
      agents: (
        if .hook_event_name == "SubagentStart" then (($prev.agents // 0) + 1)
        elif .hook_event_name == "SubagentStop" then ([($prev.agents // 0) - 1, 0] | max)
        elif .hook_event_name == "UserPromptSubmit" or .hook_event_name == "Stop"
             or .hook_event_name == "StopFailure" then 0
        else ($prev.agents // 0) end
      ),
      prompt: (if .hook_event_name == "UserPromptSubmit" then ((.prompt // "") | .[0:400]) else $prev.prompt end),
      turn_ts: (if .hook_event_name == "UserPromptSubmit" then $t else ($prev.turn_ts // $t) end),
      host_app: (if $prev | has("host_app") then $prev.host_app else $host end),
      tty: (if $prev | has("tty") then $prev.tty else $tty end),
      ts: $t
    }
' > "$file.tmp" 2>/dev/null && mv -f "$file.tmp" "$file"

rm -f "$file.tmp" 2>/dev/null
exit 0
