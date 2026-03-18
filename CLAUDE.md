# CLAUDE.md - Restore-WindowsDefaults

## Overview
Un-debloat tool that reverses changes made by debloat scripts, privacy.sexy, Group Policy mods, and registry tweaks. Restores Windows to factory defaults. v4.2.0.

## Tech Stack
- PowerShell 5.1 (forces WinPS 5.1 from PS7 for Appx module compatibility)
- WPF GUI with embedded console/log panel (`$script:ConsoleBox`)

## Key Details
- ~3,023 lines, single-file (largest script in the collection)
- Self-elevates to admin
- Pre-scan diagnostics, preset fix modes
- Per-category result tracking (`$script:CategoryResults`)
- Generates timestamped log on Desktop (`WindowsRestore_*.log`)

## Build/Run
```powershell
.\Restore-WindowsDefaults.ps1
```

## Version
4.2.0

## Gotchas
- Must run under Windows PowerShell 5.1 (Appx module incompatible with PS7)
- Script auto-relaunches in WinPS if started from PS7
