# ==============================================================================
# Script Name: cleanprofile.ps1
# Description: Standard user profile removal script. Deletes inactive user profiles
#              while protecting system accounts, active users, and specified admins.
# Run Level:   Must run as SYSTEM or Local Administrator
# ==============================================================================

# --- CONFIGURATION ---
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

# 1. Stop common background services/processes that create file locks (0x80070020)
$processesToKill = @('OneDrive', 'Teams', 'msedge', 'chrome', 'SearchIndexer')
foreach ($proc in $processesToKill) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# 2. Identify currently logged-in users via quser to avoid deleting active sessions
$currentUsers = quser 2>$null | ForEach-Object {
    if ($_ -match '^\s*([a-zA-Z0-9\._-]+)') { $Matches[1] }
}

Write-Host "Currently logged in users (Protected): $($currentUsers -join ', ')" -ForegroundColor Yellow

# 3. Query all user profiles on the system
$profiles = Get-CimInstance Win32_UserProfile | Where-Object {
    -not $_.Special -and                                                      # Ignore System profiles
    $_.LocalPath -like 'C:\Users\*' -and                                      # Target standard C:\Users folders
    !(($ExcludedUsers + $currentUsers) -contains ($_.LocalPath -split '\\')[-1]) -and # Exclude admins & active users
    $_.LastUseTime -lt (Get-Date).AddDays(-$DaysInactive)                    # Inactivity threshold
}

if (-not $profiles) {
    Write-Host "No eligible profiles found for removal." -ForegroundColor Green
    exit 0
}

Write-Host "Found $($profiles.Count) profile(s) targeted for removal.`n" -ForegroundColor Yellow

# 4. Attempt profile removal
foreach ($profile in $profiles) {
    $userName = ($profile.LocalPath -split '\\')[-1]
    
    try {
        Write-Host "Removing profile: $userName ($($profile.LocalPath))..." -NoNewline
        
        # Remove profile registry entries and disk files
        Remove-CimInstance -InputObject $profile -ErrorAction Stop
        
        Write-Host " [SUCCESS]" -ForegroundColor Green
    }
    catch {
        Write-Host " [FAILED/LOCKED]" -ForegroundColor Red
        Write-Warning "Could not fully remove $userName. Reason: $_"
    }
}

Write-Host "`nProfile cleanup pass completed." -ForegroundColor Cyan
