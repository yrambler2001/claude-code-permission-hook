<#
.SYNOPSIS
Install permission-hook for the current user, on Windows.

.DESCRIPTION
Copies hooks\permission-hook.ps1 into <config dir>\hooks, along with permission-hook.cmd for
switching modes, and registers the hook as a PermissionRequest hook in <config dir>\settings.json.
Claude Code runs it through powershell.exe, or pwsh on macOS and Linux, so it works with or
without Git Bash. Safe to run again, for example after pulling a new version.

The config dir is $env:CLAUDE_CONFIG_DIR, or ~\.claude when that is not set. On macOS and
Linux, install.sh is the usual choice; this script works there too if you prefer PowerShell.

.PARAMETER Link
Symlink the hook to this checkout instead of copying it, so edits apply at once. On Windows
this needs Developer Mode or an elevated prompt.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding()]
param([switch] $Link)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'settings.ps1')

$configDir = Get-ClaudeConfigDir
$hooksDir = Join-Path $configDir 'hooks'
$source = Join-Path (Join-Path $PSScriptRoot 'hooks') 'permission-hook.ps1'
$target = Join-Path $hooksDir 'permission-hook.ps1'

[void](New-Item -ItemType Directory -Force -Path $hooksDir)
Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
if ($Link) {
    [void](New-Item -ItemType SymbolicLink -Path $target -Target $source)
    Write-Host "hook: $target -> $source"
} else {
    Copy-Item -LiteralPath $source -Destination $target
    Write-Host "hook: $target"
}
if (Test-OnWindows) {
    Copy-Item -LiteralPath (Join-Path (Join-Path $PSScriptRoot 'hooks') 'permission-hook.cmd') -Destination (Join-Path $hooksDir 'permission-hook.cmd') -Force
}

$shell = if (Test-OnWindows) { 'powershell.exe' } else { 'pwsh' }
$hookArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $target)
Update-Settings (Join-Path $configDir 'settings.json') { param($s) Add-OurHook $s $shell $hookArgs }

Write-Host ''
& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $target status
Write-Host ''
Write-Host 'Installed. Sessions started from now on use the hook; restart any session already open.'
