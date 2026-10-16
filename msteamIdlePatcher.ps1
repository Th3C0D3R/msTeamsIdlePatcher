<#
  Teams idle patch (regex/pattern version): neutralize osutils.getSystemIdleTime()
  - Backups to writable folder (%LOCALAPPDATA%\TeamsPatch\backup)
  - Self-elevates; -Restore reinstates newest backup
  - -Mode Passthrough keeps the native call but forces result to 0 (default: Spoof, never calls host)
#>
[CmdletBinding()]
param(
    [string]$BackupDir = "$env:LOCALAPPDATA\TeamsPatch\backup",
    [ValidateSet('Spoof','Passthrough')][string]$Mode = 'Spoof',
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

function Get-TeamsBundlePath {
    # Authoritative: the registered package's install location (survives version changes)
    $pkg = Get-AppxPackage -Name 'MSTeams' | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pkg) { throw 'MSTeams package not found for this user' }
    $b = Join-Path $pkg.InstallLocation 'client-bindings\bundle.js'
    if (Test-Path -LiteralPath $b) { return $b }

    # Fallback: newest MSTeams_* folder under WindowsApps (rollback leftovers may exist)
    $b = Get-ChildItem 'C:\Program Files\WindowsApps' -Directory -Filter 'MSTeams_*' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending |
         ForEach-Object { Join-Path $_.FullName 'client-bindings\bundle.js' } |
         Where-Object { Test-Path -LiteralPath $_ } |
         Select-Object -First 1
    if (-not $b) { throw 'client-bindings\bundle.js not found under WindowsApps' }
    return $b
}

$target = Get-TeamsBundlePath

# Anchors are the API name + call shape; minified ids are wildcards ($ = one ident char)
$pattern = 'function\s+(?<tok>[A-Za-z_$][\w$]{0,5})\s*\(\s*\)\s*\{\s*return\s+' +
           '(?<call>[A-Za-z_$][\w$]{0,5}\.HostBridge\.invokeHost\s*\(\s*' +
           '"osutils\.getSystemIdleTime"\s*,\s*\{\s*\}\s*,\s*' +
           '[A-Za-z_$][\w$]{0,5}\.NoopPostProcessingFactory\s*\(\s*\)\s*\))\s*\}'

function Test-Admin {
    ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host 'Not elevated - relaunching as Administrator...'
    Start-Process pwsh -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`""
    )
    exit
}

if (-not (Test-Path -LiteralPath $target)) { throw "Teams bundle not found: $target" }

Get-Process ms-teams -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

takeown /F $target | Out-Null
icacls $target /grant '*S-1-5-32-544:F' | Out-Null

if ($Restore) {
    $latest = Get-ChildItem -LiteralPath $BackupDir -Filter 'bundle.js-*.bak' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw "No backup found in $BackupDir" }
    [System.IO.File]::WriteAllText($target, [System.IO.File]::ReadAllText($latest.FullName),
                                   (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Restored: $($latest.Name)"
    return
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
$backup = Join-Path $BackupDir ("bundle.js-{0:yyyyMMdd-HHmmss}.bak" -f (Get-Date))
[System.IO.File]::Copy($target, $backup, $true)
Write-Host "Backup -> $backup"

$content = [System.IO.File]::ReadAllText($target)
$matches = [regex]::Matches($content, $pattern)

if ($matches.Count -eq 0) {
    if ($content -notmatch 'invokeHost\("osutils\.getSystemIdleTime"') {
        Write-Host 'Already patched (or API absent) - nothing to do.'
        return
    }
    $i = $content.IndexOf('"osutils.getSystemIdleTime"')
    $ctx = $content.Substring([Math]::Max(0,$i-200), [Math]::Min(400, $content.Length-[Math]::Max(0,$i-200)))
    throw ("Binding found but shape changed - update `$pattern. Context: ...$ctx...")
}
Write-Host "Matched $($matches.Count) binding(s): token='$($matches[0].Groups['tok'].Value)'"

$patched = [regex]::Replace($content, $pattern, {
    param($m)
    $tok = $m.Groups['tok'].Value
    if ($Mode -eq 'Passthrough') {
        "function $tok(){return $($m.Groups['call'].Value).then(()=>0)}"
    } else {
        "function $tok(){return Promise.resolve(0)}"
    }
})

[System.IO.File]::WriteAllText($target, $patched, (New-Object System.Text.UTF8Encoding($false)))

$verify = [System.IO.File]::ReadAllText($target)
if ([regex]::Matches($verify, $pattern).Count -ne 0) { throw 'Verification failed' }
Write-Host "Patched OK ($Mode). Start Teams normally."