<#
.SYNOPSIS
Remove permission-hook, on Windows.

.DESCRIPTION
Takes the hook's entry out of <config dir>\settings.json and deletes the hook scripts and the
mode file. The decision log is kept. The config dir is $env:CLAUDE_CONFIG_DIR, or ~\.claude
when that is not set.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'settings.ps1')

$configDir = Get-ClaudeConfigDir
$hooksDir = Join-Path $configDir 'hooks'

Update-Settings (Join-Path $configDir 'settings.json') { param($s) Remove-OurHook $s }
foreach ($name in 'permission-hook.ps1', 'permission-hook.cmd', 'permission-hook.sh', 'permission-hook.mode') {
    Remove-Item -LiteralPath (Join-Path $hooksDir $name) -Force -ErrorAction SilentlyContinue
}
Write-Host "removed: the hook scripts and mode file in $hooksDir"
if (Test-Path -LiteralPath (Join-Path $hooksDir 'permission-hook.log')) {
    Write-Host "kept: $(Join-Path $hooksDir 'permission-hook.log') (delete it yourself if you don't need it)"
}
Write-Host 'Restart any open Claude Code session to stop it using the hook.'
