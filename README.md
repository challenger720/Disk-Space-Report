# Automated Multi-Machine User Profile Cleanup

An automated, two-part PowerShell tool built for IT Helpdesk Technicians and System Administrators to bulk-delete stale or inactive user profiles across domain-joined Windows machines. 

It handles remote file distribution via SMB, executes profile deletions under the `NT AUTHORITY\SYSTEM` context using Sysinternals `PsExec`, and automatically handles locked profile files (`0x80070020`) by scheduling a temporary startup task and triggering a reboot.

---

## 📁 Repository Structure

| File Name | Purpose | Execution Location |
| :--- | :--- | :--- |
| **`Run-RemoteCleanup.ps1`** | Master controller script that reads `computers.csv`, creates target directories, copies the worker script, executes it via PsExec, and schedules reboots for locked profiles. | Local Workstation |
| **`cleanprofile.ps1`** | Core worker script that terminates file-locking processes (OneDrive, Teams, Edge), queries WMI/CIM for user profiles, protects active/admin accounts, and removes stale profiles. | Remote Target PC |
| **`computers.csv`** | CSV input file containing the list of target computer hostnames. | Local Workstation |

---

## 📋 Prerequisites

Before running the script, ensure the following requirements are met on your technician machine and domain targets:

1. **Local Workstation:**
   * PowerShell 5.1 or higher running as **Administrator**.
   * Sysinternals **PsExec** installed (default path: `C:\Tools\PSTools\PsExec.exe`).
   * Files placed inside `C:\Temp\`:
     * `C:\Temp\Run-RemoteCleanup.ps1`
     * `C:\Temp\cleanprofile.ps1`
     * `C:\Temp\computers.csv`

2. **Target Network / Domain:**
   * Active Directory Domain Environment with Administrative rights over target workstations.
   * **SMB (Port 445)** open between your technician machine and target computers.
   * Administrative Shares (`C$`, `ADMIN$`) enabled on target endpoints.

---

## ⚙️ Configuration & Setup

### 1. Populate `computers.csv`
Edit `C:\Temp\computers.csv` and add your target computer hostnames under the `ComputerName` column header:

```csv
ComputerName
JC053509
JC053860
JC053861
