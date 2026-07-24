# Automated Multi-Machine User Profile Cleanup

An automated, two-part PowerShell solution built for IT Helpdesk Technicians and System Administrators to bulk-delete stale or inactive user profiles across domain-joined Windows endpoints.

It handles remote script deployment via SMB, executes profile deletions under the `NT AUTHORITY\SYSTEM` context using Sysinternals `PsExec`, and features **smart reboot safety checks** directly on the endpoint to avoid disrupting active end-users.

---

## 📁 Repository Structure

| File Name | Purpose | Execution Location |
| :--- | :--- | :--- |
| **`Run-RemoteCleanup.ps1`** | Master controller script. Reads `computers.csv`, verifies SMB connectivity, creates target directories, pushes the worker script, and executes via PsExec. | Local Workstation |
| **`cleanprofile.ps1`** | Core worker script. Kills file-locking background processes, unloads orphaned registry hives, detects active sessions via `quser`, deletes stale profiles, and handles local scheduled task creation and smart reboots. | Remote Target PC |
| **`computers.csv`** | CSV input file containing the list of target computer hostnames. | Local Workstation |

---

## ⚡ Smart Reboot & Safety Logic

The worker script (`cleanprofile.ps1`) executes locally on the target machine under `NT AUTHORITY\SYSTEM` and dynamically manages file locks (`0x80070020`) and user sessions:

1. **Active User Protection:** Currently logged-in user profiles are detected via `quser` and automatically added to the exclusion list to prevent desktop session corruption.
2. **Idle Machines (Locked Files):** If profiles fail to delete due to background process locks and **nobody is logged in**, `cleanprofile.ps1` registers a `PendingProfileCleanup` startup task and initiates an immediate **5-second local force reboot** to finalize cleanup at boot.
3. **Active Workstations (Locked Files):** If profiles fail to delete and a **user IS actively logged in**, the script registers the startup task for the **next manual/natural reboot** and **skips `shutdown.exe`** to prevent work loss.
4. **Self-Cleaning:** Once all targeted profiles are wiped successfully, the script automatically unregisters and deletes the `PendingProfileCleanup` task.

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
