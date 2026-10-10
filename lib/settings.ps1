# Helpers for install.ps1 and uninstall.ps1: find the Claude Code config dir and add or remove
# the permission-hook entry in its settings.json. Mirrors lib/edit_settings.py: any hook that
# runs permission-hook.sh or permission-hook.ps1 counts as ours, other settings and hooks are
# kept, and a file that changes is backed up to settings.json.bak-<timestamp> first.
# Works on Windows PowerShell 5.1 and PowerShell 7.

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-ClaudeConfigDir {
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return Join-Path $HOME '.claude'
}

function Test-OnWindows { return $env:OS -eq 'Windows_NT' }

# The file a settings.json path really refers to, following a symlink so it stays a symlink.
function Resolve-SettingsPath([string] $path) {
    $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq 'SymbolicLink') {
        $target = @($item.Target)[0]
        if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path -Parent $path) $target }
        return $target
    }
    return $path
}

function Read-SettingsText([string] $path) {
    if (-not (Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -eq 0) { return '{}' }
    $text = [IO.File]::ReadAllText($path, $script:Utf8NoBom)
    try { $parsed = $text | ConvertFrom-Json } catch { throw "$path is not valid JSON ($($_.Exception.Message)); fix it first, nothing was changed" }
    if ($parsed -isnot [pscustomobject]) { throw "$path does not hold a JSON object; nothing was changed" }
    return $text
}

function Test-OurHook($hook) {
    if ($hook -isnot [pscustomobject]) { return $false }
    $parts = @($hook.command) + @($hook.args) | Where-Object { $null -ne $_ }
    return [bool](($parts -join ' ') -match 'permission-hook\.(sh|ps1)')
}

function Set-Property($object, [string] $name, $value) {
    if ($null -ne $object.PSObject.Properties[$name]) { $object.$name = $value }
    else { $object | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

# PermissionRequest matcher groups with our hook taken out, as a list.
function Get-OtherGroups($groups) {
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($group in @($groups)) {
        if ($null -eq $group) { continue }
        if ($group -isnot [pscustomobject] -or $null -eq $group.PSObject.Properties['hooks']) { $kept.Add($group); continue }
        $hooks = @(@($group.hooks) | Where-Object { -not (Test-OurHook $_) })
        if ($hooks.Count -gt 0) {
            $group.hooks = $hooks
            $kept.Add($group)
        }
    }
    return , $kept
}

function Add-OurHook($settings, [string] $command, [string[]] $hookArgs) {
    if ($null -eq $settings.PSObject.Properties['hooks'] -or $settings.hooks -isnot [pscustomobject]) {
        Set-Property $settings 'hooks' ([pscustomobject]@{})
    }
    $groups = Get-OtherGroups $settings.hooks.PermissionRequest
    $entry = [pscustomobject][ordered]@{ type = 'command'; command = $command; args = $hookArgs }
    $groups.Add([pscustomobject][ordered]@{ matcher = '*'; hooks = @($entry) })
    Set-Property $settings.hooks 'PermissionRequest' $groups.ToArray()
}

function Remove-OurHook($settings) {
    if ($null -eq $settings.PSObject.Properties['hooks'] -or $settings.hooks -isnot [pscustomobject]) { return }
    if ($null -eq $settings.hooks.PSObject.Properties['PermissionRequest']) { return }
    $groups = Get-OtherGroups $settings.hooks.PermissionRequest
    if ($groups.Count -gt 0) { $settings.hooks.PermissionRequest = $groups.ToArray() }
    else { $settings.hooks.PSObject.Properties.Remove('PermissionRequest') }
    if (@($settings.hooks.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }
}

# Applies $change (a script block taking the parsed settings) to settings.json and writes the
# result if anything changed.
function Update-Settings([string] $path, [scriptblock] $change) {
    $path = Resolve-SettingsPath $path
    $text = Read-SettingsText $path
    $before = $text | ConvertFrom-Json
    $settings = $text | ConvertFrom-Json
    & $change $settings
    $beforeJson = ConvertTo-Json -InputObject $before -Depth 100 -Compress
    $afterJson = ConvertTo-Json -InputObject $settings -Depth 100 -Compress
    if ($beforeJson -ceq $afterJson) {
        if (Test-Path -LiteralPath $path) { Write-Host "${path}: already up to date" } else { Write-Host "${path}: nothing to change" }
        return
    }
    $dir = Split-Path -Parent $path
    if ($dir) { [void](New-Item -ItemType Directory -Force -Path $dir) }
    if (Test-Path -LiteralPath $path) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$path.bak-$stamp"
        $n = 1
        while (Test-Path -LiteralPath $backup) { $backup = "$path.bak-$stamp-$n"; $n++ }
        Copy-Item -LiteralPath $path -Destination $backup
        Write-Host "${path}: backed up to $backup"
    }
    $tmp = Join-Path $dir ".settings-$([Guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $settings -Depth 100) + "`n", $script:Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $path -Force
    Write-Host "${path}: updated"
}
