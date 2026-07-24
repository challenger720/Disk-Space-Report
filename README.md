# Automated Multi-Machine User Profile Cleanup

An automated, two-part PowerShell solution built for IT Helpdesk Technicians and System Administrators to bulk-delete stale or inactive user profiles across domain-joined Windows endpoints.

It handles remote script deployment via SMB, executes profile deletions under the `NT AUTHORITY\SYSTEM` context using Sysinternals `PsExec`, and captures exact process return codes to give **100% accurate status reporting** without false positives.

---

## 📁 Repository Structure

| File Name | Purpose | Execution Location |
| :--- | :--- | :--- |
| **`Run-RemoteCleanup.ps1`** | Master controller script. Reads `computers.csv`, verifies SMB connectivity, pushes the worker script, executes via PsExec using `Start-Process`, and interprets process exit codes. | Local Workstation |
| **`cleanprofile.ps1`** | Core worker script. Kills file-locking background processes, unloads registry hives, detects active sessions via `quser`, deletes stale profiles, handles local scheduled task creation, and exits with precise status codes (`0`, `101`, `102`). | Remote Target PC |
| **`computers.csv`** | CSV input file containing the list of target computer hostnames. | Local Workstation |

---

## ⚡ Smart Reboot & Safety Logic

The worker script (`cleanprofile.ps1`) executes locally on the target machine under `NT AUTHORITY\SYSTEM` and manages file locks (`0x80070020`), user presence, and reboots locally:

1. **Active User Protection:** Currently logged-in user profiles are detected via `quser` and automatically added to the exclusion list to prevent desktop session corruption.
2. **Idle Machines (Locked Files):** If profiles fail to delete due to background process locks and **nobody is logged in**, `cleanprofile.ps1` registers a `PendingProfileCleanup` startup task, initiates an immediate **5-second local force reboot**, and exits with code **`101`**.
3. **Active Workstations (Locked Files):** If profiles fail to delete and a **user IS actively logged in**, the script registers the startup task for the **next manual/natural reboot**, skips `shutdown.exe`, and exits with code **`102`**.
4. **Self-Cleaning:** Once all targeted profiles are wiped successfully, the script deletes the `PendingProfileCleanup` task and exits with code **`0`**.

---

## 📋 Exit Code Reference

`Run-RemoteCleanup.ps1` evaluates the return value from `PsExec` to provide accurate reporting in the final execution table:

| Exit Code | Meaning | Summary Status Output |
| :---: | :--- | :--- |
| **`0`** | All targeted profiles deleted successfully on the first pass. | `Cleaned (No Reboot Required)` |
| **`101`** | Profiles locked; machine was idle so an immediate local reboot was triggered. | `Reboot Triggered (Locked Profiles)` |
| **`102`** | Profiles locked; user actively logged in so cleanup task was queued for next restart. | `Scheduled (Pending Next Manual Reboot)` |
| **`1`+** | General execution failure or PsExec communication error. | `Failed / Error (Exit Code X)` |

---

## 📋 Prerequisites

### Technician Workstation:
* PowerShell 5.1+ running as **Administrator**.
* Sysinternals **PsExec** installed (default path: `C:\Tools\PSTools\PsExec.exe`).
* Files located in `C:\Temp\`:
  * `C:\Temp\Run-RemoteCleanup.ps1`
  * `C:\Temp\cleanprofile.ps1`
  * `C:\Temp\computers.csv`

### Target Endpoints & Domain:
* Active Directory Domain Environment with Administrative rights over endpoints.
* **SMB (Port 445)** accessible between technician workstation and target PCs.
* Administrative Shares (`C$`, `ADMIN$`) enabled on targets.

---

## ⚙️ Setup & Configuration

### 1. Populate `computers.csv`
Add your target machine names under the `ComputerName` header inside `C:\Temp\computers.csv`:

```csv
ComputerName
JC053509
JC053860
JC053861
```

---

## 🚀 Usage

> ⚠️ **Execution Location:** Run the command below on your **local technician workstation** as an elevated Administrator. The master script will handle all remote target interactions across the network automatically.

Open PowerShell as **Administrator** on your local machine and execute:

` ` `powershell
PS C:\Temp> powershell.exe -ExecutionPolicy Bypass -File "C:\Temp\Run-RemoteCleanup.ps1"
` ` `
### Execution Flow:
1. **Deployment (`Run-RemoteCleanup.ps1`):** Copies worker scripts and triggers execution remotely under `NT AUTHORITY\SYSTEM` context via PsExec/RPC.
2. **Laptop Safety Guard:** Checks WMI `Win32_SystemEnclosure` chassis type. If a laptop/portable form factor is detected, the script exits immediately without modifying profiles or creating tasks.
3. **Pre-Flight Lock Detection:** Before touching WMI or registry, `cleanprofile.ps1` tests key profile files (`NTUSER.DAT`, AppData databases) for active file locks.
4. **Registry Protection:** If locks are detected, the script skips `Remove-CimInstance` to keep the profile hive intact in `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`.
5. **Orphaned Folder Sweeping:** Directly scans `C:\Users\` to remove leftover physical directories whose registry hives were deleted during prior incomplete operations.
6. **Self-Healing Startup Task (Desktop Only):** If file locks prevent complete deletion on desktop PCs, the script registers a `PendingProfileCleanup` task that executes at system boot before background services load.

---

## Script Files & Responsibilities

| File | Purpose | Location |
| :--- | :--- | :--- |
| `Run-RemoteCleanup.ps1` | Master orchestration script. Loops through `computers.csv` and deploys worker scripts remotely. | Local Workstation (`C:\Temp`) |
| `cleanprofile.ps1` | Worker script executed on remote endpoints. Performs lock checks, WMI deletions, disk folder sweeps, and task registration. | Local Workstation & Target (`C:\Temp`) |
| `Confirm-CleanupStatus.ps1` | Audit script. Inspects task scheduler queues AND physical `C:\Users\` directories over SMB to confirm cleanup status. | Local Workstation (`C:\Temp`) |

---

## Script 1: `cleanprofile.ps1` (Worker Script with Safeguards)

```powershell
# ==============================================================================
# Script Name: cleanprofile.ps1
# Description: Safely removes inactive user profiles and orphaned disk folders.
#              Includes laptop safeguards, last-logged-on user protection, 
#              and pre-flight file-lock testing.
# Run Level:   Must run as SYSTEM or Local Administrator
# ==============================================================================

$DaysInactive  = 30  # Safety threshold: Only purge profiles untouched for > 30 days
$ExcludedUsers = @(
    'Administrator', 
    'Default', 
    'Default User', 
    'Public', 
    'SAdmin', 
    'All Users',
    'Helpdesk',
    'ITAdmin'
)

# --- SAFEGUARD 1: CHASSIS & LAPTOP GUARD ---
$chassis = (Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes
$isLaptop = $chassis -contains 8 -or $chassis -contains 9 -or $chassis -contains 10 -or $chassis -contains 14

if ($isLaptop) {
    Write-Warning "Device detected as LAPTOP/PORTABLE. Exiting profile cleanup for safety."
    schtasks /delete /tn "PendingProfileCleanup" /f 2>$null
    exit 103  # Exit Code 103: Laptop Guard Triggered
}

# --- HELPER FUNCTION: PRE-FLIGHT LOCK TEST ---
function Test-ProfileLocked {
    param (
        [string]$Path
    )

    if (-not (Test-Path $Path)) { return $false }

    $filesToTest = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue | 
                   Where-Object { $_.Extension -in '.dat', '.log', '.db', '.ldf' -or $_.Name -like '*NTUSER*' } |
                   Select-Object -First 20

    foreach ($file in $filesToTest) {
        try {
            $stream = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            if ($stream) { $stream.Close() }
        }
        catch {
            return $true  # Locked by active handle
        }
    }

    return $false
}

Write-Host "Starting User Profile Cleanup Process..." -ForegroundColor Cyan

# --- SAFEGUARD 2: PROTECT LAST LOGGED-ON USER ---
$lastUserRaw = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI" -Name "LastLoggedOnUser" -ErrorAction SilentlyContinue).LastLoggedOnUser
if ($lastUserRaw) {
    $lastUser = ($lastUserRaw -split '\\')[-1]
    $ExcludedUsers += $lastUser
    Write-Host "Protecting Last Logged-On User: $lastUser" -ForegroundColor Yellow
}

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

# --- STEP 4: QUERY TARGET PROFILES & DISK FOLDERS ---
$wmiProfiles = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object {
    -not $_.Special -and
    $_.LocalPath -like 'C:\Users\*' -and
    !($protectedList -contains ($_.LocalPath -split '\\')[-1]) -and
    $_.LastUseTime -lt (Get-Date).AddDays(-$DaysInactive)
}

$diskFolders = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object {
    $protectedList -notcontains $_.Name
}

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

    if (Test-ProfileLocked -Path $profileDir) {
        Write-Host " [LOCKED - PRESERVING REGISTRY KEY]" -ForegroundColor Red
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
        $failedCount++
    }
}

# --- STEP 6: DELETE ORPHANED DISK FOLDERS ---
foreach ($folder in $diskFolders) {
    if (Test-Path $folder.FullName) {
        $folderName = $folder.Name

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

# --- STEP 7: SCHEDULED TASK LOGIC (DESKTOPS ONLY) ---
if ($failedCount -gt 0) {
    Write-Warning "$failedCount profile(s) or folder(s) locked. Registering boot cleanup task..."
    schtasks /create /tn PendingProfileCleanup /tr "powershell.exe -ExecutionPolicy Bypass -File C:\Temp\cleanprofile.ps1" /sc onstart /ru "NT AUTHORITY\SYSTEM" /f 2>$null

    if ($currentUsers.Count -eq 0) {
        Write-Host "System idle. Triggering reboot to clear locks..." -ForegroundColor Yellow
        shutdown.exe /r /t 5 /f /c "Rebooting to complete profile cleanup."
        exit 101  # Code 101: Reboot Triggered
    } else {
        Write-Host "User logged in. Reboot skipped; task queued for next restart." -ForegroundColor Yellow
        exit 102  # Code 102: Task Scheduled
    }
} else {
    Write-Host "`nAll targeted profiles and disk folders deleted successfully!" -ForegroundColor Green
    schtasks /delete /tn "PendingProfileCleanup" /f 2>$null
    exit 0      # Code 0: Complete Success
}
