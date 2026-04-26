# Restore-WindowsDefaults Roadmap

PowerShell 5.1 WPF tool that undoes debloat-script damage (47 restoration categories, detection-first, HTML report). Roadmap extends category coverage, adds selective undo for more debloat tools, and matures into a pre/post imaging utility.

## Planned Features

### Detection
- Broader scanner: detect settings from O&O ShutUp10, WPD, ThisIsWin11, Sophia, Win10Privacy
- Registry snapshot-diff mode (snapshot before debloat, compare after)
- Service / task fingerprint database per debloat tool
- AppX package removal detection by wim comparison
- Scheduled task restore matrix (which tasks disabled by which tools)

### Restoration Depth
- Windows Security Center full reset (all providers: Defender, Firewall, Update, SmartScreen)
- Windows Update channel + deferral reset with explicit policy cleanup
- Edge policies reset (managed vs unmanaged detection)
- Search indexer rebuild option
- Store / WinGet service chain repair
- Bluetooth / camera / microphone privacy slider reset
- Microsoft Account vs Local Account sign-in repair
- Task Scheduler missing-task repair (re-import from `%WINDIR%\System32\Tasks` golden copy)

### Manifest Interop
- Debloat-Win11 v1.1 manifest (already) + newer versions
- privacy.sexy script-generated compensation log ingester
- Chris Titus WinUtil diff reader
- Generic "what changed" import by feeding two `reg export` snapshots

### UX
- Pre-flight "impact preview" showing deltas per category
- Timeline scrubber (what will be fixed at each step)
- Export / email HTML report
- Schedule restore for next reboot (for locked keys / services)
- Rollback mode — undo a previous Restore-WindowsDefaults run

### Packaging & Signing
- Authenticode-signed release
- winget manifest
- Intune / SCCM remediation script templates
- MSIX packaging

## Competitive Research
- **Windows Repair Toolbox** — broad repair launcher. Lesson: WRT is a launcher around third-party tools; ours must stay self-contained.
- **Sophia Script Undo** — per-script undo, requires tool. Lesson: support reading their `StoredRegistryValues` log for targeted reversal.
- **Tweaker (winaerotweaker) Reset** — reset-to-default button. Lesson: match their granular per-tweak reset lists.
- **DISM + SFC** — built-in baseline. Lesson: integrate, don't replace.

## Nice-to-Haves
- Group Policy template reset alongside registry
- Domain-joined mode awareness (skip personal-account restores)
- Multi-PC batch mode via PowerShell remoting
- Backup vault — auto-snapshot before any run, keep last 10
- Localization (en, de, fr, es, pt-BR)
- Telemetry-free crash reporter (bundled zip on Desktop)

## Open-Source Research (Round 2)

### Related OSS Projects
- https://github.com/Sycnex/Windows10Debloater — Has a `Revert` option that reinstalls bloatware and restores registry keys, closest peer
- https://github.com/bRootForceSec/Win11-Debloat-And-Privacy — Auto-creates system restore point before each run, documents reversibility
- https://github.com/simeononsecurity/Windows-Optimize-Harden-Debloat — STIG/SRG-compliant hardening, keeps Update/Defender/Cortana in a functional state
- https://github.com/ionuttbara/windows-defender-remover — Reference for the full surface area of Defender components a debloat script can destroy (VBS, SmartScreen, AppGuard, DriverBlockList, File Virtualization, Settings page)
- https://github.com/lostzombie/AchillesScript — Documents which Defender disables survive Windows Update vs which revert
- https://github.com/flick9000/winscript — Builder-style privacy/perf/Defender-CPU-cap toggles
- https://github.com/TheWorldOfPC/Windows11-Debloat-Privacy-Guide — Reference registry-key catalog for Defender + SmartScreen tweaks
- https://github.com/topics/windows-defender — Topic hub

### Features to Borrow
- Revert function naming + structure (`Start-Debloat` / `Remove-Keys` / `Protect-Privacy` inverse set) from Sycnex/Windows10Debloater
- Explicit system-restore-point creation before any mutation + graceful handling of 24h cooldown (bRootForceSec)
- Full Defender component map to scan (VBS / SmartScreen / AppGuard / DriverBlockList / File Virtualization / Settings-app page / Security-services / Web-Threat / Driver-BlockList) (windows-defender-remover)
- Post-Windows-Update re-check mode — warn if previously disabled Defender components were re-enabled (AchillesScript)
- STIG/SRG-aware baseline preset (Windows-Optimize-Harden-Debloat) — one-click "DoD-acceptable" rather than just "factory"
- Defender CPU-cap registry key as a separate toggle (winscript)
- Documented reversibility per-setting in UI (bRootForceSec README pattern)

### Patterns & Architectures Worth Studying
- Scan-then-apply two-phase pattern with dry-run diff between them (several repos do scan but not diff-preview)
- JSON baseline catalog of "known safe default" registry values shipped with the script, rather than hard-coded values (Windows-Optimize-Harden-Debloat style)
- Idempotent Ensure-* function pattern — every restore is `if (-not desired) { set }` rather than blind writes
- Layered restore tiers: Quick (services + tasks), Full (+ registry), Nuclear (+ reinstall missing provisioned packages) — pulled from bRootForceSec's tier model
