# ==============================================================================
# Script Name: Confirm-CleanupStatus.ps1
# Description: Checks scheduled tasks AND physical profile folders over SMB
# Run Level:   Run locally on your technician workstation
# ==============================================================================

param (
    [string]$CsvPath = "C:\Temp\computers.csv"
)

$excludedFolders = @('Administrator', 'Default', 'Default User', 'Public', 'SAdmin', 'All Users')
$computerList = Import-Csv -Path $CsvPath
$results = @()

Write-Host "`nAuditing cleanup status across $($computerList.Count) computer(s)...`n" -ForegroundColor Cyan

foreach ($row in $computerList) {
    $target = $row.ComputerName.Trim()
    if ([string]::IsNullOrWhitespace($target)) { continue }

    if (-not (Test-Connection -ComputerName $target -Count 1 -Quiet)) {
        $results += [PSCustomObject]@{ ComputerName = $target; AuditStatus = "Offline"; Details = "Machine unreachable" }
        continue
    }

    $taskOutput = schtasks /query /s $target /tn "PendingProfileCleanup" /fo CSV 2>$null | ConvertFrom-Csv
    
    $quserRaw = quser /server:$target 2>$null
    $activeUsers = @()
    if ($quserRaw) {
        $activeUsers = $quserRaw | ForEach-Object {
            if ($_ -match '^\s*>?\s*([a-zA-Z0-9\._-]+)') { $Matches[1].Trim() }
        }
    }

    $diskFolders = Get-ChildItem -Path "\\$target\C$\Users" -Directory -ErrorAction SilentlyContinue | 
                    Where-Object { ($excludedFolders + $activeUsers) -notcontains $_.Name } | 
                    Select-Object -ExpandProperty Name

    if ($taskOutput) {
        $status = $taskOutput.Status
        $results += [PSCustomObject]@{
            ComputerName = $target
            AuditStatus  = "Pending Reboot"
            Details      = "Task is $status. Remaining uncleaned profiles: ($($diskFolders -join ', '))"
        }
    } elseif ($diskFolders.Count -gt 0) {
        $results += [PSCustomObject]@{
            ComputerName = $target
            AuditStatus  = "Needs Cleanup"
            Details      = "Stale/orphaned folders still on disk: ($($diskFolders -join ', '))"
        }
    } else {
        $results += [PSCustomObject]@{
            ComputerName = $target
            AuditStatus  = "FULLY CLEANED"
            Details      = "No stale profile folders remain on disk."
        }
    }
}

$results | Format-Table -AutoSize
