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
