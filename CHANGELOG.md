# Changelog

All notable changes to Restore-WindowsDefaults will be documented in this file.

## [Unreleased]

- Added a versioned, build-aware baseline catalog contract across registry defaults, AppX expectations, debloat fingerprints, service/task evidence, and CLI reporting, with provenance, confidence, and warning-only unknown entries.
- Added structured managed-policy provenance across health findings, capability reports, action plans, and restore results, including domain/MDM/Group Policy evidence, labeled `dsregcmd` fallbacks, default preservation of organization-owned values, and recorded operator overrides.
- Constrained external undo imports to schema v2 with bounded input, allowlisted paths and operations, provenance, and distinct verified, untrusted, malformed, and unsupported evidence results.
- Added fail-closed capability gates with versioned machine profiles, per-category OS/build/architecture/runtime declarations, managed-policy ownership decisions, CLI capability reports, and Intune/SCCM reporting.
- Added versioned `-WhatIf`/`-PlanPath` action plans with capability decisions, registry/service/task state where statically known, operation hashes, and explicit review boundaries for remaining category-level operations.
- Routed fully represented registry, service, and scheduled-task operations through `ShouldProcess`-aware mutation primitives and the versioned plan executor.
- Made mapped category restore paths capture exact registry, service, task, file, AppX, environment, optional-feature, native-command, and restore-point operations before execution, with stale-state precondition checks shared by CLI and GUI.
- Replaced run snapshots with v2 atomic rollback journals containing per-operation state, SHA-256 integrity, resumable execution, tamper refusal, inverse adapters, and legacy snapshot compatibility.
- Added bounded native-command outcomes with exit codes, stderr, reboot-required and failure-taxonomy states, independent fresh postcondition verification, explicit pending-reboot reporting, and structured propagation through CLI, GUI, Intune, and Configuration Manager results.
- Added explicit AppX scope contracts for current-user, all-existing-user, provisioned-image, and offline-image observations, with read-only capability gates, scope-aware registry metadata, CLI/GUI selectors, and scheduled-state propagation.
- Hardened next-boot restore into an expiring, integrity-checked job with owner/plan/rollback metadata, failure-safe two-phase registration, status and cancellation commands, stale-job refusal, and idempotent journal-backed resume.
- Reworked support bundles around a fixed allowlist with bounded redacted event text, aggregate health/scan summaries, collision-safe output, size limits, SHA-256 payload manifests, and machine-readable exclusion/redaction reports.
- Added plan-first offline WIM/VHD servicing with source/index/edition/architecture/DISM/scratch/lock gates, explicit commit/discard lifecycle actions, cleanup guards, and bounded AppX, optional-feature, task, and machine-policy adapters.

## [v4.4.0] - 2026-08-03

- Added detection-only fingerprints for common debloat tools plus disabled service/task attribution.
- Added versioned registry and AppX baseline snapshots, `.reg` comparison, and offline-WIM package comparison.
- Added managed-policy awareness, deeper Windows Update/Security/Store/Search/privacy/account restoration, and missing-task repair.
- Added rollback snapshots, next-boot scheduling, restore tiers, post-update security checks, support bundles, and Intune/SCCM deployment wrappers.
- Added parser coverage for external change logs and nested undo manifests without executing imported content.

## [v4.3.0] - 2026-04-13

- Added: Add project icon to README
- v4.3.0 - Progress bar, manifest import, pre-scan summary, category results, HTML report
- Initial commit - Restore-WindowsDefaults

## Roadmap archive — 2026-08-10 — ROADMAP.md

<details>
<summary>Original roadmap snapshot</summary>

```markdown
# Restore-WindowsDefaults Roadmap

PowerShell 5.1 WPF tool that undoes debloat-script damage (47 restoration categories, detection-first, HTML report). Roadmap extends category coverage, adds selective undo for more debloat tools, and matures into a pre/post imaging utility.

## Planned Features

### Detection

### Restoration Depth

### Manifest Interop

### UX

## Research-Driven Additions

- [ ] P1 — Move health discovery off the UI thread with timeouts and cancellation
  Why: `Get-SystemHealthReport` performs broad serial registry/service/task/AppX work and the GUI can take minutes before it becomes useful; there is no cancel or partial-result state.
  Evidence: `Restore-WindowsDefaults.ps1` (`Show-MainWindow`, `Get-SystemHealthReport`, `Get-QuickScanSummary`); Winhance's release notes document activity-aware timeouts and startup-race fixes; WPF UI Automation guidance supports testable control state.
  Touches: health pipeline, WPF page state, progress/cancel controls, log/result model, performance tests.
  Acceptance: Scan starts asynchronously, reports per-check progress and elapsed time, enforces per-check/global timeouts, supports cancel without mutation, returns partial/timeout/error states, and keeps the UI responsive on a representative low-end fixture.
  Complexity: L

- [ ] P1 — Publish stable CLI and Intune/SCCM/WinRM adapter contracts
  Why: Deployment wrappers hard-code seven categories and do not expose a common versioned JSON result, while Intune requires precise detection exit semantics and forbids reboot commands in remediation scripts.
  Evidence: `deploy\Intune-Restore-WindowsDefaults.ps1`, `deploy\SCCM-Restore-WindowsDefaults.ps1`, `Invoke-RemoteRestoreBatch`; [Intune Remediations contract](https://learn.microsoft.com/en-us/intune/device-management/tools/deploy-remediations).
  Touches: deployment wrappers, CLI parameter/result model, category configuration, remote aggregation, README examples, tests.
  Acceptance: Detection/remediation/CLI/remote modes share a documented schema version, explicit exit codes, bounded output, category scope, dry-run flag, and no-reboot guarantee; wrappers consume configurable plan IDs instead of duplicated category lists; an integration fixture validates compliance, remediation, partial failure, and rollback results.
  Complexity: M

- [ ] P1 — Add a cross-build contract test matrix and release gate
  Why: The suite has only 14 tests and no CI; critical paths are untested across Windows editions/builds, native tools, wrappers, manifests, rollback, WIMs, and UI parsing.
  Evidence: `Restore-WindowsDefaults.Tests.ps1`, baseline of 14 passing Pester tests and 64 PSScriptAnalyzer warnings; [Pester releases](https://github.com/pester/Pester/releases); [PSScriptAnalyzer releases](https://github.com/PowerShell/PSScriptAnalyzer/releases).
  Touches: tests, fixtures, `.github\workflows`, PSScriptAnalyzer configuration, release checklist.
  Acceptance: CI runs syntax/static checks and unit/contract tests on every change; fixtures cover supported/unknown builds, managed state, import limits, `-WhatIf`, rollback round trips, native failures, AppX/WIM, schedule lifecycle, bundle redaction, wrapper output, and UI XAML/accessibility; baseline warnings are tracked separately from new diagnostics.
  Complexity: L

- [ ] P1 — Unify version, schema, and reproducible distribution metadata
  Why: The script, README, CHANGELOG, `CLAUDE.md`, UI, wrappers, snapshot schemas, and release path do not have one authoritative version contract.
  Evidence: `Restore-WindowsDefaults.ps1`, `README.md`, `CHANGELOG.md`, `CLAUDE.md`, deployment wrappers; [PowerShell support lifecycle](https://learn.microsoft.com/en-us/powershell/scripting/install/powershell-support-lifecycle?view=powershell-7.6); [WinGet release history](https://github.com/microsoft/winget-cli/releases).
  Touches: version metadata, reports/UI/wrappers, README/CHANGELOG, release scripts and hash manifest.
  Acceptance: One metadata source emits tool version, category catalog version, snapshot/plan schema versions, supported OS matrix, runtime requirements, and SHA-256 values; release checks reject stale strings, missing assets, placeholder URLs, or untracked schema changes; distribution separates download, inspection, hash verification, and execution.
  Complexity: M

- [ ] P2 — Make the WPF shell keyboard-first, accessible, responsive, and per-monitor-DPI safe
  Why: Card-like `Border` controls rely on mouse events, automation names/focus order are sparse, and fixed dimensions can clip at high DPI or smaller windows.
  Evidence: `Restore-WindowsDefaults.ps1` (`Show-MainWindow`); [UI Automation overview](https://learn.microsoft.com/en-us/dotnet/framework/ui-automation/ui-automation-overview); [accessibility checklist](https://learn.microsoft.com/en-us/windows/apps/design/accessibility/accessibility-checklist); [per-monitor-v2 guidance](https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows).
  Touches: XAML/styles/event handlers in `Show-MainWindow`, page navigation, report/export controls, UI tests.
  Acceptance: All actions are real focusable controls with names, descriptions, predictable tab order, visible focus, keyboard activation, high-contrast-safe states, minimum-size behavior, and per-monitor-v2 layout; an offscreen UIA test can discover and invoke the golden path without pointer injection.
  Complexity: L

- [ ] P2 — Add structured observability without sending data off-device
  Why: Logs are primarily human text and support bundles are post-hoc; fleet operators need event-level correlation for scan, plan, mutation, verification, skip, and rollback outcomes.
  Evidence: `Restore-WindowsDefaults.ps1` (`Write-Log`, HTML report, support bundle); [Write-EventLog](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/write-eventlog?view=powershell-5.1); Intune's bounded script-output requirements.
  Touches: event model, JSONL/ETW or Windows Event Log adapter, HTML/report exporters, wrappers, privacy tests.
  Acceptance: Each run has a correlation ID and monotonic operation IDs; CLI can emit deterministic JSONL while GUI remains human-readable; events contain no secrets by default; event schema, retention, redaction, and wrapper truncation behavior are documented and tested.
  Complexity: M

- [ ] P2 — Extract a data-driven category/action registry before adding more restore categories
  Why: The single script contains parallel category maps, detection logic, UI labels, wrapper lists, and version strings, which already produces a 47-category documentation mismatch.
  Evidence: `Restore-WindowsDefaults.ps1` (`Get-RestoreFunctionMap`, category checkbox construction, report generation); [DSC declarative Get/Test/Set model](https://learn.microsoft.com/en-us/powershell/dsc/overview?view=dsc-3.0); Sophia's per-function architecture.
  Touches: category metadata, detection/planning/restore dispatch, UI and wrappers, schema migration, tests.
  Acceptance: One registry drives discovery, plan, restore, verification, risk/scope labels, UI, CLI help, wrapper selection, and report output; adding a category cannot require editing multiple unrelated lists; a future plugin boundary is documented but no arbitrary third-party code is auto-loaded.
  Complexity: XL

- [ ] P2 — Version and migrate snapshot, plan, rollback, and manifest schemas
  Why: Current imports reject unsupported schema versions but have no migration path, leaving users with old snapshots after a tool upgrade or category catalog change.
  Evidence: `Restore-WindowsDefaults.ps1` snapshot import/compare and rollback state validation; [WinGet configuration schema/validation model](https://learn.microsoft.com/en-us/windows/package-manager/configuration/create).
  Touches: schema validators/migrators, snapshot/plan/rollback/import functions, version metadata, fixtures and upgrade tests.
  Acceptance: Schemas declare version, tool/catalog/build context, and migration compatibility; migrations are pure, bounded, idempotent, and produce a before/after audit; incompatible state is preserved and explained rather than silently discarded.
  Complexity: L
```

</details>
