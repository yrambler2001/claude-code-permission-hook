# permission-hook.ps1: a Claude Code PermissionRequest hook that answers permission prompts
# automatically, so sessions nobody is watching don't stall on a prompt. This is the Windows
# version of permission-hook.sh, with the same modes, mode file and log. It runs on Windows
# PowerShell 5.1 and PowerShell 7.
#
# Modes:
#   deny-rm    (default) In --dangerously-skip-permissions sessions, deny prompts for Bash
#              commands that run rm or rmdir, and tell Claude how to rewrite the command.
#   deny-all   In --dangerously-skip-permissions sessions, deny every prompt.
#   allow-all  Approve every prompt, in every permission mode.
#   off        Do nothing; every prompt reaches you.
#
# The mode comes from the first of:
#   1. the CLAUDE_PERMISSION_HOOK_MODE environment variable (unknown values are ignored)
#   2. the mode file, <config dir>\hooks\permission-hook.mode
#   3. deny-rm
#
# Run the script yourself to manage the mode (permission-hook.cmd next to it does the same):
#   powershell -NoProfile -ExecutionPolicy Bypass -File permission-hook.ps1 [status | deny-rm | deny-all | allow-all | off | reset]
#
# When it answers a prompt it prints the decision as JSON and logs it. In every other case,
# including errors, it prints nothing and Claude Code shows the prompt as usual.

$ErrorActionPreference = 'Stop'

$configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$modeFile = Join-Path (Join-Path $configDir 'hooks') 'permission-hook.mode'
$logFile = Join-Path (Join-Path $configDir 'hooks') 'permission-hook.log'
$modes = @('deny-rm', 'deny-all', 'allow-all', 'off')
$defaultMode = 'deny-rm'
$utf8 = [System.Text.UTF8Encoding]::new($false)

$denyRmMessage = 'Denied automatically by permission-hook (deny-rm): Claude Code could not verify what this rm deletes, and nobody is watching this session to approve it. Rewrite the command so every rm target is a literal absolute path: no cd before the rm, no $(...) or backticks, no unguarded $VAR (use "${VAR:?}"), no rm inside bash -c, and do not glob-clear the working directory itself. Then run the rewritten command.'
$denyAllMessage = 'Denied automatically by permission-hook (deny-all): nobody is watching this session to approve permission prompts. Do this another way that does not need approval. If there is none, stop and report which action needs approval and why.'

# Returns @(mode, source), where source is env, file or default.
function Resolve-Mode {
    if ($modes -ccontains $env:CLAUDE_PERMISSION_HOOK_MODE) { return @($env:CLAUDE_PERMISSION_HOOK_MODE, 'env') }
    $fromFile = $null
    try { $fromFile = (Get-Content -LiteralPath $modeFile -TotalCount 1 -ErrorAction Stop) -replace '\s', '' } catch { }
    if ($modes -ccontains $fromFile) { return @($fromFile, 'file') }
    return @($defaultMode, 'default')
}

$usage = @'
usage: permission-hook.ps1 [status | deny-rm | deny-all | allow-all | off | reset]

  status     show the current mode and recent decisions (the default)
  deny-rm    in --dangerously-skip-permissions sessions, deny rm prompts and tell Claude
             how to rewrite the command (the default mode)
  deny-all   in --dangerously-skip-permissions sessions, deny every prompt
  allow-all  approve every prompt, in every permission mode
  off        answer nothing; every prompt reaches you
  reset      delete the mode file, going back to deny-rm

The mode applies to every session and takes effect on the next prompt. To set it for one
session, start Claude with CLAUDE_PERMISSION_HOOK_MODE=<mode> in its environment instead.
'@

function Invoke-Cli([string[]] $arguments) {
    $command = if ($arguments.Count -gt 0) { $arguments[0] } else { 'status' }
    switch -CaseSensitive ($command) {
        'status' { }
        'reset' { Remove-Item -LiteralPath $modeFile -Force -ErrorAction SilentlyContinue }
        { $_ -in '-h', '--help', 'help' } { [Console]::Out.WriteLine($usage); return 0 }
        default {
            if ($modes -cnotcontains $command) { [Console]::Error.WriteLine($usage); return 2 }
            [void](New-Item -ItemType Directory -Force -Path (Split-Path $modeFile))
            [IO.File]::WriteAllText($modeFile, "$command`n", $utf8)
        }
    }
    $mode, $source = Resolve-Mode
    [Console]::Out.WriteLine("mode: $mode ($source)")
    [Console]::Out.WriteLine("mode file: $modeFile")
    [Console]::Out.WriteLine("log: $logFile")
    if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 0) {
        [Console]::Out.WriteLine('recent decisions:')
        Get-Content -LiteralPath $logFile -Tail 5 -Encoding UTF8 | ForEach-Object { [Console]::Out.WriteLine("  $_") }
    }
    return 0
}

# Claude Code runs the hook with JSON on stdin and no arguments.
if ($args.Count -gt 0 -or -not [Console]::IsInputRedirected) {
    exit (Invoke-Cli $args)
}

try {
    $stdin = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8)
    $request = $stdin.ReadToEnd() | ConvertFrom-Json
    $tool = [string]$request.tool_name
    $permissionMode = [string]$request.permission_mode
    $command = ''
    if ($request.tool_input -and $request.tool_input.command) { $command = [string]$request.tool_input.command }
    $mode = (Resolve-Mode)[0]

    function Add-DecisionLog([string] $decision) {
        if ($env:CLAUDE_PERMISSION_HOOK_LOG -eq '0') { return }
        try {
            $shown = $command -replace '[\r\n\t]', ' '
            if ($shown.Length -gt 300) { $shown = $shown.Substring(0, 300) }
            $time = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            [void](New-Item -ItemType Directory -Force -Path (Split-Path $logFile))
            [IO.File]::AppendAllText($logFile, "$time`t$decision`t$mode`t$permissionMode`t$tool`t$shown`n", $utf8)
        } catch { }
    }

    function Write-Decision([string] $behavior, [string] $message) {
        $decision = [ordered]@{ behavior = $behavior }
        if ($message) { $decision.message = $message }
        $output = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PermissionRequest'; decision = $decision } }
        Add-DecisionLog $behavior
        [Console]::Out.WriteLine(($output | ConvertTo-Json -Compress -Depth 5))
    }

    $runsRm = $command -cmatch '(?m)(^|[^A-Za-z0-9_.-])rm(dir)?([^A-Za-z0-9_.-]|$)'

    switch ($mode) {
        'allow-all' { Write-Decision 'allow' }
        'deny-all' { if ($permissionMode -eq 'bypassPermissions') { Write-Decision 'deny' $denyAllMessage } }
        'deny-rm' { if ($permissionMode -eq 'bypassPermissions' -and $tool -eq 'Bash' -and $runsRm) { Write-Decision 'deny' $denyRmMessage } }
    }
} catch { }
exit 0
