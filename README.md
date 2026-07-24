# Automated Multi-Machine User Profile Cleanup

An automated, two-part PowerShell solution built for IT Helpdesk Technicians and System Administrators to bulk-delete stale or inactive user profiles across domain-joined Windows endpoints.

It handles remote script deployment via SMB, executes profile deletions under the `NT AUTHORITY\SYSTEM` context using Sysinternals `PsExec`, and features **smart reboot safety checks** to avoid disrupting active end-users.

---

## 📁 Repository Structure

| File Name | Purpose | Execution Location |
| :--- | :--- | :--- |
| **`Run-RemoteCleanup.ps1`** | Master controller script. Reads `computers.csv`, creates remote directories, pushes the worker script, executes via PsExec, and evaluates session state before scheduling reboots. | Local Workstation |
| **`cleanprofile.ps1`** | Core worker script. Kills file-locking processes (OneDrive, Teams, Edge), detects active sessions via `quser`, preserves admin accounts, and deletes stale profiles via WMI/CIM. | Remote Target PC |
| **`computers.csv`** | CSV input file containing the list of target computer hostnames. | Local Workstation |

---

## ⚡ Smart Reboot & Safety Logic

The script dynamically adapts its behavior based on file lock status (`0x80070020`) and active user presence:

1. **Active User Protection:** Currently logged-in user profiles are detected via `quser` and automatically added to the exclusion list to prevent desktop session corruption.
2. **Idle Machines (Locked Files):** If files are locked and **nobody is logged in**, the script registers a `PendingProfileCleanup` startup task and initiates an immediate 10-second force reboot to finalize cleanup.
3. **Active Workstations (Locked Files):** If files are locked and a **user IS actively logged in**, the script registers the startup task for the **next manual/natural reboot** and **skips calling `shutdown.exe`** to prevent work loss.

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
