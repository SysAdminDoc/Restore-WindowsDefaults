<p align="center"><img src="icon.svg" width="128" height="128" alt="Restore-WindowsDefaults"></p>

# Windows Restore Tool

A one-click solution to fix Windows PCs broken by debloat scripts, privacy.sexy tweaks, and aggressive registry modifications.

![Version](https://img.shields.io/badge/version-4.4.0-green)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-blue)
![License](https://img.shields.io/badge/license-MIT-blue)

## The Problem

Debloat scripts and privacy tools like privacy.sexy, Win10Debloater, and similar utilities often go too far. They can disable Windows Defender, break Windows Update, disable critical services, and leave your system in an insecure or non-functional state.

**Windows Restore Tool** scans your system for these issues and restores Windows to safe, working defaults with a single click.

## Features

- **Pre-scan diagnostics** - Automatically detects what's broken before making changes
- **Quick scan summary** - Shows disabled services, tasks, missing apps, and registry modifications at a glance
- **Multiple fix modes** - Recommended, detected-only, security-only, or fully custom
- **47 restoration categories** - Comprehensive coverage of common tweaks
- **Progress bar** - Real-time progress with percentage as categories are processed
- **Category result indicators** - FIXED, PARTIAL, FAILED, or SKIPPED status for each category
- **Import undo manifest** - Load JSON manifests from Debloat-Win11 v1.1.0 for precise restoration
- **Debloat fingerprinting** - Detects evidence from O&O ShutUp10, WPD, ThisIsWin11, Sophia Script, and Win10Privacy without executing their code
- **Baseline inventory** - Exports and compares registry/AppX state, including provisioned-package and offline-WIM comparisons
- **Managed-device safety** - Reports structured domain, MDM, Group Policy, local-policy, and account-join provenance; managed values and categories are skipped by default unless an explicit operator override is recorded
- **Operational recovery** - Adds security reset, Search index rebuild, Store/WinGet repair, privacy-slider repair, integrity-checked rollback journals, and next-boot restore scheduling
- **Deployment wrappers** - Read-only compliance and optional remediation entry points for Intune and Configuration Manager
- **HTML report export** - Save a detailed dark-themed report of everything restored with before/after states
- **Safe by default** - Creates a System Restore point before making changes
- **Detailed logging** - Full log saved to your Desktop
- **Dark themed UI** - Modern interface that's easy on the eyes
- **No installation required** - Single PowerShell script, run and done

## Screenshot

![Windows Restore Tool](screenshot.png)

## Quick Start

### Option 1: Right-click (easiest)
1. Download `Restore-WindowsDefaults.ps1`
2. Right-click the file
3. Select **Run with PowerShell**

### Option 2: PowerShell
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Restore-WindowsDefaults.ps1
```

### Option 3: One-liner
```powershell
irm https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/Restore-WindowsDefaults.ps1 | iex
```

The script automatically elevates to Administrator and runs in Windows PowerShell 5.1 for maximum compatibility.

### Option 4: Detection and recovery CLI

The same script supports non-GUI workflows for automation and diagnostics:

```powershell
# Capture and compare a versioned registry snapshot
.\Restore-WindowsDefaults.ps1 -NoGui -ExportSnapshot .\before.json
.\Restore-WindowsDefaults.ps1 -NoGui -CompareSnapshot .\before.json
.\Restore-WindowsDefaults.ps1 -NoGui -WhatIf -RestoreCategories chkDefender,chkWindowsUpdate
.\Restore-WindowsDefaults.ps1 -NoGui -PlanPath .\restore-plan.json -RestoreCategories chkDefender,chkWindowsUpdate
.\Restore-WindowsDefaults.ps1 -NoGui -BaselineReport
.\Restore-WindowsDefaults.ps1 -NoGui -CapabilityReport -RestoreCategories chkDefender,chkWindowsUpdate
.\Restore-WindowsDefaults.ps1 -NoGui -CapabilityReport -AllowManagedPolicy -RestoreCategories chkDefender,chkWindowsUpdate
.\Restore-WindowsDefaults.ps1 -NoGui -RollbackLastRun
.\Restore-WindowsDefaults.ps1 -NoGui -ResumeRestoreJournal

# Run a bounded restore tier or a targeted operational workflow
.\Restore-WindowsDefaults.ps1 -RestoreTier Quick
.\Restore-WindowsDefaults.ps1 -SecurityReset
.\Restore-WindowsDefaults.ps1 -RebuildSearch
.\Restore-WindowsDefaults.ps1 -PostUpdateCheck
.\Restore-WindowsDefaults.ps1 -ExportSupportBundle .\support.zip

# Schedule selected categories for the next boot
.\Restore-WindowsDefaults.ps1 -ScheduleRestore -RestoreCategories chkDefender,chkWindowsUpdate,chkTasks
```

`-NoGui` is intended for automation. The Intune and Configuration Manager wrappers under `deploy\` emit JSON compliance results by default; add `-Remediate` to run the critical security and service/task categories in an already elevated management context.

The BaselineReport CLI emits the versioned registry, AppX, fingerprint, service/task, and scheduled-task catalogs with source provenance, supported build and edition ranges, confidence, and warning-only handling for unknown entries. No catalog entry with unknown provenance or unsupported scope is eligible for automatic fixes.

Capability reports and action plans include the management schema, detected ownership evidence, policy source, default decision, and `ManagedPolicyOverride`. Domain/MDM/organization-owned categories are `OrganizationOwned` and remain non-executable by default. `-AllowManagedPolicy` records `OverrideRequested` in the report, plan metadata, and category results; use it only when the operator has authority to replace the organization policy. `dsregcmd` signals are parsed only from recognized structured fields. Unavailable or unrecognized output is retained only as a warning-labeled fallback and never treated as proof of local ownership.

## What It Restores

### Security (Critical)
| Category | What it fixes |
|----------|---------------|
| Windows Defender | Re-enables real-time protection, cloud protection, automatic updates |
| Windows Firewall | Restores all firewall profiles (Domain, Private, Public) |
| SmartScreen | Re-enables app, download, and Edge SmartScreen filters |
| UAC | Restores User Account Control to default settings |
| Windows Update | Removes update blocks, re-enables automatic updates |

### System Services
| Category | What it fixes |
|----------|---------------|
| Core Services | SysMain, Windows Search, BITS, Windows Update services |
| Scheduled Tasks | Disk cleanup, defrag, diagnostics, CEIP tasks |
| Error Reporting | Windows Error Reporting service and settings |

### Privacy & Telemetry
| Category | What it fixes |
|----------|---------------|
| Telemetry | Restores diagnostic data settings to defaults |
| Cortana & Copilot | Re-enables Cortana, Copilot, and AI features |
| Activity History | Restores timeline and activity sync |
| Advertising ID | Restores default ad personalization settings |

### UI & Shell
| Category | What it fixes |
|----------|---------------|
| Taskbar | Restores search box, widgets, Chat, Meet Now icons |
| Explorer | Restores ribbons, OneDrive, recent files, 3D Objects |
| Start Menu | Restores suggestions, recent apps, Bing search |
| Context Menus | Restores full right-click menus (removes Win11 compact) |

### Apps & Features
| Category | What it fixes |
|----------|---------------|
| Microsoft Edge | Removes restrictive policies |
| Microsoft Office | Restores telemetry and macro security defaults |
| Windows Apps | Can reinstall removed Calculator, Photos, Store, etc. |
| OneDrive | Restores OneDrive integration and sync |

### Network & Hardware
| Category | What it fixes |
|----------|---------------|
| Network | Restores NetBIOS, LLMNR, network discovery |
| Bluetooth | Re-enables Bluetooth services |
| Remote Desktop | Restores RDP services |
| Power Settings | Re-enables hibernation, restores power defaults |

### Hosts File
Removes domain blocks commonly added by privacy scripts (telemetry, update, and tracking domains).

## Fix Modes

| Mode | Description |
|------|-------------|
| **Recommended Fix** | Restores all safe defaults. Keeps your dark theme. Does NOT reinstall removed apps. |
| **Fix Detected Only** | Only fixes the specific issues found by the scanner. |
| **Security Only** | Only fixes Defender, Firewall, SmartScreen, Windows Update, and UAC. |
| **Custom** | Pick exactly which categories to restore from all 47 options. |
| **Preview Only** | Shows what would change without making any changes. |

## Import Undo Manifest

If you used Debloat-Win11 v1.1.0 or a similar tool that generates an undo manifest (JSON file), you can import it:

1. Click **Import Manifest** on the main screen
2. Select the JSON manifest file
3. The tool auto-checks only the categories relevant to the manifest changes
4. A summary shows exactly how many AppX packages, services, tasks, and registry keys will be restored
5. Click **Run Selected Fixes** to restore precisely what was changed

The import path is evidence-only and uses a versioned, bounded safe schema: privacy.sexy compensation logs, Chris Titus WinUtil diffs, .reg exports, and newer nested undo manifests are limited by bytes, lines, depth, and items; validated entries carry provenance and are classified as verified/untrusted evidence, while malformed or unsupported entries retain a reason. Imported text is never executed as code.

## HTML Report

After restoration completes, click **Export Report** to save a detailed HTML report containing:
- Summary of fixed, partial, and failed categories
- Total changes made
- Full detailed log with color-coded entries
- Before/after states for all operations

## Safety Features

- **System Restore Point** - Automatically created before changes (optional but recommended)
- **Non-destructive** - Only restores settings to Windows defaults, doesn't delete user data
- **Detailed Logging** - Complete log saved to Desktop with timestamps
- **Preview Mode** - See exactly what would change before committing
- **Versioned action plans** - Export scoped operations with before/after state, risk, rollback metadata, capability decisions, and a plan hash
- **Integrity-checked rollback** - Each restore run keeps an atomic journal under `%ProgramData%\Restore-WindowsDefaults\rollback`; interrupted runs can resume, and tampered journals are refused before mutation
- **Graceful Errors** - Continues through errors, reports them at the end
- **Category Results** - FIXED, PARTIAL, FAILED, SKIPPED indicators show exactly what happened

## Requirements

- Windows 10 or Windows 11
- Windows 10 build 10240 or newer, or Windows 11 build 22000 or newer
- x86, x64, or ARM64 Windows architecture
- PowerShell 5.1 (included with Windows)
- Administrator privileges

Before any restore, the tool records the product family, build, edition, architecture, locale, PowerShell runtime, elevation state, and structured management provenance. Unknown or unsupported profiles, and categories owned by organization policy, are skipped without mutation. Policy findings in health and post-update reports identify source, ownership evidence, confidence, and the actionable skip/override decision. Use `-CapabilityReport` or `-PlanPath` to export the machine profile and per-category gate decisions for automation.

## FAQ

**Q: Will this undo my dark theme?**
A: No, the Recommended Fix specifically preserves your theme settings.

**Q: Will this reinstall bloatware apps?**
A: Not by default. App reinstallation is a separate option in Custom mode.

**Q: Is it safe to run?**
A: Yes. It only restores Windows defaults and creates a restore point first. You can always undo changes via System Restore.

**Q: My antivirus flags this script. Is it malware?**
A: No. PowerShell scripts that modify system settings often trigger false positives. Review the source code yourself - it's fully readable.

**Q: I ran a specific debloat script. Will this fix it?**
A: This tool fixes the effects of most common debloat scripts including Win10Debloater, privacy.sexy exports, Sophia Script, and manual registry tweaks.

## Building / Contributing

This is a single self-contained PowerShell script. No build process required.

To contribute:
1. Fork the repository
2. Make your changes
3. Test thoroughly on a VM
4. Submit a pull request

## License

MIT License - See [LICENSE](LICENSE) for details.

## Disclaimer

This tool modifies Windows system settings and registry values. While it's designed to be safe and creates restore points, always ensure you have backups of important data. Use at your own risk.

---

**Made for IT professionals tired of fixing PCs broken by overzealous "optimization" scripts.**
