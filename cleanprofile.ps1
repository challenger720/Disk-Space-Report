# ==============================================================================
# Script Name: cleanprofile.ps1
# Description: Safely removes inactive user profiles and orphaned disk folders.
#              Includes pre-flight file-lock testing to preserve registry hives 
#              if profile files are currently locked by background services.
# Run Level:   Must run as SYSTEM or Local Administrator
# ==============================================================================

$DaysInactive  = 0
$ExcludedUsers = @(
    'Administrator', 
    'Default', 
    'Default User', 
    'Public', 
    'SAdmin', 
    'All Users'
)

# --- HELPER FUNCTION: PRE-FLIGHT LOCK TEST ---
# Tests key profile files for active file locks before touching the registry or WMI.
function Test-ProfileLocked {
    param (
        [string]$Path
    )

    if (-not (Test-Path $Path)) { return $false }

    # Query key files in the profile that background services frequently lock
    $filesToTest = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue | 
                   Where-Object { $_.Extension -in '.dat', '.log', '.db', '.ldf' -or $_.Name -like '*NTUSER*' } |
                   Select-Object -First 20

    foreach ($file in $filesToTest) {
        try {
            # Attempt to open the file with exclusive access
            $stream = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            if ($stream) { $stream.Close() }
        }
        catch {
            # Sharing violation / locked by a process
            return $true
        }
    }

    return $false # No active file locks detected
}


Write-Host "Starting User Profile Cleanup Process..." -ForegroundColor Cyan

# --- STEP 1: FORCE KILL LOCKING PROCESSES ---
$processesToKill = @('SearchIndexer', 'OneDrive', 'Teams', 'msedge', 'chrome', 'SIHost', 'RuntimeBroker')
foreach ($proc in $processesToKill) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# --- STEP 2: FORCE UNLOAD HKU REGISTRY HIVES ---
Get-ChildItem -Path "Registry::HKU" -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match 'S-1-5-21-\d+-\d+-\d+-\d+$' -and $_.Name -notlike '*_Classes'
} | ForEach-Object {
    $sid = $_.PSChildName
    [gc]::Collect()
    reg.exe unload "HKU\$sid" 2>$null
}

# --- STEP 3: IDENTIFY ACTIVE LOGGED-IN USERS ---
$currentUsers = @()
$quserOutput  = quser 2>$null
if ($quserOutput) {
    $currentUsers = $quserOutput | ForEach-Object {
        if ($_ -match '^\s*>?\s*([a-zA-Z0-9\._-]+)') { $Matches[1].Trim() }
    }
}
$protectedList = $ExcludedUsers + $currentUsers

if ($currentUsers.Count -gt 0) {
    Write-Host "Active user session detected: $($currentUsers -join ', ')" -ForegroundColor Yellow
} else {
    Write-Host "No active user sessions detected." -ForegroundColor Green
}

# --- STEP 4: QUERY TARGET PROFILES & DISK FOLDERS ---
# Query registered profiles in WMI
$wmiProfiles = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object {
    -not $_.Special -and
    $_.LocalPath -like 'C:\Users\*' -and
    !($protectedList -contains ($_.LocalPath -split '\\')[-1]) -and
    $_.LastUseTime -lt (Get-Date).AddDays(-$DaysInactive)
}

# Query physical folders in C:\Users (Catches orphaned folders if WMI key was deleted previously)
$diskFolders = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object {
    $protectedList -notcontains $_.Name
}

# Exit early if no profiles exist in WMI and no leftover folders exist on disk
if ((-not $wmiProfiles) -and (-not $diskFolders)) {
    Write-Host "No eligible profiles or leftover folders found for removal." -ForegroundColor Green
    schtasks /delete /tn "PendingProfileCleanup" /f 2>$null
    exit 0
}

$failedCount = 0

# --- STEP 5: DELETE REGISTERED WMI PROFILES (WITH LOCK PRE-CHECK) ---
foreach ($profile in $wmiProfiles) {
    $userName   = ($profile.LocalPath -split '\\')[-1]
    $profileDir = $profile.LocalPath

    Write-Host "Checking file locks on WMI profile: $userName..." -NoNewline

    # Pre-flight check: If files are locked, SKIP Remove-CimInstance to preserve the registry key
    if (Test-ProfileLocked -Path $profileDir) {
        Write-Host " [LOCKED - PRESERVING REGISTRY KEY]" -ForegroundColor Red
        Write-Warning "File locks detected in $profileDir. Skipping WMI deletion until reboot."
        $failedCount++
        continue
    }

    try {
        Write-Host " Removing profile..." -NoNewline
        Remove-CimInstance -InputObject $profile -ErrorAction Stop
        Write-Host " [SUCCESS]" -ForegroundColor Green
    }
    catch {
        Write-Host " [FAILED]" -ForegroundColor Red
        Write-Warning "Could not remove $userName. Reason: $_"
        $failedCount++
    }
}

# --- STEP 6: DELETE ORPHANED DISK FOLDERS ---
foreach ($folder in $diskFolders) {
    if (Test-Path $folder.FullName) {
        $folderName = $folder.Name

        # Skip if this folder was already handled during Step 5
        $alreadyProcessed = $wmiProfiles | Where-Object { ($_.LocalPath -split '\\')[-1] -eq $folderName }
        if ($alreadyProcessed) { continue }

        Write-Host "Checking orphaned disk folder: $folderName..." -NoNewline

        if (Test-ProfileLocked -Path $folder.FullName) {
            Write-Host " [LOCKED]" -ForegroundColor Red
            $failedCount++
            continue
        }

        try {
            Write-Host " Removing folder from disk..." -NoNewline
            Remove-Item -Path $folder.FullName -Recurse -Force -ErrorAction Stop
            Write-Host " [SUCCESS]" -ForegroundColor Green
        }
        catch {
            Write-Host " [FAILED/LOCKED]" -ForegroundColor Red
            $failedCount++
        }
    }
}

# --- STEP 7: SMART REBOOT & SCHEDULED TASK LOGIC ---
if ($failedCount -gt 0) {
    Write-Warning "$failedCount profile(s) or folder(s) could not be deleted due to active file locks."
    
    # Register Scheduled Task to attempt cleanup on next system startup
    Write-Host "Registering PendingProfileCleanup scheduled task..." -ForegroundColor Cyan
    schtasks /create /tn PendingProfileCleanup /tr "powershell.exe -ExecutionPolicy Bypass -File C:\Temp\cleanprofile.ps1" /sc onstart /ru "NT AUTHORITY\SYSTEM" /f 2>$null

    if ($currentUsers.Count -eq 0) {
        Write-Host "Machine is idle. Triggering immediate reboot in 5 seconds to clear file locks..." -ForegroundColor Yellow
        shutdown.exe /r /t 5 /f /c "Rebooting to complete automated profile cleanup."
        exit 101  # Exit Code 101: Reboot Triggered
    } else {
        Write-Host "User is signed in. Reboot skipped. Task queued for next manual restart." -ForegroundColor Yellow
        exit 102  # Exit Code 102: Task Scheduled
    }
} else {
    Write-Host "`nAll targeted profiles and disk folders were deleted successfully!" -ForegroundColor Green
    schtasks /delete /tn "PendingProfileCleanup" /f 2>$null
    exit 0      # Exit Code 0: Complete Success
}
