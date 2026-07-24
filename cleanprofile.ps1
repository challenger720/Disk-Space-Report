# ==============================================================================
# Script Name: cleanprofile.ps1
# Description: Deletes inactive profiles. Handles registry unloading, file-locking 
#              process termination, scheduled task creation, and direct local reboots.
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
$currentUsers = (quser 2>$null) | ForEach-Object {
    if ($_ -match '^\s*([a-zA-Z0-9\._-]+)') { $Matches[1].Trim() }
}
$protectedList = $ExcludedUsers + $currentUsers

if ($currentUsers.Count -gt 0) {
    Write-Host "Active user session detected: $($currentUsers -join ', ')" -ForegroundColor Yellow
} else {
    Write-Host "No active user sessions detected." -ForegroundColor Green
}

# --- STEP 4: QUERY TARGET PROFILES ---
$profiles = Get-CimInstance Win32_UserProfile | Where-Object {
    -not $_.Special -and
    $_.LocalPath -like 'C:\Users\*' -and
    !($protectedList -contains ($_.LocalPath -split '\\')[-1]) -and
    $_.LastUseTime -lt (Get-Date).AddDays(-$DaysInactive)
}

if (-not $profiles) {
    Write-Host "No eligible profiles found for removal." -ForegroundColor Green
    # Clean up scheduled task if it exists from a previous run
    schtasks /delete /tn "PendingProfileCleanup" /f 2>$null
    exit 0
}

Write-Host "Found $($profiles.Count) profile(s) targeted for removal.`n" -ForegroundColor Yellow

# --- STEP 5: ATTEMPT DELETION & TRACK FAILURES ---
$failedCount = 0

foreach ($profile in $profiles) {
    $userName = ($profile.LocalPath -split '\\')[-1]
    
    try {
        Write-Host "Removing profile: $userName ($($profile.LocalPath))..." -NoNewline
        Remove-CimInstance -InputObject $profile -ErrorAction Stop
        Write-Host " [SUCCESS]" -ForegroundColor Green
    }
    catch {
        Write-Host " [FAILED/LOCKED]" -ForegroundColor Red
        Write-Warning "Could not fully remove $userName. Reason: $_"
        $failedCount++
    }
}

# --- STEP 6: SMART REBOOT & SCHEDULED TASK LOGIC ---
if ($failedCount -gt 0) {
    Write-Warning "$failedCount profile(s) could not be deleted due to file locks."
    
    # Register Scheduled Task to attempt cleanup on next system startup
    Write-Host "Registering PendingProfileCleanup scheduled task..." -ForegroundColor Cyan
    schtasks /create /tn PendingProfileCleanup /tr "powershell.exe -ExecutionPolicy Bypass -File C:\Temp\cleanprofile.ps1" /sc onstart /ru "NT AUTHORITY\SYSTEM" /f 2>$null

    if ($currentUsers.Count -eq 0) {
        Write-Host "Machine is idle (no active users). Triggering immediate reboot in 5 seconds to clear file locks..." -ForegroundColor Yellow
        shutdown.exe /r /t 5 /f /c "Rebooting to complete automated profile cleanup."
    } else {
        Write-Host "User is signed in. Reboot skipped. Task will execute on next manual system restart." -ForegroundColor Yellow
    }
} else {
    Write-Host "`nAll targeted profiles were deleted successfully!" -ForegroundColor Green
    schtasks /delete /tn "PendingProfileCleanup" /f 2>$null
}
