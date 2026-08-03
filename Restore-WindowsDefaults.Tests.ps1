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
