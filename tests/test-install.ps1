# Tests for install.ps1 and uninstall.ps1, run against a throwaway CLAUDE_CONFIG_DIR. The
# installers run under the same PowerShell as this script, so run it with both powershell.exe
# and pwsh on Windows. On macOS and Linux, pwsh must be on PATH.
#
# usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-install.ps1
#        pwsh -NoProfile -File tests/test-install.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$onWindows = $env:OS -eq 'Windows_NT'
$utf8 = [System.Text.UTF8Encoding]::new($false)

$tmp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
$env:CLAUDE_CONFIG_DIR = Join-Path $tmp 'config'
$settings = Join-Path $env:CLAUDE_CONFIG_DIR 'settings.json'
$hooksDir = Join-Path $env:CLAUDE_CONFIG_DIR 'hooks'
$hook = Join-Path $hooksDir 'permission-hook.ps1'
[void](New-Item -ItemType Directory -Force -Path $env:CLAUDE_CONFIG_DIR)

$script:passed = 0
$script:failed = 0
function Check([string] $what, [bool] $ok) {
    if ($ok) { $script:passed++ } else { $script:failed++; Write-Host "FAIL: $what" }
}

function Invoke-Script([string] $name, [string[]] $arguments = @()) {
    $output = & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repo $name) @arguments 2>&1
    $script:lastOutput = $output | Out-String
    return $LASTEXITCODE
}

function Read-Json([string] $path) { [IO.File]::ReadAllText($path, $utf8) | ConvertFrom-Json }
function Get-OurEntries {
    @((Read-Json $settings).hooks.PermissionRequest | ForEach-Object { $_.hooks } |
        Where-Object { (@($_.command) + @($_.args)) -join ' ' -match 'permission-hook\.(sh|ps1)' })
}
function Get-Backups { @(Get-ChildItem -LiteralPath $env:CLAUDE_CONFIG_DIR -Filter 'settings.json.bak-*') }

try {
    [IO.File]::WriteAllText($settings, @'
{
  "model": "opus",
  "permissions": { "allow": ["Bash(npm run *)"] },
  "hooks": {
    "PermissionRequest": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "other-hook.sh" }] }
    ],
    "Stop": [{ "hooks": [{ "type": "command", "command": "notify.sh" }] }]
  }
}
'@, $utf8)

    # Install into existing settings, keeping everything else.
    Check 'install exits 0' ((Invoke-Script 'install.ps1') -eq 0)
    Check 'hook copied' ((Test-Path -LiteralPath $hook) -and -not ((Get-Item -LiteralPath $hook).LinkType))
    Check '.cmd wrapper copied on Windows only' ((Test-Path -LiteralPath (Join-Path $hooksDir 'permission-hook.cmd')) -eq $onWindows)
    $s = Read-Json $settings
    $entry = @(Get-OurEntries)
    Check 'one hook entry' ($entry.Count -eq 1)
    Check 'entry matches every tool' ($s.hooks.PermissionRequest[-1].matcher -eq '*')
    $expectedShell = if ($onWindows) { 'powershell.exe' } else { 'pwsh' }
    Check 'entry runs PowerShell in exec form' ($entry[0].command -eq $expectedShell -and $entry[0].args[-1] -eq $hook -and $entry[0].args -contains 'Bypass')
    Check 'other PermissionRequest hook kept' ($s.hooks.PermissionRequest[0].hooks[0].command -eq 'other-hook.sh')
    Check 'other hook events kept' ($s.hooks.Stop[0].hooks[0].command -eq 'notify.sh')
    Check 'other settings kept' ($s.model -eq 'opus' -and $s.permissions.allow[0] -eq 'Bash(npm run *)')
    Check 'settings backed up' ((Get-Backups).Count -eq 1)
    Check 'settings written without a BOM' ([IO.File]::ReadAllBytes($settings)[0] -eq [byte][char]'{')

    # Running it again changes nothing.
    Check 'second install exits 0' ((Invoke-Script 'install.ps1') -eq 0)
    Check 'second install keeps one entry' (@(Get-OurEntries).Count -eq 1)
    Check 'second install makes no backup' ((Get-Backups).Count -eq 1)
    Check 'second install says up to date' ($script:lastOutput -match 'already up to date')

    # -Link symlinks the hook to the checkout.
    Check '-Link exits 0' ((Invoke-Script 'install.ps1' @('-Link')) -eq 0)
    Check '-Link symlinks the hook' ((Get-Item -LiteralPath $hook).LinkType -eq 'SymbolicLink')
    Check '-Link keeps one entry' (@(Get-OurEntries).Count -eq 1)

    # The installed hook answers prompts.
    $out = '{"permission_mode":"bypassPermissions","tool_name":"Bash","tool_input":{"command":"rm -f *"}}' |
        & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $hook
    Check 'installed hook denies an rm prompt' ((($out | Out-String) | ConvertFrom-Json).hookSpecificOutput.decision.behavior -eq 'deny')

    # Uninstall takes out only our entry and files.
    [void](& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $hook allow-all)
    Check 'uninstall exits 0' ((Invoke-Script 'uninstall.ps1') -eq 0)
    Check 'hook removed' (-not (Test-Path -LiteralPath $hook))
    Check 'mode file removed' (-not (Test-Path -LiteralPath (Join-Path $hooksDir 'permission-hook.mode')))
    Check '.cmd wrapper removed' (-not (Test-Path -LiteralPath (Join-Path $hooksDir 'permission-hook.cmd')))
    Check 'no entries left' (@(Get-OurEntries).Count -eq 0)
    $s = Read-Json $settings
    Check 'other PermissionRequest hook kept on uninstall' ($s.hooks.PermissionRequest[0].hooks[0].command -eq 'other-hook.sh')
    Check 'other settings kept on uninstall' ($s.model -eq 'opus')
    Check 'second uninstall is harmless' ((Invoke-Script 'uninstall.ps1') -eq 0)

    # An entry written by install.sh is replaced, not duplicated.
    [IO.File]::WriteAllText($settings, '{"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[{"type":"command","command":"~/.claude/hooks/permission-hook.sh"}]}]}}', $utf8)
    [void](Invoke-Script 'install.ps1')
    $entry = @(Get-OurEntries)
    Check 'install.sh entry replaced' ($entry.Count -eq 1 -and $entry[0].args[-1] -eq $hook)
    [void](Invoke-Script 'uninstall.ps1')

    # With no settings file, install creates one, and uninstall leaves no empty hooks object.
    Remove-Item -LiteralPath $settings -Force
    Get-Backups | Remove-Item -Force
    [void](Invoke-Script 'install.ps1')
    Check 'install creates settings.json' (@(Get-OurEntries).Count -eq 1)
    [void](Invoke-Script 'uninstall.ps1')
    Check 'uninstall drops the empty hooks object' (@((Read-Json $settings).PSObject.Properties).Count -eq 0)

    # Invalid JSON is left alone.
    [IO.File]::WriteAllText($settings, '{ "model": "opus"', $utf8)
    Check 'install fails on invalid settings' ((Invoke-Script 'install.ps1') -ne 0)
    Check 'invalid settings untouched' ([IO.File]::ReadAllText($settings) -ceq '{ "model": "opus"')

    # A symlinked settings.json is updated through the link.
    $real = Join-Path $tmp 'real-settings.json'
    [IO.File]::WriteAllText($real, '{"model": "opus"}', $utf8)
    Remove-Item -LiteralPath $settings -Force
    [void](New-Item -ItemType SymbolicLink -Path $settings -Target $real)
    [void](Invoke-Script 'install.ps1')
    Check 'symlinked settings.json stays a symlink' ((Get-Item -LiteralPath $settings).LinkType -eq 'SymbolicLink')
    Check 'symlink target updated' (@((Read-Json $real).hooks.PermissionRequest).Count -eq 1)
} finally {
    if (Test-Path -LiteralPath $tmp) { [IO.Directory]::Delete($tmp, $true) }
}

Write-Host "$script:passed passed, $script:failed failed ($($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion))"
if ($script:failed -gt 0) { exit 1 }
