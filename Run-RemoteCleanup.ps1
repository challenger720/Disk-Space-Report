# ==============================================================================
# Script Name: Run-RemoteCleanup.ps1
# Location:    C:\Temp\Run-RemoteCleanup.ps1
# Run Level:   Run locally on YOUR technician workstation as Administrator
# ==============================================================================

param (
    [string]$CsvPath     = "C:\Temp\computers.csv",
    [string]$LocalScript = "C:\Temp\cleanprofile.ps1",
    [string]$PsExecPath  = "C:\Tools\PSTools\PsExec.exe"
)

# --- PRE-FLIGHT CHECKS ---
if (-not (Test-Path $CsvPath)) {
    Write-Error "CRITICAL: Could not find CSV file at '$CsvPath'!"
    exit 1
}

if (-not (Test-Path $LocalScript)) {
    Write-Error "CRITICAL: Could not find '$LocalScript' on your local workstation!"
    exit 1
}

if (-not (Test-Path $PsExecPath)) {
    Write-Error "CRITICAL: Could not find PsExec.exe at '$PsExecPath'!"
    exit 1
}

# Import target machines from CSV
$computerList = Import-Csv -Path $CsvPath

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "   BATCH PROFILE CLEANUP: $($computerList.Count) MACHINE(S) LOADED" -ForegroundColor Cyan
Write-Host "====================================================`n" -ForegroundColor Cyan

$results = @()

foreach ($row in $computerList) {
    $target = $row.ComputerName.Trim()

    if ([string]::IsNullOrWhitespace($target)) { continue }

    Write-Host "`n>>> PROCESSING TARGET: $target <<<" -ForegroundColor Yellow
    Write-Host "----------------------------------------------------" -ForegroundColor Gray

    # Check network connectivity first
    if (-not (Test-Connection -ComputerName $target -Count 1 -Quiet)) {
        Write-Host "OFFLINE: $target is not reachable on the network. Skipping..." -ForegroundColor Red
        $results += [PSCustomObject]@{ ComputerName = $target; Status = "Offline / Unreachable" }
        continue
    }

    try {
        # --- STEP 1: FORCE C:\Temp TO EXIST ON TARGET ---
        Write-Host "[1/3] Ensuring C:\Temp exists on $target..." -ForegroundColor Cyan
        & $PsExecPath \\$target -s cmd.exe /c "if not exist C:\Temp mkdir C:\Temp" | Out-Null

        # --- STEP 2: COPY CLEANPROFILE.PS1 DIRECTLY TO C:\Temp ---
        Write-Host "[2/3] Copying '$LocalScript' to \\$target\C$\Temp\..." -ForegroundColor Cyan
        
        $destinationPath = "\\$target\C$\Temp\cleanprofile.ps1"
        Copy-Item -Path $LocalScript -Destination $destinationPath -Force -ErrorAction Stop
        
        if (Test-Path $destinationPath) {
            Write-Host " -> Successfully verified cleanprofile.ps1 is sitting in C:\Temp on $target!" -ForegroundColor Green
        } else {
            throw "Failed to verify file copy to $destinationPath"
        }

        # --- STEP 3: EXECUTE CLEANPROFILE.PS1 FROM C:\Temp UNDER SYSTEM ---
        Write-Host "[3/3] Executing cleanup script on $target under SYSTEM context..." -ForegroundColor Cyan
        
        & $PsExecPath \\$target -s powershell.exe -ExecutionPolicy Bypass -File "C:\Temp\cleanprofile.ps1"

        # --- STEP 4: VERIFY REMAINING PROFILES & SCHEDULE REBOOT IF LOCKED ---
        Write-Host "[4/4] Verifying profile cleanup on $target..." -ForegroundColor Cyan
        
        $daysInactive = 0
        $excludedUsers = @('Administrator', 'Default', 'Default User', 'Public', 'SAdmin', 'All Users')

        $currentUsers = Invoke-Command -ComputerName $target -ScriptBlock {
            quser 2>$null | ForEach-Object { if ($_ -match '^\s*([a-zA-Z0-9\._-]+)') { $Matches[1] } }
        } -ErrorAction SilentlyContinue

        $remainingProfiles = Get-CimInstance -ComputerName $target Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object {
            -not $_.Special -and
            $_.LocalPath -like 'C:\Users\*' -and
            !(($excludedUsers + $currentUsers) -contains ($_.LocalPath -split '\\')[-1]) -and
            $_.LastUseTime -lt (Get-Date).AddDays(-$daysInactive)
        }

        if ($remainingProfiles.Count -gt 0) {
            Write-Warning "Found $($remainingProfiles.Count) profile(s) on $target locked by background processes."
            Write-Host "Scheduling startup task and initiating reboot on $target..." -ForegroundColor Yellow

            # Schedule startup task pointing directly to C:\Temp\cleanprofile.ps1
            $cmdTask = "schtasks /create /tn PendingProfileCleanup /tr `"powershell.exe -ExecutionPolicy Bypass -File C:\Temp\cleanprofile.ps1`" /sc onstart /ru `"NT AUTHORITY\SYSTEM`" /f"
            Invoke-Command -ComputerName $target -ScriptBlock { param($cmd) cmd.exe /c $cmd } -ArgumentList $cmdTask -ErrorAction SilentlyContinue

            # Trigger reboot
            Invoke-Command -ComputerName $target -ScriptBlock { shutdown.exe /r /t 10 /f /c "Rebooting to complete user profile cleanup." } -ErrorAction SilentlyContinue

            $results += [PSCustomObject]@{ ComputerName = $target; Status = "Scheduled Reboot (Locked Profiles)" }
        } else {
            Write-Host "SUCCESS: All target profiles removed on $target!" -ForegroundColor Green
            $results += [PSCustomObject]@{ ComputerName = $target; Status = "Cleaned (No Reboot Required)" }
        }

    } catch {
        Write-Error "ERROR: Failed to process $target - $_"
        $results += [PSCustomObject]@{ ComputerName = $target; Status = "Failed: $_" }
    }
}

# --- SUMMARY REPORT ---
Write-Host "`n====================================================" -ForegroundColor Cyan
Write-Host "               FINAL EXECUTION SUMMARY               " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
$results | Format-Table -AutoSize