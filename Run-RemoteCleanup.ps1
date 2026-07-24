# ==============================================================================
# Script Name: Run-RemoteCleanup.ps1
# Description: Pushes cleanprofile.ps1 to remote machines and accurately reports
#              status based on worker script exit codes.
# Run Level:   Run locally on YOUR technician workstation as Administrator
# ==============================================================================

param (
    [string]$CsvPath     = "C:\Temp\computers.csv",
    [string]$LocalScript = "C:\Temp\cleanprofile.ps1",
    [string]$PsExecPath  = "C:\Tools\PSTools\PsExec.exe"
)

# Pre-flight checks
if (-not (Test-Path $CsvPath))     { Write-Error "CRITICAL: Could not find '$CsvPath'!"; exit 1 }
if (-not (Test-Path $LocalScript)) { Write-Error "CRITICAL: Could not find '$LocalScript'!"; exit 1 }
if (-not (Test-Path $PsExecPath))  { Write-Error "CRITICAL: Could not find '$PsExecPath'!"; exit 1 }

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

    # Ping check
    if (-not (Test-Connection -ComputerName $target -Count 1 -Quiet)) {
        Write-Host "OFFLINE: $target is not reachable." -ForegroundColor Red
        $results += [PSCustomObject]@{ ComputerName = $target; Status = "Offline / Unreachable" }
        continue
    }

    try {
        # 1. Ensure C:\Temp exists
        & $PsExecPath \\$target -s cmd.exe /c "if not exist C:\Temp mkdir C:\Temp" | Out-Null

        # 2. Copy worker script
        $destinationPath = "\\$target\C$\Temp\cleanprofile.ps1"
        Copy-Item -Path $LocalScript -Destination $destinationPath -Force -ErrorAction Stop

        # 3. Execute and capture process exit code
        Write-Host "Executing cleanup script on $target..." -ForegroundColor Cyan
        
        $p = Start-Process -FilePath $PsExecPath -ArgumentList "\\$target -s powershell.exe -ExecutionPolicy Bypass -File C:\Temp\cleanprofile.ps1" -Wait -NoNewWindow -PassThru
        $exitCode = $p.ExitCode

        # 4. Interpret true exit code from cleanprofile.ps1
        switch ($exitCode) {
            0 {
                Write-Host "SUCCESS: All target profiles removed on $target!" -ForegroundColor Green
                $results += [PSCustomObject]@{ ComputerName = $target; Status = "Cleaned (No Reboot Required)" }
            }
            101 {
                Write-Host "REBOOTING: Locked profiles found, machine is idle. Reboot triggered!" -ForegroundColor Yellow
                $results += [PSCustomObject]@{ ComputerName = $target; Status = "Reboot Triggered (Locked Profiles)" }
            }
            102 {
                Write-Host "SCHEDULED: Locked profiles found, user is logged in. Task queued for next manual restart." -ForegroundColor Yellow
                $results += [PSCustomObject]@{ ComputerName = $target; Status = "Scheduled (Pending Next Manual Reboot)" }
            }
            default {
                Write-Host "WARNING: Execution finished with code $exitCode." -ForegroundColor Red
                $results += [PSCustomObject]@{ ComputerName = $target; Status = "Failed / Error (Exit Code $exitCode)" }
            }
        }

    } catch {
        Write-Error "ERROR: Failed on $target - $_"
        $results += [PSCustomObject]@{ ComputerName = $target; Status = "Failed: $_" }
    }
}

# --- FINAL SUMMARY REPORT ---
Write-Host "`n====================================================" -ForegroundColor Cyan
Write-Host "               FINAL EXECUTION SUMMARY               " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
$results | Format-Table -AutoSize
