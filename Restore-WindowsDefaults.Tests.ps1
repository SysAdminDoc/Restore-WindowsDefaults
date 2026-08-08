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
