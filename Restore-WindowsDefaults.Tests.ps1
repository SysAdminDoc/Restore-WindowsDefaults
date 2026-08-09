BeforeAll {
    . (Join-Path $PSScriptRoot "Restore-WindowsDefaults.ps1") -NoGui -NoElevation
}

Describe "Restore-WindowsDefaults inventory primitives" {
    It "exposes all supported debloat tool fingerprints without probing mutation paths" {
        $reports = @(Get-DebloatToolFingerprintReport -IncludeUndetected)

        $reports.Count | Should -Be 5
        @($reports.Tool) | Should -Contain "O&O ShutUp10"
        @($reports.Tool) | Should -Contain "WPD"
        @($reports.Tool) | Should -Contain "ThisIsWin11"
        @($reports.Tool) | Should -Contain "Sophia Script"
        @($reports.Tool) | Should -Contain "Win10Privacy"
        @($reports | Where-Object { $_.Confidence -eq "None" }).Count | Should -BeGreaterThan 0
        @($reports | Where-Object { $_.CatalogStatus -eq "Verified" }).Count | Should -Be $reports.Count
        $reports[0].CatalogVersion | Should -Be "rwd-baseline-1.0"
        $reports[0].SupportedBuildRange | Should -Match "Windows 11"
        $reports[0].EvidenceType | Should -Be "ExplicitIndicator"
    }

    It "attributes disabled services and tasks through injectable providers" {
        $catalog = @(
            @{Tool="TestTool";Services=@("DisabledService","HealthyService");Tasks=@(
                @{P="\Test\";N="DisabledTask"},
                @{P="\Test\";N="HealthyTask"}
            )}
        )
        $serviceProvider = {
            param($name)
            [pscustomobject]@{StartType=if ($name -eq "DisabledService") { "Disabled" } else { "Automatic" }}
        }
        $taskProvider = {
            param($path,$name)
            [pscustomobject]@{State=if ($name -eq "DisabledTask") { "Disabled" } else { "Ready" }}
        }

        $findings = @(Get-ServiceTaskFingerprintReport -Catalog $catalog -ServiceProvider $serviceProvider -TaskProvider $taskProvider)

        $findings.Count | Should -Be 2
        @($findings | Where-Object { $_.Kind -eq "Service" -and $_.NeedsRestore }).Count | Should -Be 1
        @($findings | Where-Object { $_.Kind -eq "Task" -and $_.NeedsRestore }).Count | Should -Be 1
    }

    It "reports missing and disabled tasks from the restore matrix" {
        $matrix = @(
            @{Source="Test";Tools=@("TestTool");P="\Test\";N="DisabledTask";Category="chkTasks"},
            @{Source="Test";Tools=@("TestTool");P="\Test\";N="MissingTask";Category="chkTasks"}
        )
        $taskProvider = {
            param($path,$name)
            if ($name -eq "DisabledTask") { [pscustomobject]@{State="Disabled"} }
            else { throw "not found" }
        }

        $findings = @(Get-ScheduledTaskRestoreMatrix -Matrix $matrix -TaskProvider $taskProvider)

        $findings.Count | Should -Be 2
        ($findings | Where-Object Name -eq "DisabledTask").NeedsRestore | Should -BeTrue
        ($findings | Where-Object Name -eq "MissingTask").State | Should -Be "Missing"
    }
}

Describe "Restore-WindowsDefaults snapshot and AppX comparisons" {
    It "classifies added, removed, and changed registry values" {
        $before = [pscustomobject]@{
            SchemaVersion=1
            Entries=@(
                [pscustomobject]@{Path="HKCU:\Test";Name="Changed";Type="DWord";Value=1},
                [pscustomobject]@{Path="HKCU:\Test";Name="Removed";Type="String";Value="old"}
            )
        }
        $after = [pscustomobject]@{
            SchemaVersion=1
            Entries=@(
                [pscustomobject]@{Path="HKCU:\Test";Name="Changed";Type="DWord";Value=2},
                [pscustomobject]@{Path="HKCU:\Test";Name="Added";Type="String";Value="new"}
            )
        }

        $diff = Compare-RegistrySnapshots -Before $before -After $after

        $diff.TotalChanges | Should -Be 3
        @($diff.Added).Name | Should -Contain "Added"
        @($diff.Removed).Name | Should -Contain "Removed"
        @($diff.Changed).Name | Should -Contain "Changed"
    }

    It "detects AppX packages missing from both the user and provisioned image" {
        $expected = @(
            @{Name="Microsoft.WindowsStore"},
            @{Name="Microsoft.WindowsCalculator"},
            @{Name="Microsoft.Windows.Photos"}
        )
        $installed = @([pscustomobject]@{Name="Microsoft.WindowsStore"})
        $provisioned = @([pscustomobject]@{DisplayName="Microsoft.WindowsCalculator"})

        $report = Get-AppxPackageRemovalReport -ExpectedPackages $expected -InstalledPackages $installed -ProvisionedPackages $provisioned

        $report.Present | Should -Contain "Microsoft.WindowsStore"
        $report.ProvisionedOnly | Should -Contain "Microsoft.WindowsCalculator"
        $report.Missing | Should -Contain "Microsoft.Windows.Photos"
        $report.MissingCount | Should -Be 1
        $report.CatalogStatus | Should -Be "Warnings"
        $report.CanAutoFix | Should -BeFalse
        $report.UnknownExpectedPackages | Should -Contain "Microsoft.Windows.Photos"
    }

    It "round-trips an empty registry snapshot through the versioned file contract" {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("Restore-WindowsDefaults-{0}.json" -f ([guid]::NewGuid().ToString("N")))
        try {
            $snapshot = Export-RegistrySnapshot -OutputPath $path -Path @()
            $loaded = Import-RegistrySnapshot -InputPath $path

            $loaded.SchemaVersion | Should -Be 1
            @($loaded.Entries).Count | Should -Be 0
            $snapshot.SchemaVersion | Should -Be $loaded.SchemaVersion
        } finally {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe "Restore-WindowsDefaults external change imports" {
    It "parses privacy.sexy compensation commands without executing them" {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("privacy-sexy-{0}.log" -f ([guid]::NewGuid().ToString("N")))
        try {
            @(
                'reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /d 0',
                'sc.exe config DiagTrack start= disabled',
                'schtasks.exe /change /tn "\Microsoft\Windows\WindowsUpdate\Scheduled Start" /disable'
            ) | Set-Content -LiteralPath $path

            $result = Import-PrivacySexyCompensationLog -LogPath $path

            $result.Success | Should -BeTrue
            $result.Operations.Count | Should -Be 3
            $result.RelevantCategories | Should -Contain "chkPrivacy"
            $result.RelevantCategories | Should -Contain "chkServices"
            $result.RelevantCategories | Should -Contain "chkTasks"
        } finally {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }

    It "reads Chris Titus style diff lines through the same safe parser" {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("winutil-diff-{0}.txt" -f ([guid]::NewGuid().ToString("N")))
        try {
            @(
                "Registry: HKLM:\SOFTWARE\Policies\Microsoft\Edge SmartScreenEnabled",
                "Service: wuauserv disabled",
                "AppX: Microsoft.WindowsStore removed"
            ) | Set-Content -LiteralPath $path

            $result = Import-ChrisTitusWinUtilDiff -DiffPath $path

            $result.Operations.Count | Should -Be 3
            $result.RelevantCategories | Should -Contain "chkEdge"
            $result.RelevantCategories | Should -Contain "chkWindowsUpdate"
            $result.RelevantCategories | Should -Contain "chkAppx"
        } finally {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }

    It "imports reg export files and compares them as registry snapshots" {
        $beforePath = Join-Path ([System.IO.Path]::GetTempPath()) ("before-{0}.reg" -f ([guid]::NewGuid().ToString("N")))
        $afterPath = Join-Path ([System.IO.Path]::GetTempPath()) ("after-{0}.reg" -f ([guid]::NewGuid().ToString("N")))
        try {
            @(
                'Windows Registry Editor Version 5.00',
                '',
                '[HKEY_CURRENT_USER\Software\RestoreTest]',
                '"Changed"=dword:00000001',
                '"Removed"="old"'
            ) | Set-Content -LiteralPath $beforePath
            @(
                'Windows Registry Editor Version 5.00',
                '',
                '[HKEY_CURRENT_USER\Software\RestoreTest]',
                '"Changed"=dword:00000002',
                '"Added"="new"'
            ) | Set-Content -LiteralPath $afterPath

            $diff = Compare-RegExportSnapshots -BeforePath $beforePath -AfterPath $afterPath

            $diff.TotalChanges | Should -Be 3
            @($diff.Changed).Name | Should -Contain "Changed"
            @($diff.Added).Name | Should -Contain "Added"
            @($diff.Removed).Name | Should -Contain "Removed"
            $snapshot = Import-RegExportSnapshot -RegPath $beforePath
            $snapshot.ImportSchemaVersion | Should -Be 2
            $snapshot.Provenance.Trust | Should -Be "UntrustedEvidence"
            $snapshot.Provenance.ExecutableContent | Should -BeFalse
            $snapshot.Entries[0].Status | Should -Be "Verified"
            @($snapshot.Entries[0].PSObject.Properties.Name) | Should -Not -Contain "Raw"
        } finally {
            foreach ($path in @($beforePath,$afterPath)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    It "maps a newer nested undo manifest to restoration categories" {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("manifest-{0}.json" -f ([guid]::NewGuid().ToString("N")))
        try {
            $manifest = @{
                version="2"
                changes=@(@{
                    removedApps=@("Microsoft.WindowsStore")
                    disabledServices=@("DiagTrack")
                    disabledTasks=@("\Microsoft\Windows\WindowsUpdate\Scheduled Start")
                    registryChanges=@(@{Path="HKLM:\SOFTWARE\Policies\Microsoft\Edge"})
                })
            }
            $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path

            $result = Import-UndoManifest -ManifestPath $path

            $result.Success | Should -BeTrue
            $result.FormatVersion | Should -Be "2"
            $result.RelevantCategories | Should -Contain "chkAppx"
            $result.RelevantCategories | Should -Contain "chkServices"
            $result.RelevantCategories | Should -Contain "chkTasks"
        } finally {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }

    It "separates verified, malformed, and unsupported text evidence without retaining commands" {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("import-diagnostics-{0}.log" -f ([guid]::NewGuid().ToString("N")))
        try {
            @(
                'reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /d 0',
                'Add-AppxPackage -AllUsers',
                'Invoke-Expression "Remove-Item C:\unsafe"'
            ) | Set-Content -LiteralPath $path

            $result = Import-PrivacySexyCompensationLog -LogPath $path

            $result.Status | Should -Be "ImportedWithWarnings"
            $result.Operations.Count | Should -Be 1
            $result.UntrustedEntries.Count | Should -Be 1
            $result.UnsupportedEntries.Count | Should -BeGreaterThan 0
            $result.MalformedEntries.Count | Should -BeGreaterThan 0
            $result.UnsupportedEntries[0].Reason | Should -Not -BeNullOrEmpty
            $result.MalformedEntries[0].Reason | Should -Not -BeNullOrEmpty
            @($result.Operations[0].PSObject.Properties.Name) | Should -Not -Contain "Raw"
            $result.Operations[0].RawHash | Should -Not -BeNullOrEmpty
            $result.Provenance.Trust | Should -Be "UntrustedEvidence"
            $result.Provenance.ExecutableContent | Should -BeFalse
        } finally {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }

    It "rejects missing and unsupported manifest schema versions with distinct diagnostics" {
        $missingVersionPath = Join-Path ([System.IO.Path]::GetTempPath()) ("manifest-no-version-{0}.json" -f ([guid]::NewGuid().ToString("N")))
        $unsupportedVersionPath = Join-Path ([System.IO.Path]::GetTempPath()) ("manifest-unsupported-version-{0}.json" -f ([guid]::NewGuid().ToString("N")))
        try {
            @{ changes=@(@{ disabledServices=@("DiagTrack") }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $missingVersionPath
            @{ version="9"; changes=@(@{ disabledServices=@("DiagTrack") }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $unsupportedVersionPath

            $missing = Import-UndoManifest -ManifestPath $missingVersionPath
            $unsupported = Import-UndoManifest -ManifestPath $unsupportedVersionPath

            $missing.Status | Should -Be "Rejected"
            $missing.MalformedEntries.Count | Should -BeGreaterThan 0
            $missing.MalformedEntries[0].Reason | Should -Match "version"
            $unsupported.Status | Should -Be "Rejected"
            $unsupported.UnsupportedEntries.Count | Should -BeGreaterThan 0
            $unsupported.UnsupportedEntries[0].Status | Should -Be "Unsupported"
        } finally {
            foreach ($path in @($missingVersionPath,$unsupportedVersionPath)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    It "enforces bounded text, JSON depth, and item counts" {
        $oversizedPath = Join-Path ([System.IO.Path]::GetTempPath()) ("import-oversized-{0}.log" -f ([guid]::NewGuid().ToString("N")))
        $deepPath = Join-Path ([System.IO.Path]::GetTempPath()) ("manifest-deep-{0}.json" -f ([guid]::NewGuid().ToString("N")))
        $manyPath = Join-Path ([System.IO.Path]::GetTempPath()) ("manifest-many-{0}.json" -f ([guid]::NewGuid().ToString("N")))
        try {
            ("x" * ($script:ExternalImportMaxLineBytes + 1)) | Set-Content -LiteralPath $oversizedPath
            $deep = @{ version="2"; child=@{} }
            $cursor = $deep.child
            for ($i=0; $i -lt ($script:ExternalImportMaxDepth + 2); $i++) {
                $cursor.child = @{}
                $cursor = $cursor.child
            }
            $deep | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $deepPath
            $services = @(
                for ($i=0; $i -lt ($script:ExternalImportMaxItems + 1); $i++) { "Svc$i" }
            )
            @{ version="2"; services=$services } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manyPath

            $oversized = Import-PrivacySexyCompensationLog -LogPath $oversizedPath
            $deepResult = Import-UndoManifest -ManifestPath $deepPath
            $manyResult = Import-UndoManifest -ManifestPath $manyPath

            $oversized.Status | Should -Be "Rejected"
            $oversized.UnsupportedEntries.Count | Should -BeGreaterThan 0
            $deepResult.Status | Should -Be "Rejected"
            $deepResult.UnsupportedEntries[0].Reason | Should -Match "depth"
            $manyResult.Status | Should -Be "Rejected"
            $manyResult.UnsupportedEntries[0].Reason | Should -Match "item"
        } finally {
            foreach ($path in @($oversizedPath,$deepPath,$manyPath)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}

Describe "Restore-WindowsDefaults baseline catalog contracts" {
    BeforeAll {
        $baselineProfile = [pscustomobject]@{
            ProductFamily="Windows 11"; Edition="Professional"; Build=26100
        }
    }

    It "publishes provenance and scope metadata for every built-in catalog entry" {
        $report = Get-RestoreBaselineCatalogReport -MachineProfile $baselineProfile

        $report.SchemaVersion | Should -Be 1
        $report.CatalogVersion | Should -Be "rwd-baseline-1.0"
        $report.Status | Should -Be "Ready"
        $report.Warnings.Count | Should -Be 0
        $report.Entries.Count | Should -BeGreaterThan 0
        @($report.Entries | Where-Object { $_.CatalogVersion -ne "rwd-baseline-1.0" }).Count | Should -Be 0
        @($report.Entries | Where-Object { [string]::IsNullOrWhiteSpace($_.SourceUrl) -and [string]::IsNullOrWhiteSpace($_.PolicyMapping) }).Count | Should -Be 0
        @($report.Entries | Where-Object { [string]::IsNullOrWhiteSpace($_.SupportedBuildRange) -or $_.SupportedEditions.Count -eq 0 -or [string]::IsNullOrWhiteSpace($_.Confidence) }).Count | Should -Be 0
        @($report.Entries | Where-Object { -not $_.CanAutoFix }).Count | Should -Be 0
    }

    It "marks custom and out-of-range catalog entries as warnings without auto-fix eligibility" {
        $custom = @(@{Name="Unversioned policy";Path="HKCU:\Software\Restore-WindowsDefaults-Test";ValueName="Missing";Action="Remove";Category="chkMisc"})
        $unknown = @(Get-RegistryDefaultBaselineReport -Catalog $custom -MachineProfile $baselineProfile)
        $unsupportedProfile = [pscustomobject]@{ProductFamily="Windows 11";Edition="Professional";Build=21999}
        $outOfRange = @(Get-RegistryDefaultBaselineReport -Catalog @($script:RegistryDefaultCatalog[0]) -MachineProfile $unsupportedProfile)

        $unknown[0].CatalogStatus | Should -Be "Unknown"
        $unknown[0].CanAutoFix | Should -BeFalse
        $unknown[0].Warning | Should -Match "missing"
        $outOfRange[0].CatalogStatus | Should -Be "Unsupported"
        $outOfRange[0].CanAutoFix | Should -BeFalse
        $outOfRange[0].Warning | Should -Match "outside"
    }

    It "reports provenance for supported AppX findings and warns on unversioned baselines" {
        $known = Get-AppxPackageRemovalReport -ExpectedPackages @($script:CoreAppxPackageCatalog[0]) -InstalledPackages @() -ProvisionedPackages @() -MachineProfile $baselineProfile
        $unknown = Get-AppxPackageRemovalReport -ExpectedPackages @(@{Name="Custom.Package";Role="Core"}) -InstalledPackages @() -ProvisionedPackages @() -MachineProfile $baselineProfile

        $known.Findings[0].CatalogStatus | Should -Be "Verified"
        $known.Findings[0].SourceUrl | Should -Match "release-health"
        $known.Findings[0].Confidence | Should -Be "High"
        $unknown.CatalogStatus | Should -Be "Warnings"
        $unknown.CanAutoFix | Should -BeFalse
        $unknown.Findings[0].Warning | Should -Match "missing"
    }
}

Describe "Restore-WindowsDefaults planning helpers" {
    It "creates an impact preview for selected categories" {
        $health = [ordered]@{
            Security=@{FixKeys=@("chkDefender");IssueCount=2;Details=@("a","b");Severity="Critical"}
            Privacy=@{FixKeys=@("chkPrivacy");IssueCount=0;Details=@();Severity="OK"}
        }

        $preview = @(Get-RestoreImpactPreview -SelectedKeys @("chkDefender","chkPrivacy") -HealthReport $health)

        ($preview | Where-Object FixKey -eq "chkDefender").DetectedIssueCount | Should -Be 2
        ($preview | Where-Object FixKey -eq "chkDefender").Severity | Should -Be "Critical"
        ($preview | Where-Object FixKey -eq "chkPrivacy").HasDetectedIssue | Should -BeFalse
    }

    It "builds a missing task re-import plan from injectable state" {
        $matrix = @(@{Source="Test";Tools=@("TestTool");P="\Test\";N="TaskOne";Category="chkTasks"})
        $taskProvider = { param($path,$name) throw "missing" }
        $fileProvider = { param($path) $true }

        $plan = @(Get-MissingTaskRegistrationPlan -Matrix $matrix -TaskProvider $taskProvider -FileExistsProvider $fileProvider)

        $plan.Count | Should -Be 1
        $plan[0].TaskName | Should -Be "\Test\TaskOne"
    }

    It "evaluates a custom safe-default catalog without changing state" {
        $catalog = @(@{Name="Missing policy";Path="HKCU:\Software\Restore-WindowsDefaults-Test";ValueName="Missing";Action="Remove";Category="chkMisc"})

        $report = @(Get-RegistryDefaultBaselineReport -Catalog $catalog)

        $report.Count | Should -Be 1
        $report[0].IsDefault | Should -BeTrue
        $report[0].Action | Should -Be "Remove"
    }

    It "keeps the restore function map aligned with the new operational categories" {
        $map = Get-RestoreFunctionMap

        $map.ContainsKey("chkSearchIndexer") | Should -BeTrue
        $map.ContainsKey("chkStoreChain") | Should -BeTrue
        $map.ContainsKey("chkAccount") | Should -BeTrue
        $map.ContainsKey("chkGroupPolicy") | Should -BeTrue
        $map.ContainsKey("chkDefenderCpuCap") | Should -BeTrue
    }
}

Describe "Restore-WindowsDefaults capability gates" {
    BeforeAll {
        $capabilityManagement = [pscustomobject]@{ IsManaged=$false; IsKnown=$true; DomainJoined=$false; MdmEnrolled=$false }
        $capabilityProvider = {
            [pscustomobject]@{
                ProductName="Windows 11 Pro"; ProductFamily="Windows 11"; EditionID="Professional"
                DisplayVersion="25H2"; CurrentBuild=26100; Architecture="AMD64"; Locale="en-US"
                IsWindows=$true; IsOnline=$true; PowerShellMajor=5; IsWindowsPowerShell=$true; IsAdministrator=$true
            }
        }
    }

    It "records a complete machine profile for a supported build" {
        $profile = Get-RestoreMachineProfile -OperatingSystemProvider $capabilityProvider -ManagementState $capabilityManagement

        $profile.Status | Should -Be "Ready"
        $profile.ProductFamily | Should -Be "Windows 11"
        $profile.Build | Should -Be 26100
        $profile.Architecture | Should -Be "x64"
        $profile.Locale | Should -Be "en-US"
        $profile.Management.IsKnown | Should -BeTrue
    }

    It "declares capabilities for every restore function map entry" {
        $map = Get-RestoreFunctionMap
        $catalog = Get-RestoreCapabilityCatalog -FunctionMap $map

        $catalog.Keys.Count | Should -Be $map.Keys.Count
        foreach ($key in $map.Keys) {
            $catalog.Contains($key) | Should -BeTrue
            @($catalog[$key].SupportedProductFamilies).Count | Should -BeGreaterThan 0
            @($catalog[$key].SupportedArchitectures).Count | Should -BeGreaterThan 0
            $catalog[$key].RequiresAdministrator | Should -BeTrue
        }
    }

    It "fails closed when the machine profile is incomplete" {
        $unknownProvider = { [pscustomobject]@{ ProductName="Windows 11 Pro"; IsWindows=$true; IsOnline=$true } }
        $profile = Get-RestoreMachineProfile -OperatingSystemProvider $unknownProvider -ManagementState $capabilityManagement
        $evaluations = @(Get-RestoreCapabilityEvaluation -SelectedKeys @("chkDefender","chkTheme") -MachineProfile $profile)

        $profile.Status | Should -Be "Unknown"
        @($evaluations | Where-Object CanMutate).Count | Should -Be 0
        @($evaluations | Where-Object Status -eq "Unknown").Count | Should -Be 2
        ($evaluations | Select-Object -First 1).Reason | Should -Match "unknown"
    }

    It "preserves organization-owned categories by default" {
        $managed = [pscustomobject]@{ IsManaged=$true; IsKnown=$true; DomainJoined=$true; MdmEnrolled=$false }
        $profile = Get-RestoreMachineProfile -OperatingSystemProvider $capabilityProvider -ManagementState $managed
        $evaluations = @(Get-RestoreCapabilityEvaluation -SelectedKeys @("chkWindowsUpdate","chkTheme") -MachineProfile $profile)

        ($evaluations | Where-Object Key -eq "chkWindowsUpdate").Status | Should -Be "OrganizationOwned"
        ($evaluations | Where-Object Key -eq "chkWindowsUpdate").CanMutate | Should -BeFalse
        ($evaluations | Where-Object Key -eq "chkTheme").CanMutate | Should -BeTrue
    }
}

Describe "Restore-WindowsDefaults action plans" {
    BeforeAll {
        $planManagement = [pscustomobject]@{ IsManaged=$false; IsKnown=$true; DomainJoined=$false; MdmEnrolled=$false }
        $planProvider = {
            [pscustomobject]@{
                ProductName="Windows 11 Pro"; ProductFamily="Windows 11"; EditionID="Professional"
                DisplayVersion="25H2"; CurrentBuild=26100; Architecture="AMD64"; Locale="en-US"
                IsWindows=$true; IsOnline=$true; PowerShellMajor=5; IsWindowsPowerShell=$true; IsAdministrator=$true
            }
        }
        $planProfile = Get-RestoreMachineProfile -OperatingSystemProvider $planProvider -ManagementState $planManagement
    }

    It "emits a versioned plan with exact registry, service, file, and command state" {
        $plan = Get-RestoreActionPlan -SelectedKeys @("chkDefender") -MachineProfile $planProfile

        $plan.SchemaVersion | Should -Be 1
        $plan.Status | Should -Be "Ready"
        $plan.ExecutionAllowed | Should -BeTrue
        $plan.PlanHash | Should -Match '^[a-f0-9]{64}$'
        $plan.ExactOperationCount | Should -BeGreaterThan 0
        $plan.OpaqueOperationCount | Should -Be 0
        @($plan.Operations | Where-Object Kind -eq "RegistryValue").Count | Should -BeGreaterThan 0
        @($plan.Operations | Where-Object Kind -eq "Service").Count | Should -BeGreaterThan 0
        ($plan.Operations | Where-Object Kind -eq "RegistryValue" | Select-Object -First 1).PSObject.Properties.Name | Should -Contain "Before"
        foreach ($operation in $plan.Operations) {
            [string]::IsNullOrWhiteSpace([string]$operation.Scope) | Should -BeFalse
            [string]::IsNullOrWhiteSpace([string]$operation.Risk) | Should -BeFalse
            [string]::IsNullOrWhiteSpace([string]$operation.RollbackAction) | Should -BeFalse
            [string]::IsNullOrWhiteSpace([string]$operation.Dependency) | Should -BeFalse
            [string]::IsNullOrWhiteSpace([string]$operation.Verification) | Should -BeFalse
        }
    }

    It "allows a fully represented registry category to execute its plan" {
        $plan = Get-RestoreActionPlan -SelectedKeys @("chkBing") -MachineProfile $planProfile

        $plan.Status | Should -Be "Ready"
        $plan.ExecutionAllowed | Should -BeTrue
        $plan.OpaqueOperationCount | Should -Be 0
        @($plan.Operations | Where-Object { $_.Kind -eq "RegistryValue" -and $_.Exact }).Count | Should -BeGreaterThan 0
    }

    It "keeps an unknown profile non-executable in the plan" {
        $unknownProvider = { [pscustomobject]@{ ProductName="Windows 11 Pro"; IsWindows=$true; IsOnline=$true } }
        $unknownProfile = Get-RestoreMachineProfile -OperatingSystemProvider $unknownProvider -ManagementState $planManagement
        $plan = Get-RestoreActionPlan -SelectedKeys @("chkDefender") -MachineProfile $unknownProfile

        $plan.Status | Should -Be "Blocked"
        $plan.ExecutionAllowed | Should -BeFalse
        @($plan.Operations | Where-Object Kind -eq "CapabilityGate").Count | Should -Be 1
        @($plan.Operations | Where-Object CanExecute).Count | Should -Be 0
    }

    It "keeps registry helpers mutation-free under WhatIf and captures the intended state" {
        $path = "HKCU:\Software\Restore-WindowsDefaults-WhatIf-$([guid]::NewGuid().ToString('N'))"
        try {
            $script:ActionPlanCapture = $true
            $script:CapturedActionOperations = New-Object System.Collections.Generic.List[object]
            $script:CurrentCategory = "chkTest"
            Set-RegistryValue -Path $path -Name "TestValue" -Value 1 -Type DWord | Should -BeFalse

            Test-Path -LiteralPath $path | Should -BeFalse
            $script:CapturedActionOperations.Count | Should -Be 1
            $script:CapturedActionOperations[0].Action | Should -Be "Set"
            $script:CapturedActionOperations[0].After.Exists | Should -BeTrue
        } finally {
            $script:ActionPlanCapture = $false
            $script:CurrentCategory = ""
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It "routes ready plan operations through the mutation primitives" {
        $path = "HKCU:\Software\Restore-WindowsDefaults-PlanExecutor-$([guid]::NewGuid().ToString('N'))"
        $plan = [pscustomobject]@{
            Operations=@([pscustomobject]@{
                OperationId="test-0001"; CategoryKey="chkTest"; Kind="RegistryValue"; Action="Set"
                Target="$path\Value"; CanExecute=$true
                Before=[pscustomobject]@{Exists=$false;Path=$path;Name="Value";Type=$null;Value=$null}
                After=[pscustomobject]@{Exists=$true;Path=$path;Name="Value";Type="DWord";Value=1}
            })
        }
        try {
            $script:ActionPlanCapture = $true
            $script:CapturedActionOperations = New-Object System.Collections.Generic.List[object]
            $result = Invoke-RestoreActionPlan -ActionPlan $plan -CategoryKey "chkTest"

            $result.OperationCount | Should -Be 1
            $result.Changed | Should -Be 0
            $result.Errors | Should -Be 0
            $script:CapturedActionOperations.Count | Should -Be 1
            Test-Path -LiteralPath $path | Should -BeFalse
        } finally {
            $script:ActionPlanCapture = $false
            $script:CurrentCategory = ""
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe "Restore-WindowsDefaults management provenance" {
    It "returns structured domain, MDM, Group Policy, and dsreg evidence without raw output" {
        $domainProvider = { [pscustomobject]@{ PartOfDomain=$true } }
        $detectedPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Enrollments",
            "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\History"
        )
        $pathProvider = { param($path) $path -in $detectedPaths }
        $dsregProvider = { @("AzureAdJoined : YES","DomainJoined : YES","WorkplaceJoined : NO") }

        $state = Get-PolicyManagementState -DomainProvider $domainProvider -PathProvider $pathProvider -DsregProvider $dsregProvider

        $state.SchemaVersion | Should -Be 1
        $state.IsKnown | Should -BeTrue
        $state.IsManaged | Should -BeTrue
        $state.MdmEnrolled | Should -BeTrue
        $state.Ownership | Should -Be "Organization (Domain + MDM)"
        $state.Dsreg.Status | Should -Be "Parsed"
        @($state.Signals | Where-Object { $_.SignalType -eq "MdmEnrollment" -and $_.Detected }).Count | Should -BeGreaterThan 0
        @($state.Evidence | Where-Object { $_.Source -eq "Group Policy registry history" }).Count | Should -Be 1
        $state.Dsreg.RawOutputRetained | Should -BeFalse
        ($state.Dsreg.PSObject.Properties.Name -contains "RawOutput") | Should -BeFalse
    }

    It "labels unavailable or localized dsreg output as an explicit fallback" {
        $state = Get-PolicyManagementState -DomainProvider { $false } -PathProvider { param($path) $false } -DsregProvider { "EstadoDeAzure : SI" }

        $state.IsKnown | Should -BeTrue
        $state.IsManaged | Should -BeFalse
        $state.Dsreg.Status | Should -Be "Unparsed"
        $state.Dsreg.FallbackUsed | Should -BeTrue
        $state.Dsreg.Warning | Should -Match "fallback|recognized"
    }

    It "classifies managed policy provenance and records the operator override" {
        $managed = [pscustomobject]@{
            IsManaged=$true; IsKnown=$true; DomainJoined=$false; MdmEnrolled=$true
            Ownership="Organization (MDM)"; Evidence=@([pscustomobject]@{Source="MDM Policy CSP";Detected=$true})
        }
        $pathProvider = { param($path) [pscustomobject]@{Exists=$true;ValueNames=@("NoAutoUpdate") } }

        $preserved = Get-RestorePolicyProvenance -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -ValueName "NoAutoUpdate" -ManagementState $managed -PathProvider $pathProvider
        $override = Get-RestorePolicyProvenance -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -ValueName "NoAutoUpdate" -ManagementState $managed -AllowManagedPolicy -PathProvider $pathProvider

        $preserved.Source | Should -Be "MDM policy registry"
        $preserved.Ownership | Should -Be "Organization"
        $preserved.ManagementDecision | Should -Be "SkipByDefault"
        $preserved.CanMutate | Should -BeFalse
        $preserved.Reason | Should -Match "operator authority"
        $override.ManagementDecision | Should -Be "OverrideAllowed"
        $override.OperatorOverride | Should -BeTrue
        $override.CanMutate | Should -BeTrue
    }

    It "carries management evidence into capability reports and capability gates" {
        $management = [pscustomobject]@{
            IsManaged=$true; IsKnown=$true; DomainJoined=$true; MdmEnrolled=$false
            Ownership="Organization (Domain)"; Evidence=@([pscustomobject]@{Source="Win32_ComputerSystem";Detected=$true})
            Decision="SkipByDefault"
        }
        $osProvider = {
            [pscustomobject]@{
                ProductName="Windows 11 Pro"; ProductFamily="Windows 11"; EditionID="Professional"
                CurrentBuild=26100; Architecture="AMD64"; Locale="en-US"; IsWindows=$true; IsOnline=$true
                PowerShellMajor=5; IsWindowsPowerShell=$true; IsAdministrator=$true
            }
        }
        $profile = Get-RestoreMachineProfile -OperatingSystemProvider $osProvider -ManagementState $management
        $report = Get-RestoreCapabilityReport -SelectedKeys @("chkWindowsUpdate") -MachineProfile $profile
        $category = $report.Categories[0]
        $plan = Get-RestoreActionPlan -SelectedKeys @("chkWindowsUpdate") -MachineProfile $profile
        $gate = @($plan.Operations | Where-Object Kind -eq "CapabilityGate")[0]

        $report.ManagementDecision | Should -Be "SkipByDefault"
        $category.Status | Should -Be "OrganizationOwned"
        $category.ManagedPolicyDecision | Should -Be "SkippedByDefault"
        $category.OperatorOverride | Should -BeFalse
        @($category.ManagementEvidence).Count | Should -Be 1
        $plan.ManagedPolicyOverride | Should -BeFalse
        $gate.Metadata.ManagementDecision | Should -Be "SkippedByDefault"
        $gate.Metadata.OperatorOverride | Should -BeFalse
        $plan.Categories[0].PolicyOwnership | Should -Be "Organization (Domain)"
    }
}

Describe "Restore-WindowsDefaults rollback journals" {
    It "writes an atomic v2 journal with operation and whole-file integrity" {
        $journalPath = Join-Path ([System.IO.Path]::GetTempPath()) ("rwd-journal-{0}.json" -f ([guid]::NewGuid().ToString("N")))
        $plan = [pscustomobject]@{
            SchemaVersion=1; ToolVersion=$script:Version; PlanHash=('a' * 64); Profile=[pscustomobject]@{Status="Ready"}
            Operations=@([pscustomobject]@{
                OperationId="op-0001"; CategoryKey="chkTest"; Kind="RegistryValue"; Action="Set"; Target="HKCU:\Software\RwdJournalTest\Value"
                Scope="CurrentUser"; Risk="Low"; Before=[pscustomobject]@{Exists=$false;KeyExists=$false;Path="HKCU:\Software\RwdJournalTest";Name="Value";Type=$null;Value=$null}
                After=[pscustomobject]@{Exists=$true;Path="HKCU:\Software\RwdJournalTest";Name="Value";Type="DWord";Value=1}
                RollbackAction="Restore before state"; Exact=$true; CanExecute=$true; Reason=$null; Source="test"; Dependency="test"; Verification="value exists"; Metadata=$null
            })
        }
        try {
            $created = New-RestoreRollbackJournal -ActionPlan $plan -SelectedKeys @("chkTest") -OutputPath $journalPath -BeforeRegistry ([pscustomobject]@{SchemaVersion=1;Entries=@()})
            $created | Should -Be $journalPath
            $journal = Read-RestoreRollbackJournal -Path $journalPath

            $journal.SchemaVersion | Should -Be 2
            $journal.State | Should -Be "Prepared"
            $journal.PlanHash | Should -Be ('a' * 64)
            $journal.Integrity.Algorithm | Should -Be "SHA256"
            $journal.Integrity.JournalHash | Should -Match '^[a-f0-9]{64}$'
            $journal.Operations[0].OperationId | Should -Be "op-0001"
            $journal.Operations[0].OperationHash | Should -Match '^[a-f0-9]{64}$'
            @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetDirectoryName($journalPath)) -Filter (([System.IO.Path]::GetFileName($journalPath)) + ".tmp-*") -File -ErrorAction SilentlyContinue).Count | Should -Be 0
            @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetDirectoryName($journalPath)) -Filter (([System.IO.Path]::GetFileName($journalPath)) + ".bak-*") -File -ErrorAction SilentlyContinue).Count | Should -Be 0
        } finally {
            if (Test-Path -LiteralPath $journalPath) { Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue }
        }
    }

    It "round-trips a registry value and removes a key created by the plan" {
        $keyPath = "HKCU:\Software\RwdJournalRegistry-$([guid]::NewGuid().ToString('N'))"
        $journalPath = Join-Path ([System.IO.Path]::GetTempPath()) ("rwd-registry-journal-{0}.json" -f ([guid]::NewGuid().ToString("N")))
        $plan = [pscustomobject]@{
            PlanHash=('b' * 64); Profile=[pscustomobject]@{Status="Ready"}
            Operations=@([pscustomobject]@{
                OperationId="op-0001"; CategoryKey="chkTest"; Kind="RegistryValue"; Action="Set"; Target="$keyPath\Value"; Scope="CurrentUser"; Risk="Low"
                Before=[pscustomobject]@{Exists=$false;KeyExists=$false;Path=$keyPath;Name="Value";Type=$null;Value=$null}
                After=[pscustomobject]@{Exists=$true;Path=$keyPath;Name="Value";Type="DWord";Value=7}
                RollbackAction="Restore before state"; Exact=$true; CanExecute=$true; Reason=$null; Source="test"; Dependency="test"; Verification="value exists"; Metadata=$null
            })
        }
        $oldSnapshotPaths = $script:RegistrySnapshotPaths
        $script:RegistrySnapshotPaths = @()
        try {
            New-RestoreRollbackJournal -ActionPlan $plan -SelectedKeys @("chkTest") -OutputPath $journalPath -BeforeRegistry ([pscustomobject]@{SchemaVersion=1;Entries=@()}) | Out-Null
            $execution = Invoke-RestoreActionPlan -ActionPlan $plan -CategoryKey "chkTest"
            $execution.Errors | Should -Be 0
            (Get-ItemProperty -LiteralPath $keyPath -Name "Value").Value | Should -Be 7
            Update-RestoreRollbackJournal -Journal $script:ActiveRollbackJournal -JournalPath $journalPath -State "Committed" | Out-Null

            $rollback = Invoke-RestoreRollback -RollbackPath $journalPath
            $rollback.Success | Should -BeTrue
            $rollback.State | Should -Be "RolledBack"
            (Test-Path -LiteralPath $keyPath) | Should -BeFalse
            (Read-RestoreRollbackJournal -Path $journalPath).Operations[0].JournalStatus | Should -Be "RolledBack"
            (Read-RestoreRollbackJournal -Path $journalPath).Operations[0].RollbackStatus | Should -Be "RolledBack"
        } finally {
            $script:RegistrySnapshotPaths = $oldSnapshotPaths
            if (Test-Path -LiteralPath $keyPath) { Remove-Item -LiteralPath $keyPath -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $journalPath) { Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue }
        }
    }

    It "round-trips supported inline file bytes" {
        $filePath = Join-Path ([System.IO.Path]::GetTempPath()) ("rwd-file-{0}.txt" -f ([guid]::NewGuid().ToString("N")))
        $journalPath = Join-Path ([System.IO.Path]::GetTempPath()) ("rwd-file-journal-{0}.json" -f ([guid]::NewGuid().ToString("N")))
        $beforeText = "before content`r`n"
        $afterText = "after content`r`n"
        [System.IO.File]::WriteAllText($filePath, $beforeText, [System.Text.UTF8Encoding]::new($false))
        $oldSnapshotPaths = $script:RegistrySnapshotPaths
        $script:RegistrySnapshotPaths = @()
        try {
            $script:ActionPlanCapture = $true
            $script:CapturedActionOperations = New-Object System.Collections.Generic.List[object]
            $script:CurrentCategory = "chkTest"
            Invoke-RestoreTextFileMutation -Path $filePath -Content $afterText -Scope "CurrentUser" -Silent | Should -BeFalse
            $captured = $script:CapturedActionOperations[0]
            $script:ActionPlanCapture = $false
            $script:CurrentCategory = ""
            $plan = [pscustomobject]@{PlanHash=('c' * 64);Profile=[pscustomobject]@{Status="Ready"};Operations=@([pscustomobject]@{
                OperationId="op-0001"; CategoryKey="chkTest"; Kind=$captured.Kind; Action=$captured.Action; Target=$captured.Target; Scope=$captured.Scope; Risk="Low"
                Before=$captured.Before; After=$captured.After; RollbackAction=$captured.RollbackAction; Exact=$true; CanExecute=$true; Reason=$captured.Reason; Source="test"; Dependency="test"; Verification=$captured.Verification; Metadata=$captured.Metadata
            })}
            New-RestoreRollbackJournal -ActionPlan $plan -SelectedKeys @("chkTest") -OutputPath $journalPath -BeforeRegistry ([pscustomobject]@{SchemaVersion=1;Entries=@()}) | Out-Null
            $execution = Invoke-RestoreActionPlan -ActionPlan $plan -CategoryKey "chkTest"
            $execution.Errors | Should -Be 0
            [System.IO.File]::ReadAllText($filePath) | Should -Be $afterText
            Update-RestoreRollbackJournal -Journal $script:ActiveRollbackJournal -JournalPath $journalPath -State "Committed" | Out-Null

            $rollback = Invoke-RestoreRollback -RollbackPath $journalPath
            $rollback.Success | Should -BeTrue
            [System.IO.File]::ReadAllText($filePath) | Should -Be $beforeText
        } finally {
            $script:RegistrySnapshotPaths = $oldSnapshotPaths
            $script:ActionPlanCapture = $false
            $script:CurrentCategory = ""
            if (Test-Path -LiteralPath $filePath) { Remove-Item -LiteralPath $filePath -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $journalPath) { Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue }
        }
    }

    It "rejects a tampered journal before touching the restored state" {
        $keyPath = "HKCU:\Software\RwdJournalTamper-$([guid]::NewGuid().ToString('N'))"
        $journalPath = Join-Path ([System.IO.Path]::GetTempPath()) ("rwd-tamper-journal-{0}.json" -f ([guid]::NewGuid().ToString("N")))
        $plan = [pscustomobject]@{
            PlanHash=('d' * 64); Profile=[pscustomobject]@{Status="Ready"}
            Operations=@([pscustomobject]@{
                OperationId="op-0001"; CategoryKey="chkTest"; Kind="RegistryValue"; Action="Set"; Target="$keyPath\Value"; Scope="CurrentUser"; Risk="Low"
                Before=[pscustomobject]@{Exists=$false;KeyExists=$false;Path=$keyPath;Name="Value";Type=$null;Value=$null}
                After=[pscustomobject]@{Exists=$true;Path=$keyPath;Name="Value";Type="DWord";Value=9}
                RollbackAction="Restore before state"; Exact=$true; CanExecute=$true; Reason=$null; Source="test"; Dependency="test"; Verification="value exists"; Metadata=$null
            })
        }
        $oldSnapshotPaths = $script:RegistrySnapshotPaths
        $script:RegistrySnapshotPaths = @()
        try {
            New-RestoreRollbackJournal -ActionPlan $plan -SelectedKeys @("chkTest") -OutputPath $journalPath -BeforeRegistry ([pscustomobject]@{SchemaVersion=1;Entries=@()}) | Out-Null
            Invoke-RestoreActionPlan -ActionPlan $plan -CategoryKey "chkTest" | Out-Null
            (Get-ItemProperty -LiteralPath $keyPath -Name "Value").Value | Should -Be 9
            Update-RestoreRollbackJournal -Journal $script:ActiveRollbackJournal -JournalPath $journalPath -State "Committed" | Out-Null
            $tampered = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
            $tampered.PlanHash = ('e' * 64)
            $tampered | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $journalPath -Encoding UTF8

            { Read-RestoreRollbackJournal -Path $journalPath } | Should -Throw
            { Invoke-RestoreRollback -RollbackPath $journalPath } | Should -Throw
            (Get-ItemProperty -LiteralPath $keyPath -Name "Value").Value | Should -Be 9
        } finally {
            $script:RegistrySnapshotPaths = $oldSnapshotPaths
            if (Test-Path -LiteralPath $keyPath) { Remove-Item -LiteralPath $keyPath -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $journalPath) { Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue }
        }
    }

    It "resumes a prepared journal and commits its pending operation" {
        $keyPath = "HKCU:\Software\RwdJournalResume-$([guid]::NewGuid().ToString('N'))"
        $journalPath = Join-Path ([System.IO.Path]::GetTempPath()) ("rwd-resume-journal-{0}.json" -f ([guid]::NewGuid().ToString("N")))
        $plan = [pscustomobject]@{
            PlanHash=('f' * 64); Profile=[pscustomobject]@{Status="Ready"}
            Operations=@([pscustomobject]@{
                OperationId="op-0001"; CategoryKey="chkTest"; Kind="RegistryValue"; Action="Set"; Target="$keyPath\Value"; Scope="CurrentUser"; Risk="Low"
                Before=[pscustomobject]@{Exists=$false;KeyExists=$false;Path=$keyPath;Name="Value";Type=$null;Value=$null}
                After=[pscustomobject]@{Exists=$true;Path=$keyPath;Name="Value";Type="DWord";Value=11}
                RollbackAction="Restore before state"; Exact=$true; CanExecute=$true; Reason=$null; Source="test"; Dependency="test"; Verification="value exists"; Metadata=$null
            })
        }
        $oldSnapshotPaths = $script:RegistrySnapshotPaths
        $script:RegistrySnapshotPaths = @()
        try {
            New-RestoreRollbackJournal -ActionPlan $plan -SelectedKeys @("chkTest") -OutputPath $journalPath -BeforeRegistry ([pscustomobject]@{SchemaVersion=1;Entries=@()}) | Out-Null
            $resumed = Resume-RestoreRollbackJournal -JournalPath $journalPath
            $resumed.Success | Should -BeTrue
            $resumed.State | Should -Be "Committed"
            (Get-ItemProperty -LiteralPath $keyPath -Name "Value").Value | Should -Be 11
            (Read-RestoreRollbackJournal -Path $journalPath).Operations[0].JournalStatus | Should -Be "Completed"
        } finally {
            $script:RegistrySnapshotPaths = $oldSnapshotPaths
            if (Test-Path -LiteralPath $keyPath) { Remove-Item -LiteralPath $keyPath -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $journalPath) { Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe "Restore-WindowsDefaults native outcomes and verification" {
    It "classifies native success, stderr failures, and unavailable executables" {
        $success = Invoke-RestoreNativeCommand -FilePath "cmd.exe" -ArgumentList @("/c","exit","0") -Silent
        $failure = Invoke-RestoreNativeCommand -FilePath "cmd.exe" -ArgumentList @("/c","echo native-error 1>&2 & exit /b 7") -ExpectedExitCodes @(0) -Silent
        $unsupported = Invoke-RestoreNativeCommand -FilePath "rwd-missing-native-command.exe" -Silent

        $success.Status | Should -Be "Changed"
        $success.ExitCode | Should -Be 0
        $success.Success | Should -BeTrue
        $failure.Status | Should -Be "Failed"
        $failure.ExitCode | Should -Be 7
        $failure.FailureCategory | Should -Be "UnexpectedExitCode"
        $failure.FailureReason | Should -Match "unexpected exit code"
        $failure.Stderr | Should -Match "native-error"
        $unsupported.Status | Should -Be "Unsupported"
        $unsupported.FailureCategory | Should -Be "ExecutableUnavailable"
        $success.PendingRebootState.SchemaVersion | Should -Be 1
    }

    It "reports native failures as action-plan errors instead of verified no-change" {
        $plan = [pscustomobject]@{
            Operations=@([pscustomobject]@{
                OperationId="native-0001"; CategoryKey="chkTest"; Kind="NativeCommand"; Action="Execute"; Target="cmd.exe /c exit 9"
                Scope="Machine"; CanExecute=$true; Before=[pscustomobject]@{Executable="cmd.exe";Arguments=@("/c","exit","9");ExitCode=$null;Observed=$true}
                After=[pscustomobject]@{ExpectedExitCodes=@(0);RequiresReboot=$false;Completed=$true}
                Metadata=[pscustomobject]@{FilePath="cmd.exe";ArgumentList=@("/c","exit","9");ExpectedExitCodes=@(0);RequiresReboot=$false}
            })
        }
        $result = Invoke-RestoreActionPlan -ActionPlan $plan -CategoryKey "chkTest"

        $result.Status | Should -Be "Error"
        $result.Errors | Should -Be 1
        $result.Operations[0].Status | Should -Be "Failed"
        $result.Operations[0].ExitCode | Should -Be 9
        $result.Operations[0].FailureCategory | Should -Be "UnexpectedExitCode"
        $result.Operations[0].FailureReason | Should -Match "unexpected exit code"
        @($result.PendingRebootState.Signals).Count | Should -BeGreaterThan 0
    }

    It "freshly verifies a registry postcondition after plan execution" {
        $path = "HKCU:\Software\RwdIndependentVerification-$([guid]::NewGuid().ToString('N'))"
        $plan = [pscustomobject]@{
            Operations=@([pscustomobject]@{
                OperationId="registry-0001"; CategoryKey="chkTest"; Kind="RegistryValue"; Action="Set"; Target="$path\Value"
                Scope="CurrentUser"; CanExecute=$true; Before=[pscustomobject]@{Exists=$false;KeyExists=$false;Path=$path;Name="Value";Type=$null;Value=$null}
                After=[pscustomobject]@{Exists=$true;Path=$path;Name="Value";Type="DWord";Value=19}
            })
        }
        try {
            $result = Invoke-RestoreActionPlan -ActionPlan $plan -CategoryKey "chkTest"
            $result.Errors | Should -Be 0
            $result.Operations[0].Verification.Status | Should -Be "Verified"
            $result.Operations[0].Verification.FreshRead | Should -BeTrue
            $report = Get-RestoreIndependentPostRunVerification -ActionPlan $plan
            $report.Status | Should -Be "Verified"
            $report.VerifiedCount | Should -Be 1
            $report.Independent | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It "reports a pending reboot from injected structured signals" {
        $pending = Get-RestorePendingRebootState -Provider { param($path) $path -match "Component Based Servicing" }

        $pending.PendingReboot | Should -BeTrue
        $pending.Status | Should -Be "Pending"
        @($pending.Signals | Where-Object { $_.Detected }).Count | Should -Be 1
        $pending.Signals[0].PSObject.Properties.Name | Should -Contain "EvidenceType"
    }
}
