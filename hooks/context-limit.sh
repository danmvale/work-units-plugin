#!/usr/bin/env bash
# PostToolUse / PostToolUseFailure hook that soft-stops a work-unit-executor once its context
# reaches CONTEXT_LIMIT tokens: it tells the executor to hand off its work unit (step 4 of its
# workflow in agents/work-unit-executor.md) without blocking its tools, so it can still write the
# handoff. If the executor keeps working, it's reminded every REMINDER_STEP tokens.
# It runs on every tool call of every session, so it exits early outside executors. It fails open:
# on any problem it prints nothing.
# context-limit.ps1 is its PowerShell port, for Windows without Git Bash, where Claude Code runs
# hooks in PowerShell; keep the two in sync. hooks.json runs them with a command that is valid in
# both shells: bash runs this script and treats the second line as a comment, while PowerShell
# reads the rest of the first line as the start of a <# #> block comment and runs the port.

CONTEXT_LIMIT=500000
REMINDER_STEP=50000

# Byte semantics: faster string handling and grep, and paths with any bytes still match.
export LC_ALL=C

# Only the top-level fields before tool_input are needed. Cutting the rest keeps this fast on
# megabyte payloads and keeps tool payloads from posing as top-level fields.
input=$(cat)
input=${input:0:16384}
input=${input%%',"tool_input":'*}

# Sets REPLY to the string value of the given top-level key.
field() {
  local re="\"$1\":\"([^\"]*)\""
  [[ $input =~ $re ]] || return 1
  REPLY=${BASH_REMATCH[1]}
}

field agent_type || exit 0
[[ $REPLY == work-units:work-unit-executor ]] || exit 0
field hook_event_name || exit 0; event=$REPLY
field tool_name || exit 0; tool=$REPLY
field agent_id || exit 0; agent_id=$REPLY
field transcript_path || exit 0; transcript=$REPLY

[[ $event == PostToolUse || $event == PostToolUseFailure ]] || exit 0
# The executor has already delivered its final report; don't wake it up again.
[[ $tool == SubagentHandback ]] && exit 0
[[ $agent_id =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

# transcript_path is the parent session's transcript. The executor's own transcript is
# {session}/subagents/agent-{agent_id}.jsonl next to it. JSON escapes Windows backslashes, so turn
# them into forward slashes.
transcript=${transcript//\\\\//}
transcript="${transcript%.jsonl}/subagents/agent-$agent_id.jsonl"
[[ -f $transcript ]] || exit 0

# The context size is the input side of the executor's latest API response, the formula the status
# line uses. Only assistant lines carry the executor's own usage: Agent tool results carry the
# nested agent's usage, and synthetic messages carry zeros.
line=$(grep -F '"type":"assistant"' "$transcript" | grep -F '"usage":{' | grep -Fv '"model":"<synthetic>"' | tail -n 1)
usage_key='"usage":{'
usage=${line##*"$usage_key"}
tokens=0
for key in input_tokens cache_creation_input_tokens cache_read_input_tokens; do
  re="\"$key\":([0-9]+)"
  [[ $usage =~ $re ]] && tokens=$((tokens + 10#${BASH_REMATCH[1]}))
done
((tokens >= CONTEXT_LIMIT)) || exit 0

# One marker per notice: the first at the limit, then one for every REMINDER_STEP tokens over it.
# noclobber makes creating a marker atomic, so when parallel tool calls run this hook at the same
# time, each notice is sent once.
notice=$(((tokens - CONTEXT_LIMIT) / REMINDER_STEP))
marker_dir="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/work-units}/context-limit/$agent_id"
mkdir -p "$marker_dir" 2>/dev/null || exit 0
(set -C; : > "$marker_dir/$notice") 2>/dev/null || exit 0
markers=("$marker_dir"/*)
if ((${#markers[@]} == 1)); then
  intro="Context limit reached: your context is about $tokens tokens, and the limit for a work-unit-executor is $CONTEXT_LIMIT."
else
  intro="Reminder, context limit exceeded: your context is now about $tokens tokens, and the limit for a work-unit-executor is $CONTEXT_LIMIT."
fi

# The message goes into a JSON string as is, so it must not contain double quotes or backslashes
# other than the \n line breaks.
message="[work-units] $intro Stop working on the work unit now and hand it off (step 4 of your workflow; if you're in plan mode, exit it first). Don't start any new implementation, test or review, and don't trigger a reviewer.\n1. Update task.md with what you have done (including whether you've already triggered a reviewer, and what has and hasn't been verified and approved) + notes for next agents.\n2. Set the work unit's status to In Progress in both the Status and Work units sections (not Completed, since the work unit isn't complete yet).\n3. Then end by giving your parent agent instructions to trigger another work-unit-executor agent to continue this work unit. Make the handoff to the next agent clear.\nIf you had already finished the work unit before this notice (reviewed, approved and marked Completed in task.md), just finish your report. Otherwise, don't try to finish it first: hand it off now."

printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$event" "$message"
