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
