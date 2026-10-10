# Unit tests for hooks/permission-hook.ps1. Runs every case in tests/cases.json (shared with
# tests/test-hook.sh), then checks the deny message, the log and the command line. The hook
# runs under the same PowerShell as this script, so run it with both powershell.exe and pwsh
# on Windows.
#
# usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-hook.ps1
#        pwsh -NoProfile -File tests/test-hook.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$hook = Join-Path (Join-Path $repo 'hooks') 'permission-hook.ps1'
$shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$utf8 = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = $utf8

$tmp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
$env:CLAUDE_CONFIG_DIR = Join-Path $tmp 'config'
Remove-Item Env:CLAUDE_PERMISSION_HOOK_MODE, Env:CLAUDE_PERMISSION_HOOK_LOG -ErrorAction SilentlyContinue
$hooksDir = Join-Path $env:CLAUDE_CONFIG_DIR 'hooks'
$modeFile = Join-Path $hooksDir 'permission-hook.mode'
$logFile = Join-Path $hooksDir 'permission-hook.log'
[void](New-Item -ItemType Directory -Force -Path $hooksDir)

$script:passed = 0
$script:failed = 0
function Pass { $script:passed++ }
function Fail([string] $what) { $script:failed++; Write-Host "FAIL: $what" }

# The PermissionRequest input Claude Code would send for a case.
function New-HookInput($case) {
    $toolInput = if ($case.command) { [ordered]@{ command = $case.command; description = 'test' } }
                 else { [ordered]@{ file_path = '/work/a.txt'; content = 'x' } }
    [ordered]@{
        session_id = 'test'; cwd = '/work'; permission_mode = $case.permission_mode
        hook_event_name = 'PermissionRequest'; tool_name = $case.tool; tool_input = $toolInput
        permission_suggestions = @()
    } | ConvertTo-Json -Compress -Depth 5
}

# Runs the hook with the given stdin and returns its output as one string.
function Invoke-Hook([string] $stdin, [string[]] $arguments = @()) {
    $psi = [Diagnostics.ProcessStartInfo]::new($shell)
    $all = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $hook) + $arguments
    if ($null -ne $psi.PSObject.Properties['ArgumentList']) {
        foreach ($a in $all) { $psi.ArgumentList.Add($a) }
    } else {
        # .NET Framework (Windows PowerShell 5.1) has no ArgumentList; none of these contain quotes.
        $psi.Arguments = ($all | ForEach-Object { "`"$_`"" }) -join ' '
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $process = [Diagnostics.Process]::Start($psi)
    $writer = [IO.StreamWriter]::new($process.StandardInput.BaseStream, $utf8)
    $writer.Write($stdin)
    $writer.Close()
    $out = $process.StandardOutput.ReadToEnd()
    [void]$process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $script:lastExitCode = $process.ExitCode
    return $out.Trim()
}

function Get-Decision([string] $output) {
    if (-not $output) { return 'none' }
    try {
        $parsed = $output | ConvertFrom-Json
        if ($parsed.hookSpecificOutput.hookEventName -ne 'PermissionRequest') { return 'invalid' }
        return [string]$parsed.hookSpecificOutput.decision.behavior
    } catch { return 'invalid' }
}

try {
    $cases = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'cases.json'), $utf8) | ConvertFrom-Json
    foreach ($case in $cases) {
        if (-not $case.expect) { continue }
        if ($null -ne $case.PSObject.Properties['file']) { [IO.File]::WriteAllText($modeFile, $case.file, $utf8) }
        else { Remove-Item -LiteralPath $modeFile -Force -ErrorAction SilentlyContinue }
        if ($case.env) { $env:CLAUDE_PERMISSION_HOOK_MODE = $case.env } else { Remove-Item Env:CLAUDE_PERMISSION_HOOK_MODE -ErrorAction SilentlyContinue }
        $got = Get-Decision (Invoke-Hook (New-HookInput $case))
        if ($got -eq $case.expect) { Pass } else { Fail "$($case | ConvertTo-Json -Compress): got $got" }
    }
    Remove-Item Env:CLAUDE_PERMISSION_HOOK_MODE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $modeFile -Force -ErrorAction SilentlyContinue

    $bypassRm = New-HookInput ([pscustomobject]@{ permission_mode = 'bypassPermissions'; tool = 'Bash'; command = 'rm -f *' })

    # The deny message reaches Claude intact.
    $message = (Invoke-Hook $bypassRm | ConvertFrom-Json).hookSpecificOutput.decision.message
    if ($message -like '*literal absolute path*"${VAR:?}"*') { Pass } else { Fail "deny-rm message: $message" }

    # Decisions are logged as tab-separated lines; CLAUDE_PERMISSION_HOOK_LOG=0 turns that off.
    Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
    [void](Invoke-Hook $bypassRm)
    $line = @(Get-Content -LiteralPath $logFile -Encoding UTF8)[-1]
    if (($line -split "`t", 2)[1] -ceq "deny`tdeny-rm`tbypassPermissions`tBash`trm -f *") { Pass } else { Fail "log line: $line" }
    $env:CLAUDE_PERMISSION_HOOK_LOG = '0'
    [void](Invoke-Hook $bypassRm)
    Remove-Item Env:CLAUDE_PERMISSION_HOOK_LOG
    if (@(Get-Content -LiteralPath $logFile).Count -eq 1) { Pass } else { Fail 'CLAUDE_PERMISSION_HOOK_LOG=0 still logged' }
    [void](Invoke-Hook (New-HookInput ([pscustomobject]@{ permission_mode = 'bypassPermissions'; tool = 'Bash'; command = 'ls' })))
    if (@(Get-Content -LiteralPath $logFile).Count -eq 1) { Pass } else { Fail 'a prompt the hook did not answer was logged' }

    # Command line.
    $out = Invoke-Hook '' @('status')
    if ($out -like '*mode: deny-rm (default)*') { Pass } else { Fail "status: $out" }
    [void](Invoke-Hook '' @('allow-all'))
    if ((Get-Content -LiteralPath $modeFile -TotalCount 1) -eq 'allow-all') { Pass } else { Fail 'setting allow-all' }
    $env:CLAUDE_PERMISSION_HOOK_MODE = 'off'
    $out = Invoke-Hook '' @('status')
    Remove-Item Env:CLAUDE_PERMISSION_HOOK_MODE
    if ($out -like '*mode: off (env)*') { Pass } else { Fail "status with env: $out" }
    [void](Invoke-Hook '' @('reset'))
    if (-not (Test-Path -LiteralPath $modeFile)) { Pass } else { Fail 'reset' }
    [void](Invoke-Hook '' @('bogus'))
    if ($script:lastExitCode -eq 2 -and -not (Test-Path -LiteralPath $modeFile)) { Pass } else { Fail "an unknown mode should exit 2 and change nothing (exit $script:lastExitCode)" }
    $out = Invoke-Hook '' @('--help')
    if ($out -like '*usage: permission-hook.ps1*') { Pass } else { Fail '--help' }
} finally {
    if (Test-Path -LiteralPath $tmp) { [IO.Directory]::Delete($tmp, $true) }
}

Write-Host "$script:passed passed, $script:failed failed ($($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion))"
if ($script:failed -gt 0) { exit 1 }
