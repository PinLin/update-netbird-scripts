#Requires -Version 5.1
param([string]$AdminUser)
$ErrorActionPreference = 'Stop'

# ---------- Constants ----------
$NetbirdRepo         = 'netbirdio/netbird'
$NetbirdDefaultExe   = 'C:\Program Files\Netbird\netbird.exe'
$ElevationLog        = Join-Path $env:ProgramData 'netbird-update.log'
$ElevationTimeoutMin = 5

# ---------- Privilege / session helpers ----------
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-SshSession {
    [bool]($env:SSH_CLIENT -or $env:SSH_CONNECTION)
}

function Get-AdminGroupMembers {
    # Use well-known SID so it works on any Windows locale.
    $group = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
    Get-LocalGroupMember -Group $group.Name -ErrorAction Stop
}

function Test-CurrentUserInAdmins {
    try {
        $current = "$env:USERDOMAIN\$env:USERNAME"
        return [bool]((Get-AdminGroupMembers) | Where-Object { $_.Name -ieq $current })
    } catch {
        return $false
    }
}

function Find-AdminUser {
    $members = Get-AdminGroupMembers
    $current = "$env:USERDOMAIN\$env:USERNAME"

    $candidates = @(foreach ($m in $members) {
        if ($m.ObjectClass -ne 'User') { continue }
        if ($m.Name -ieq $current)     { continue }   # cannot runas to self
        if ($m.PrincipalSource -eq 'Local') {
            $short = ($m.Name -split '\\')[-1]
            $u = Get-LocalUser -Name $short -ErrorAction SilentlyContinue
            if (-not ($u -and $u.Enabled)) { continue }
        }
        # AD / AzureAD principals: assume enabled (no module dependency).
        $m.Name
    })

    if ($candidates.Count -eq 0) {
        if ($members | Where-Object { $_.Name -ieq $current }) {
            throw @"
Current user $current is already a member of Administrators, but this session is not elevated.
runas cannot elevate self. Options:
  - Run from an already-elevated PowerShell (Run as administrator)
  - Run via SSH (OpenSSH gives Administrators members a full token by default)
  - Pre-register a scheduled task with highest privileges and trigger it from here
"@
        }
        throw 'No usable admin account found. Pass -AdminUser <DOMAIN\user> explicitly.'
    }
    if ($candidates.Count -eq 1) { return $candidates[0] }

    Write-Host 'Multiple admin accounts available:'
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f $i, $candidates[$i])
    }
    $idx = Read-Host 'Pick'
    return $candidates[[int]$idx]
}

# ---------- Netbird helpers ----------
function Get-NetbirdArch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'amd64' }
        'ARM64' { 'arm64' }
        'x86'   { '386'   }
        default { throw "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
    }
}

function Get-NetbirdExe {
    $cmd = Get-Command netbird -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if (Test-Path $NetbirdDefaultExe) { return $NetbirdDefaultExe }
    return $null
}

function Get-NetbirdCurrentVersion {
    $exe = Get-NetbirdExe
    if (-not $exe) { return $null }
    return ((& $exe version 2>$null) | Out-String).Trim()
}

# ---------- Elevation (only when not already admin) ----------
if (-not (Test-Admin)) {
    $self   = $PSCommandPath
    $log    = $ElevationLog
    $marker = "$log.done"
    Remove-Item $log, $marker -ErrorAction SilentlyContinue

    # Pack the elevated-side logic as a base64 -EncodedCommand payload.
    # Avoids a temp wrapper file and its cleanup/leak edge cases.
    $payload = @"
`$ErrorActionPreference = 'Stop'
try {
    & '$self' *> '$log'
} finally {
    'DONE' | Out-File -FilePath '$marker' -Encoding ascii
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))

    # Use the same PowerShell exe that launched this script (powershell.exe vs pwsh.exe).
    $psExe = (Get-Process -Id $PID).Path

    # Strategy:
    #   - admin in Administrators + not SSH + no -AdminUser -> UAC consent popup
    #   - otherwise -> runas to a different admin account (terminal password prompt)
    $useUac = (-not $AdminUser) -and (-not (Test-SshSession)) -and (Test-CurrentUserInAdmins)

    if ($useUac) {
        Write-Host 'You are an admin but this session is not elevated. Triggering UAC consent...'
        try {
            Start-Process -FilePath $psExe -Verb RunAs -WindowStyle Hidden `
                          -ArgumentList "-NoProfile -EncodedCommand $encoded"
        } catch {
            throw "UAC consent was denied or failed: $_"
        }
    } else {
        if (-not $AdminUser) { $AdminUser = Find-AdminUser }
        Write-Host "Elevating via $AdminUser. runas will prompt for that account's password..."
        & runas.exe "/user:$AdminUser" "`"$psExe`" -NoProfile -EncodedCommand $encoded"
    }

    $deadline = (Get-Date).AddMinutes($ElevationTimeoutMin)
    while (-not (Test-Path $marker) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
    }
    if (Test-Path $log) { Get-Content $log }
    Remove-Item $log, $marker -ErrorAction SilentlyContinue
    return
}

# ---------- Main: running elevated, update Netbird ----------
$arch      = Get-NetbirdArch
$latestTag = (Invoke-RestMethod "https://api.github.com/repos/$NetbirdRepo/releases/latest").tag_name
$ver       = $latestTag.TrimStart('v')

$current        = Get-NetbirdCurrentVersion
$currentDisplay = if ($current) { $current } else { 'not installed' }

Write-Host "current = $currentDisplay"
Write-Host "latest  = $ver"
if ($current -eq $ver) { Write-Host 'up to date'; return }

$url  = "https://github.com/$NetbirdRepo/releases/download/$latestTag/netbird_installer_${ver}_windows_${arch}.exe"
$dest = Join-Path $env:TEMP "netbird_installer_${ver}.exe"

Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
Start-Process -FilePath $dest -ArgumentList '/S' -Wait
Remove-Item $dest -Force

Write-Host "installed $(Get-NetbirdCurrentVersion)"
