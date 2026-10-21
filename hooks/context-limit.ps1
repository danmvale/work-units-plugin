# PowerShell port of context-limit.sh, for Windows without Git Bash, where Claude Code runs hooks
# in PowerShell (see context-limit.sh for how it works). Keep the two in sync. It must run in
# Windows PowerShell 5.1 and PowerShell 7, and it must always exit 0: in PowerShell, any other exit
# code makes the hook a blocking error.

$ContextLimit = 500000
$ReminderStep = 50000

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try {
  # Read stdin as UTF-8 whatever the console code page is.
  $utf8 = New-Object System.Text.UTF8Encoding $false
  $raw = (New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $utf8)).ReadToEnd()

  # Only the top-level fields before tool_input are needed. Cutting the rest keeps tool payloads from
  # posing as top-level fields.
  $top = $raw.Substring(0, [Math]::Min($raw.Length, 16384))
  $cut = $top.IndexOf(',"tool_input":', [StringComparison]::Ordinal)
  if ($cut -ge 0) { $top = $top.Substring(0, $cut) }

  # Returns the string value of the given top-level key, or $null.
  function Get-Field($key) {
    $m = [regex]::Match($top, '"' + $key + '":"([^"]*)"')
    if ($m.Success) { $m.Groups[1].Value } else { $null }
  }

  if ((Get-Field 'agent_type') -cne 'work-units:work-unit-executor') { exit 0 }
  $eventName = Get-Field 'hook_event_name'
  $tool = Get-Field 'tool_name'
  $agentId = Get-Field 'agent_id'
  $transcript = Get-Field 'transcript_path'

  if ($eventName -cne 'PostToolUse' -and $eventName -cne 'PostToolUseFailure') { exit 0 }
  # The executor has already delivered its final report; don't wake it up again.
  if ($tool -ceq 'SubagentHandback') { exit 0 }
  if ($agentId -cnotmatch '^[A-Za-z0-9_-]+$' -or -not $transcript) { exit 0 }

  # transcript_path is the parent session's transcript. The executor's own transcript is
  # {session}/subagents/agent-{agent_id}.jsonl next to it. JSON escapes backslashes.
  $transcript = $transcript.Replace('\\', '\')
  $transcript = [IO.Path]::Combine(($transcript -replace '\.jsonl$', ''), 'subagents', "agent-$agentId.jsonl")
  if (-not [IO.File]::Exists($transcript)) { exit 0 }

  # The context size is the input side of the executor's latest API response. Only assistant lines
  # carry the executor's own usage. Claude Code may be appending to the file, so share it.
  $line = $null
  $stream = New-Object System.IO.FileStream($transcript, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  $reader = New-Object System.IO.StreamReader($stream, $utf8)
  try {
    while ($null -ne ($l = $reader.ReadLine())) {
      if ($l.Contains('"usage":{') -and $l.Contains('"type":"assistant"') -and -not $l.Contains('"model":"<synthetic>"')) { $line = $l }
    }
  } finally {
    $reader.Dispose()
  }
  if (-not $line) { exit 0 }
  $usage = $line.Substring($line.LastIndexOf('"usage":{', [StringComparison]::Ordinal))
  $tokens = [long]0
  foreach ($key in 'input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens') {
    $m = [regex]::Match($usage, '"' + $key + '":([0-9]+)')
    if ($m.Success) { $tokens += [long]$m.Groups[1].Value }
  }
  if ($tokens -lt $ContextLimit) { exit 0 }

  # One marker per notice: the first at the limit, then one for every ReminderStep tokens over it.
  # CreateNew fails when the marker exists, so each notice is sent once.
  $notice = [long][Math]::Floor(($tokens - $ContextLimit) / $ReminderStep)
  $dataDir = $env:CLAUDE_PLUGIN_DATA
  if (-not $dataDir) { $dataDir = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'work-units') }
  $markerDir = [IO.Path]::Combine($dataDir, 'context-limit', $agentId)
  [void][IO.Directory]::CreateDirectory($markerDir)
  try {
    [IO.File]::Open([IO.Path]::Combine($markerDir, [string]$notice), [IO.FileMode]::CreateNew).Dispose()
  } catch {
    exit 0
  }
  if ([IO.Directory]::GetFiles($markerDir).Length -eq 1) {
    $intro = "Context limit reached: your context is about $tokens tokens, and the limit for a work-unit-executor is $ContextLimit."
  } else {
    $intro = "Reminder, context limit exceeded: your context is now about $tokens tokens, and the limit for a work-unit-executor is $ContextLimit."
  }

  # The message goes into a JSON string as is, so it must not contain double quotes or backslashes
  # other than the \n line breaks.
  $message = "[work-units] $intro Stop working on the work unit now and hand it off (step 4 of your workflow; if you're in plan mode, exit it first). Don't start any new implementation, test or review, and don't trigger a reviewer.\n1. Update task.md with what you have done (including whether you've already triggered a reviewer, and what has and hasn't been verified and approved) + notes for next agents.\n2. Set the work unit's status to In Progress in both the Status and Work units sections (not Completed, since the work unit isn't complete yet).\n3. Then end by giving your parent agent instructions to trigger another work-unit-executor agent to continue this work unit. Make the handoff to the next agent clear.\nIf you had already finished the work unit before this notice (reviewed, approved and marked Completed in task.md), just finish your report. Otherwise, don't try to finish it first: hand it off now."

  [Console]::Out.Write('{"hookSpecificOutput":{"hookEventName":"' + $eventName + '","additionalContext":"' + $message + '"}}')
} catch {
}
exit 0
