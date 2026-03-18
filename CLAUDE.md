# CLAUDE.md - Restore-WindowsDefaults

## Overview
Un-debloat tool that reverses changes made by debloat scripts, privacy.sexy, Group Policy mods, and registry tweaks. Restores Windows to factory defaults. v4.3.0.

## Tech Stack
- PowerShell 5.1 (forces WinPS 5.1 from PS7 for Appx module compatibility)
- WPF GUI with embedded console/log panel (`$script:ConsoleBox`)

## Key Details
- ~3,400+ lines, single-file (largest script in the collection)
- Self-elevates to admin
- Pre-scan diagnostics with quick summary panel (disabled services, tasks, missing apps, registry mods)
- Preset fix modes (Recommended, Detected, Security, Custom, Preview)
- Per-category result tracking (`$script:CategoryResults`) with FIXED/PARTIAL/FAILED/SKIPPED indicators
- Import Debloat-Win11 v1.1.0 JSON undo manifests for precise restoration
- Export HTML report with before/after states and detailed log
- Progress bar with percentage during restoration
- Generates timestamped log on Desktop (`WindowsRestore_*.log`)
- 47 restoration categories across 6 groups

## Build/Run
```powershell
.\Restore-WindowsDefaults.ps1
```

## Version History
- 4.3.0 - Progress bar, manifest import, pre-scan summary, category result indicators, HTML report export
- 4.2.0 - Initial public release with pre-scan diagnostics, preset modes, 47 categories

## Gotchas
- Must run under Windows PowerShell 5.1 (Appx module incompatible with PS7)
- Script auto-relaunches in WinPS if started from PS7
- NEVER use emoji/unicode in PowerShell output (encoding errors)
- XAML uses single-quoted here-string to prevent variable expansion
- Category result indicators use TextBlock elements, not unicode symbols

## Architecture
- `Get-SystemHealthReport` - Deep pre-scan diagnostics engine
- `Get-QuickScanSummary` - Fast count of disabled services/tasks/missing apps/registry mods
- `Import-UndoManifest` - Parses Debloat-Win11 JSON manifests, maps to categories
- `Export-HtmlReport` - Generates dark-themed HTML report with full log
- `Show-MainWindow` - WPF GUI with 3 pages (Home, Custom, Progress)
- `$funcMap` - Maps checkbox keys to restoration functions
- `$runRestore` - Core restore loop with progress tracking and result indicators
