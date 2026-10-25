<#
.SYNOPSIS
  Copy user data (bookmarks, passwords, cookies, extensions, settings, tabs)
  from one Firefox profile folder into another.

.DESCRIPTION
  Lists every profile folder under %APPDATA%\Mozilla\Firefox\Profiles - legacy
  profiles from profiles.ini and ones created by the new profile switcher -
  lets you pick a source and a destination, shows exactly what will be copied
  and overwritten, and asks for confirmation.

  Nothing in the destination is deleted: anything replaced is moved into
  %APPDATA%\Mozilla\Firefox\profile-copy-backups\<folder>-<timestamp> first.

  Profile-switcher settings in the destination's prefs.js (toolkit.profiles.*,
  browser.profiles.*) are kept, so the destination stays in its profile group.

  Firefox must be fully closed while this runs.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Copy-FirefoxProfile.ps1
#>
[CmdletBinding()]
param(
    [string]$ProfilesRoot = (Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles')
)

$ErrorActionPreference = 'Stop'

# Files and folders copied from source to destination. Edit to taste.
$Items = @(
    'places.sqlite'               # bookmarks + history
    'favicons.sqlite'
    'logins.json'                 # saved passwords (useless without key4.db)
    'key4.db'
    'cert9.db'                    # certificate exceptions
    'cookies.sqlite'              # stay signed in to sites
    'formhistory.sqlite'
    'permissions.sqlite'          # per-site permissions
    'content-prefs.sqlite'        # per-site zoom, etc.
    'handlers.json'               # download actions per file type
    'sessionstore.jsonlz4'        # open tabs
    'sessionstore-backups'
    'prefs.js'                    # settings
    'extensions'
    'extensions.json'
    'extension-preferences.json'
    'extension-settings.json'
    'storage'                     # extension + site storage
)

# Removed from the destination (moved to the backup) so Firefox rebuilds them.
$StaleFiles = @('addonStartup.json.lz4')

# prefs.js lines that belong to the destination and must survive the copy.
# toolkit.profiles.storeID names the "Profile Groups\<storeID>.sqlite" database
# the profile belongs to; taking the source's value would move the destination
# into the source's group. browser.profiles.enabled/created switch the profile
# menu on. See README for the Firefox source references.
$KeepPrefsPattern = '^user_pref\("(toolkit|browser)\.profiles\.'

function Get-Profiles {
    $ini = @{}
    $iniPath = Join-Path (Split-Path $ProfilesRoot) 'profiles.ini'
    if (Test-Path $iniPath) {
        $name = $null
        foreach ($line in Get-Content $iniPath) {
            if ($line -match '^Name=(.+)$') { $name = $Matches[1] }
            elseif ($line -match '^Path=(?:Profiles[/\\])?(.+)$' -and $name) {
                $ini[$Matches[1]] = $name
                $name = $null
            }
            elseif ($line -match '^\[') { $name = $null }
        }
    }

    Get-ChildItem -LiteralPath $ProfilesRoot -Directory |
        Where-Object { $_.Name -notmatch 'MozillaBackgroundTask' -and
                       (Test-Path (Join-Path $_.FullName 'prefs.js')) } |
        ForEach-Object {
            $legacy = $ini.ContainsKey($_.Name)
            $display = if ($legacy) { $ini[$_.Name] } else { $_.Name -replace '^[^.]+\.', '' }
            [pscustomobject]@{
                Name     = $display
                Kind     = $(if ($legacy) { 'legacy' } else { 'new' })
                Folder   = $_.Name
                Path     = $_.FullName
                LastUsed = (Get-Item (Join-Path $_.FullName 'prefs.js')).LastWriteTime
            }
        } |
        Sort-Object LastUsed -Descending
}

function Select-Profile($Profiles, [string]$Prompt, $Exclude) {
    while ($true) {
        Write-Host ''
        Write-Host $Prompt -ForegroundColor Cyan
        for ($i = 0; $i -lt $Profiles.Count; $i++) {
            $p = $Profiles[$i]
            $mark = if ($Exclude -and $p.Path -eq $Exclude.Path) { '  <- source' } else { '' }
            Write-Host ('{0,3}) {1,-24} {2,-7} last used {3:yyyy-MM-dd HH:mm}  {4}{5}' -f
                ($i + 1), $p.Name, $p.Kind, $p.LastUsed, $p.Folder, $mark)
        }
        $answer = Read-Host 'Number (Q to quit)'
        if ($answer -match '^\s*q\s*$') { exit 1 }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Profiles.Count) {
            $choice = $Profiles[$n - 1]
            if ($Exclude -and $choice.Path -eq $Exclude.Path) {
                Write-Host 'Destination must be different from the source.' -ForegroundColor Yellow
                continue
            }
            return $choice
        }
        Write-Host 'Invalid choice.' -ForegroundColor Yellow
    }
}

function Wait-FirefoxClosed {
    while (Get-Process firefox -ErrorAction SilentlyContinue) {
        Write-Host ''
        Write-Host 'Firefox is running. Close every Firefox window first.' -ForegroundColor Yellow
        $answer = Read-Host 'Press Enter to check again (Q to quit)'
        if ($answer -match '^\s*q\s*$') { exit 1 }
    }
}

# SQLite databases carry -wal/-shm side files that must travel with them.
function Get-SideFiles([string]$Item) {
    if ($Item -match '\.(sqlite|db)$') { @("$Item-wal", "$Item-shm") } else { @() }
}

# --- main -------------------------------------------------------------------

if (-not (Test-Path $ProfilesRoot)) {
    Write-Host "Profiles folder not found: $ProfilesRoot" -ForegroundColor Red
    exit 1
}

$profiles = @(Get-Profiles)
if ($profiles.Count -lt 2) {
    Write-Host "Need at least two profiles in $ProfilesRoot; found $($profiles.Count)." -ForegroundColor Red
    exit 1
}

$src = Select-Profile $profiles 'Copy FROM which profile?'
$dst = Select-Profile $profiles 'Copy INTO which profile?' $src

# Build the plan.
$plan = foreach ($item in $Items) {
    $srcPath = Join-Path $src.Path $item
    $dstPath = Join-Path $dst.Path $item
    $action = if (-not (Test-Path -LiteralPath $srcPath)) { 'skip (not in source)' }
              elseif (Test-Path -LiteralPath $dstPath) { 'replace' }
              else { 'add' }
    [pscustomobject]@{ Item = $item; Action = $action }
}

Write-Host ''
Write-Host '================ PLAN ================' -ForegroundColor Cyan
Write-Host ("FROM: {0}  ({1})" -f $src.Name, $src.Path)
Write-Host ("INTO: {0}  ({1})" -f $dst.Name, $dst.Path)
Write-Host ''
foreach ($row in $plan) {
    $color = switch -Wildcard ($row.Action) { 'replace' { 'Yellow' } 'add' { 'Green' } default { 'DarkGray' } }
    Write-Host ('  {0,-22} {1}' -f $row.Action, $row.Item) -ForegroundColor $color
}
$backupDir = Join-Path (Split-Path $ProfilesRoot) ('profile-copy-backups\{0}-{1:yyyyMMdd-HHmmss}' -f $dst.Folder, (Get-Date))
Write-Host ''
Write-Host "Replaced items will be moved to: $backupDir"
Write-Host ''

$confirm = Read-Host "Type YES to copy '$($src.Name)' into '$($dst.Name)'"
if ($confirm -cne 'YES') {
    Write-Host 'Cancelled. Nothing was changed.'
    exit 1
}

Wait-FirefoxClosed

New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

# Move everything we are about to replace (plus stale caches) into the backup.
$toBackUp = @($StaleFiles)
foreach ($row in $plan | Where-Object Action -ne 'skip (not in source)') {
    $toBackUp += $row.Item
    $toBackUp += Get-SideFiles $row.Item
}
foreach ($name in $toBackUp) {
    $path = Join-Path $dst.Path $name
    if (Test-Path -LiteralPath $path) {
        Move-Item -LiteralPath $path -Destination (Join-Path $backupDir $name)
    }
}

# Copy from source.
foreach ($row in $plan | Where-Object Action -ne 'skip (not in source)') {
    foreach ($name in @($row.Item) + (Get-SideFiles $row.Item)) {
        $from = Join-Path $src.Path $name
        if (Test-Path -LiteralPath $from) {
            Copy-Item -LiteralPath $from -Destination (Join-Path $dst.Path $name) -Recurse
            Write-Host "  copied $name"
        }
    }
}

# Put the destination's own profile-switcher prefs back into the new prefs.js.
$newPrefs = Join-Path $dst.Path 'prefs.js'
$oldPrefs = Join-Path $backupDir 'prefs.js'
if ((Test-Path $newPrefs) -and (Test-Path $oldPrefs)) {
    $keep = @(Get-Content $oldPrefs | Where-Object { $_ -match $KeepPrefsPattern })
    $lines = @(Get-Content $newPrefs | Where-Object { $_ -notmatch $KeepPrefsPattern }) + $keep
    [IO.File]::WriteAllLines($newPrefs, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
    Write-Host "  kept $($keep.Count) profile-switcher pref(s) from the destination"
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host "To undo: close Firefox, delete the copied items from $($dst.Path),"
Write-Host "and move everything in $backupDir back into it."
