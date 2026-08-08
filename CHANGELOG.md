# Changelog

All notable changes to Restore-WindowsDefaults will be documented in this file.

## [Unreleased]

- Added fail-closed capability gates with versioned machine profiles, per-category OS/build/architecture/runtime declarations, managed-policy ownership decisions, CLI capability reports, and Intune/SCCM reporting.
- Added versioned `-WhatIf`/`-PlanPath` action plans with capability decisions, registry/service/task state where statically known, operation hashes, and explicit review boundaries for remaining category-level operations.
- Routed fully represented registry, service, and scheduled-task operations through `ShouldProcess`-aware mutation primitives and the versioned plan executor.
- Made mapped category restore paths capture exact registry, service, task, file, AppX, environment, optional-feature, native-command, and restore-point operations before execution, with stale-state precondition checks shared by CLI and GUI.
- Replaced run snapshots with v2 atomic rollback journals containing per-operation state, SHA-256 integrity, resumable execution, tamper refusal, inverse adapters, and legacy snapshot compatibility.

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
