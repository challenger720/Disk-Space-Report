# ==============================================================================
# Script Name: cleanprofile.ps1
# Description: Removes stale user profiles, terminates locking processes, 
#              and exits with specific status codes for the controller script.
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

Write-Host "Starting Profile Cleanup..." -ForegroundColor Cyan

# 1. Kill background lock holders
$processesToKill = @('SearchIndexer', 'OneDrive', 'Teams', 'msedge', 'chrome', 'SIHost', 'RuntimeBroker')
foreach ($proc in $processesToKill) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# 2. Unload registry hives
Get-ChildItem -Path "Registry::HKU" -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match 'S-1-5-21-\d+-\d+-\d+-\d+$' -and $_.Name -notlike '*_Classes'
} | ForEach-Object {
    $sid = $_.PSChildName
    [gc]::Collect()
    reg.exe unload "HKU\$sid" 2>$null
}

# 3. Detect active sessions
$currentUsers = (quser 2>$null) | ForEach-Object {
    if ($_ -match '^\s*([a-zA-Z0-9\._-]+)') { $Matches[1].Trim() }
}
$protectedList = $ExcludedUsers + $currentUsers

# 4. Target profiles
$profiles = Get-CimInstance Win32_UserProfile | Where-Object {
    -not $_.Special -and
    $_.LocalPath -like 'C:\Users\*' -and
    !($protectedList -contains ($_.LocalPath -split '\\')[-1]) -and
    $_.LastUseTime -lt (Get-Date).AddDays(-$DaysInactive)
}

if (-not $profiles) {
    Write-Host "No eligible profiles found." -ForegroundColor Green
    schtasks /delete /tn "PendingProfileCleanup" /f 2>$null
    exit 0
}

# 5. Attempt profile removal
$failedCount = 0
foreach ($profile in $profiles) {
    $userName = ($profile.LocalPath -split '\\')[-1]
    try {
        Write-Host "Removing profile: $userName..." -NoNewline
        Remove-CimInstance -InputObject $profile -ErrorAction Stop
        Write-Host " [SUCCESS]" -ForegroundColor Green
    } catch {
        Write-Host " [FAILED/LOCKED]" -ForegroundColor Red
        $failedCount++
    }
}

# 6. Set Exit Codes & Smart Reboot
if ($failedCount -gt 0) {
    # Register task for startup
    schtasks /create /tn PendingProfileCleanup /tr "powershell.exe -ExecutionPolicy Bypass -File C:\Temp\cleanprofile.ps1" /sc onstart /ru "NT AUTHORITY\SYSTEM" /f 2>$null

    if ($currentUsers.Count -eq 0) {
        Write-Host "Machine is idle. Triggering immediate reboot..." -ForegroundColor Yellow
        shutdown.exe /r /t 5 /f /c "Rebooting to complete profile cleanup."
        exit 101  # Code 101 = Reboot Triggered
    } else {
        Write-Host "User logged in. Skipping force reboot." -ForegroundColor Yellow
        exit 102  # Code 102 = Scheduled for Next Manual Restart
    }
} else {
    Write-Host "All profiles deleted successfully." -ForegroundColor Green
    schtasks /delete /tn "PendingProfileCleanup" /f 2>$null
    exit 0      # Code 0 = Complete Success
}
