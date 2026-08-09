#Requires -Version 5.1

param(
    [switch]$NoGui,
    [switch]$NoElevation,
    [string]$ExportSnapshot,
    [string]$CompareSnapshot,
    [switch]$SecurityReset,
    [switch]$RebuildSearch,
    [switch]$ScheduleRestore,
    [switch]$ResumeScheduledRestore,
    [switch]$ResumeRestoreJournal,
    [switch]$RollbackLastRun,
    [string]$RestoreCategories,
    [ValidateSet("Quick","Full","Nuclear")][string]$RestoreTier,
    [switch]$PostUpdateCheck,
    [string]$ExportSupportBundle,
    [switch]$CapabilityReport,
    [switch]$BaselineReport,
    [switch]$AllowManagedPolicy,
    [switch]$WhatIf,
    [string]$PlanPath,
    [string[]]$RemoteComputerName,
    [string]$RemoteScriptPath
)

<#
.SYNOPSIS
    Windows Restore Tool v4.4
    Restores Windows to factory default settings after debloat scripts,
    privacy.sexy tweaks, group policy modifications, and registry changes.

.DESCRIPTION
    One-click tool to fix Windows PCs broken by debloat/privacy scripts.
    Features: pre-scan diagnostics, preset fix modes, and detailed reporting.
    Run with Administrator privileges. Creates a detailed log on your Desktop.

.NOTES
    Author: SysAdminDoc
    Version: 4.4.0
    Requires: Administrator privileges
#>

# ============================================================================
# CONFIGURATION
# ============================================================================

$script:Version = "4.4.0"
$script:CapabilitySchemaVersion = 1
$script:CapabilityProfile = $null
$script:CapabilityEvaluations = @()
$script:CapabilityExitCode = 0
$script:ManagedPolicyOverrideRequested = [bool]$AllowManagedPolicy
$script:WhatIfRequested = [bool]$WhatIf
$script:ActionPlanSchemaVersion = 1
$script:LastActionPlan = $null
$script:ActionPlanCapture = $false
$script:CapturedActionOperations = New-Object System.Collections.Generic.List[object]
$script:RollbackJournalSchemaVersion = 2
$script:RollbackJournalMaxEntries = 10
$script:RollbackJournalMaxBytes = 50MB
$script:RollbackInlineFileBytes = 4MB
$script:ActiveRollbackJournalPath = $null
$script:ActiveRollbackJournal = $null
$script:ExternalImportSchemaVersion = 2
$script:ExternalImportMaxBytes = 2MB
$script:ExternalImportMaxLines = 5000
$script:ExternalImportMaxLineBytes = 16KB
$script:ExternalImportMaxItems = 1000
$script:ExternalImportMaxDepth = 12
$script:BaselineCatalogSchemaVersion = 1
$script:BaselineCatalogVersion = "rwd-baseline-1.0"
$script:BaselineCatalogSourceUrl = "https://github.com/SysAdminDoc/Restore-WindowsDefaults"
$script:BaselinePolicySourceUrl = "https://learn.microsoft.com/en-us/windows/security/operating-system-security/device-management/windows-security-configuration-framework/security-compliance-toolkit-10"
$script:BaselineAppxSourceUrl = "https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information"
$script:BaselineSupportedProductFamilies = @("Windows 10","Windows 11")
$script:BaselineSupportedEditions = @("Core","CoreSingleLanguage","Home","Professional","ProfessionalN","ProfessionalWorkstation","Enterprise","EnterpriseN","Education","EducationN","IoTEnterprise","IoTEnterpriseS")
$script:BaselineBuildRangeByFamily = [ordered]@{
    "Windows 10" = [ordered]@{Minimum=19041;Maximum=$null}
    "Windows 11" = [ordered]@{Minimum=22000;Maximum=$null}
}
$script:BaselineBuildRangeLabel = "Windows 10 build 19041+; Windows 11 build 22000+"
$script:LogPath = "$env:USERPROFILE\Desktop\WindowsRestore_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:ChangesCount = 0
$script:ErrorsCount = 0
$script:SkippedCount = 0
# Per-category result tracking: key = category name, value = @{Status; Details; Changed; Errors}
$script:CategoryResults = [ordered]@{}
$script:CurrentCategory = ""


# ============================================================================
# SELF-ELEVATION (Forces Windows PowerShell 5.1 for WPF/Appx compatibility)
# ============================================================================

# PowerShell 7+ has broken Appx module and WPF quirks - force Windows PowerShell 5.1
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $ps5 = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $relaunchArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($NoGui) { $relaunchArgs += "-NoGui" }
    if ($NoElevation) { $relaunchArgs += "-NoElevation" }
    if ($ExportSnapshot) { $relaunchArgs += @("-ExportSnapshot", "`"$ExportSnapshot`"") }
    if ($CompareSnapshot) { $relaunchArgs += @("-CompareSnapshot", "`"$CompareSnapshot`"") }
    if ($SecurityReset) { $relaunchArgs += "-SecurityReset" }
    if ($RebuildSearch) { $relaunchArgs += "-RebuildSearch" }
    if ($ScheduleRestore) { $relaunchArgs += "-ScheduleRestore" }
    if ($ResumeScheduledRestore) { $relaunchArgs += "-ResumeScheduledRestore" }
    if ($ResumeRestoreJournal) { $relaunchArgs += "-ResumeRestoreJournal" }
    if ($RollbackLastRun) { $relaunchArgs += "-RollbackLastRun" }
    if ($RestoreCategories) { $relaunchArgs += @("-RestoreCategories", "`"$RestoreCategories`"") }
    if ($RestoreTier) { $relaunchArgs += @("-RestoreTier", $RestoreTier) }
    if ($PostUpdateCheck) { $relaunchArgs += "-PostUpdateCheck" }
    if ($ExportSupportBundle) { $relaunchArgs += @("-ExportSupportBundle", "`"$ExportSupportBundle`"") }
    if ($CapabilityReport) { $relaunchArgs += "-CapabilityReport" }
    if ($BaselineReport) { $relaunchArgs += "-BaselineReport" }
    if ($AllowManagedPolicy) { $relaunchArgs += "-AllowManagedPolicy" }
    if ($WhatIf) { $relaunchArgs += "-WhatIf" }
    if ($PlanPath) { $relaunchArgs += @("-PlanPath", "`"$PlanPath`"") }
    if ($RemoteComputerName) { $relaunchArgs += @("-RemoteComputerName", "`"$($RemoteComputerName -join ',')`"") }
    if ($RemoteScriptPath) { $relaunchArgs += @("-RemoteScriptPath", "`"$RemoteScriptPath`"") }
    Start-Process $ps5 -Verb RunAs -ArgumentList ($relaunchArgs -join " ")
    exit
}
# Self-elevate if not admin
if (-not $NoElevation -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $relaunchArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($NoGui) { $relaunchArgs += "-NoGui" }
    if ($ExportSnapshot) { $relaunchArgs += @("-ExportSnapshot", "`"$ExportSnapshot`"") }
    if ($CompareSnapshot) { $relaunchArgs += @("-CompareSnapshot", "`"$CompareSnapshot`"") }
    if ($SecurityReset) { $relaunchArgs += "-SecurityReset" }
    if ($RebuildSearch) { $relaunchArgs += "-RebuildSearch" }
    if ($ScheduleRestore) { $relaunchArgs += "-ScheduleRestore" }
    if ($ResumeScheduledRestore) { $relaunchArgs += "-ResumeScheduledRestore" }
    if ($ResumeRestoreJournal) { $relaunchArgs += "-ResumeRestoreJournal" }
    if ($RollbackLastRun) { $relaunchArgs += "-RollbackLastRun" }
    if ($RestoreCategories) { $relaunchArgs += @("-RestoreCategories", "`"$RestoreCategories`"") }
    if ($RestoreTier) { $relaunchArgs += @("-RestoreTier", $RestoreTier) }
    if ($PostUpdateCheck) { $relaunchArgs += "-PostUpdateCheck" }
    if ($ExportSupportBundle) { $relaunchArgs += @("-ExportSupportBundle", "`"$ExportSupportBundle`"") }
    if ($CapabilityReport) { $relaunchArgs += "-CapabilityReport" }
    if ($BaselineReport) { $relaunchArgs += "-BaselineReport" }
    if ($AllowManagedPolicy) { $relaunchArgs += "-AllowManagedPolicy" }
    if ($WhatIf) { $relaunchArgs += "-WhatIf" }
    if ($PlanPath) { $relaunchArgs += @("-PlanPath", "`"$PlanPath`"") }
    if ($RemoteComputerName) { $relaunchArgs += @("-RemoteComputerName", "`"$($RemoteComputerName -join ',')`"") }
    if ($RemoteScriptPath) { $relaunchArgs += @("-RemoteScriptPath", "`"$RemoteScriptPath`"") }
    Start-Process powershell -Verb RunAs -ArgumentList ($relaunchArgs -join " ")
    exit
}

# ============================================================================
# ASSEMBLY LOADING
# ============================================================================

if (-not $NoGui) {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
}

# ============================================================================
# HELPERS
# ============================================================================

# Safe wrapper for Get-AppxPackage (never throws, returns $null on failure)
function Get-AppxPackageSafe {
    param([string]$Name, [switch]$AllUsers)
    try {
        if ($AllUsers) { return @(Get-AppxPackage -AllUsers $Name -EA Stop) }
        else { return (Get-AppxPackage $Name -EA Stop) }
    } catch { return $null }
}

# ============================================================================
# LOGGING WITH RESULT TRACKING
# ============================================================================

$script:ConsoleBox = $null
$script:ConsoleWindow = $null

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Section')]
        [string]$Level = 'Info'
    )
    if ($script:ActionPlanCapture -or $script:WhatIfRequested) { return }
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logFull = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $script:LogPath -Value $logFull -ErrorAction SilentlyContinue

    # Track per-category stats
    if ($script:CurrentCategory -and $script:CategoryResults.Contains($script:CurrentCategory)) {
        switch ($Level) {
            'Success' { $script:CategoryResults[$script:CurrentCategory].Changed++ }
            'Error'   { $script:CategoryResults[$script:CurrentCategory].Errors++; $script:ErrorsCount++ }
        }
    } elseif ($Level -eq 'Error') { $script:ErrorsCount++ }

    switch ($Level) {
        'Success' { Write-Host $logFull -ForegroundColor Green }
        'Warning' { Write-Host $logFull -ForegroundColor Yellow }
        'Error'   { Write-Host $logFull -ForegroundColor Red }
        'Section' { Write-Host $logFull -ForegroundColor Magenta }
        default   { Write-Host $logFull -ForegroundColor Cyan }
    }

    # Push to GUI console
    if ($script:ConsoleBox -and $script:ConsoleWindow) {
        try {
            $colorMap = @{ Success='#6BCB77'; Warning='#FFD93D'; Error='#FF6B6B'; Section='#BB86FC'; Info='#8BB4CC' }
            $color = $colorMap[$Level]; if (!$color) { $color = '#8BB4CC' }
            $prefix = switch ($Level) { 'Success'{' + '};'Warning'{' ! '};'Error'{' X '};'Section'{'>> '};default{' . '} }
            $doc = $script:ConsoleBox.Document
            $para = New-Object System.Windows.Documents.Paragraph
            $para.Margin = [System.Windows.Thickness]::new(0)
            $para.LineHeight = 1
            $tsRun = New-Object System.Windows.Documents.Run("[$timestamp] ")
            $tsRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#555566')
            $para.Inlines.Add($tsRun) | Out-Null
            $pfxRun = New-Object System.Windows.Documents.Run($prefix)
            $pfxRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color)
            $pfxRun.FontWeight = [System.Windows.FontWeights]::SemiBold
            $para.Inlines.Add($pfxRun) | Out-Null
            $msgRun = New-Object System.Windows.Documents.Run($Message)
            $msgRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color)
            $para.Inlines.Add($msgRun) | Out-Null
            $doc.Blocks.Add($para) | Out-Null
            $script:ConsoleBox.ScrollToEnd()
            $script:ConsoleWindow.Dispatcher.Invoke([action]{}, "Render")
        } catch { }
    }
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Add-RestoreActionPlanOperation {
    param(
        [Parameter(Mandatory=$true)][string]$Kind,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$Target,
        [object]$Before,
        [object]$After,
        [string]$Scope="MachineAndUser",
        [string]$RollbackAction="Restore captured before state",
        [string]$Reason,
        [string]$Source="Mutation primitive",
        [bool]$CanExecute=$true,
        [string]$Risk="Medium",
        [string]$Dependency,
        [string]$Verification,
        [object]$Metadata
    )
    if (-not $script:ActionPlanCapture) { return }
    $operationNumber = $script:CapturedActionOperations.Count + 1
    $script:CapturedActionOperations.Add([pscustomobject][ordered]@{
        OperationId=("capture-{0:D4}" -f $operationNumber); CategoryKey=$script:CurrentCategory
        Kind=$Kind; Action=$Action; Target=$Target; Scope=$Scope; Before=$Before; After=$After
        RollbackAction=$RollbackAction; Exact=$true; CanExecute=$CanExecute; Reason=$Reason; Source=$Source
        Risk=$Risk; Dependency=$Dependency; Verification=$Verification; Metadata=$Metadata
    })
}

function Remove-RegistryValue {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$Path, [string]$Name, [switch]$Silent)
    try {
        if ($script:ActionPlanCapture) {
            $before = Get-RestoreRegistryPlanState -Path $Path -Name $Name
            $exists = $before.Exists -eq $true
            Add-RestoreActionPlanOperation -Kind "RegistryValue" -Action $(if($exists){"Remove"}else{"NoOp"}) -Target "$Path\$Name" -Before $before -After ([pscustomobject]@{Exists=$false;Path=$Path;Name=$Name;Type=$null;Value=$null}) -Scope $(if ($Path -like "HKCU:*") { "CurrentUser" } else { "Machine" }) -CanExecute:$exists -Reason $(if($exists){$null}else{"Registry value is already absent"}) -Verification "Registry value is absent"
            return $false
        }
        if (Test-Path $Path) {
            $current = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
            if ($current -and $current.PSObject.Properties[$Name]) {
                $before = Get-RestoreRegistryPlanState -Path $Path -Name $Name
                if ($script:WhatIfRequested) { return $false }
                if (-not $PSCmdlet.ShouldProcess("$Path\$Name", "remove registry value")) { return $false }
                Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop
                if (-not $Silent) { Write-Log "Removed: $Path\$Name" -Level Success }
                $script:ChangesCount++
                return $true
            }
        }
    } catch {
        if (-not $Silent) { Write-Log "Failed to remove $Path\$Name - $($_.Exception.Message)" -Level Warning }
    }
    return $false
}

function Set-RegistryValue {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$Path, [string]$Name, $Value, [string]$Type = "DWord", [switch]$Silent)
    try {
        $before = Get-RestoreRegistryPlanState -Path $Path -Name $Name
        if ($script:ActionPlanCapture) {
            Add-RestoreActionPlanOperation -Kind "RegistryValue" -Action "Set" -Target "$Path\$Name" -Before $before -After ([pscustomobject]@{Exists=$true;Path=$Path;Name=$Name;Type=$Type;Value=$Value}) -Scope $(if ($Path -like "HKCU:*") { "CurrentUser" } else { "Machine" })
            return $false
        }
        if ($script:WhatIfRequested) { return $false }
        if (-not $PSCmdlet.ShouldProcess("$Path\$Name", "set registry value")) { return $false }
        if (!(Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        $current = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($current -and $current.PSObject.Properties[$Name]) {
            $currentJson = $current.$Name | ConvertTo-Json -Depth 8 -Compress
            $desiredJson = $Value | ConvertTo-Json -Depth 8 -Compress
            if ($currentJson -eq $desiredJson) { return $false }
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
        if (-not $Silent) { Write-Log "Set: $Path\$Name = $Value" -Level Success }
        $script:ChangesCount++
        return $true
    } catch {
        if (-not $Silent) { Write-Log "Failed to set $Path\$Name - $($_.Exception.Message)" -Level Warning }
    }
    return $false
}

function Remove-RegistryKey {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$Path, [switch]$Silent)
    try {
        if ($script:ActionPlanCapture) {
            $exists = Test-Path -LiteralPath $Path
            Add-RestoreActionPlanOperation -Kind "RegistryKey" -Action $(if($exists){"Remove"}else{"NoOp"}) -Target $Path -Before ([pscustomobject]@{Exists=$exists;Path=$Path}) -After ([pscustomobject]@{Exists=$false;Path=$Path}) -Scope $(if ($Path -like "HKCU:*") { "CurrentUser" } else { "Machine" }) -RollbackAction "Restore captured key state" -CanExecute:$exists -Reason $(if($exists){$null}else{"Registry key is already absent"}) -Verification "Registry key is absent"
            return $false
        }
        if (Test-Path $Path) {
            if ($script:WhatIfRequested) { return $false }
            if (-not $PSCmdlet.ShouldProcess($Path, "remove registry key")) { return $false }
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            if (-not $Silent) { Write-Log "Removed key: $Path" -Level Success }
            $script:ChangesCount++
            return $true
        }
    } catch {
        if (-not $Silent) { Write-Log "Failed to remove key $Path - $($_.Exception.Message)" -Level Warning }
    }
    return $false
}

function New-RestoreRegistryKey {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][string]$Path,[switch]$Silent)
    try {
        $exists = Test-Path -LiteralPath $Path
        $needsChange = -not $exists
        if ($script:ActionPlanCapture) {
            Add-RestoreActionPlanOperation -Kind "RegistryKey" -Action $(if($needsChange){"Ensure"}else{"NoOp"}) -Target $Path -Before ([pscustomobject]@{Exists=$exists;Path=$Path}) -After ([pscustomobject]@{Exists=$true;Path=$Path}) -Scope $(if ($Path -like "HKCU:*") { "CurrentUser" } else { "Machine" }) -RollbackAction "Remove key if it was created by this plan" -CanExecute:$needsChange -Reason $(if($needsChange){$null}else{"Registry key already exists"}) -Verification "Registry key exists"
            return $false
        }
        if ($script:WhatIfRequested -or -not $needsChange) { return $false }
        if (-not $PSCmdlet.ShouldProcess($Path, "create registry key")) { return $false }
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        if (-not $Silent) { Write-Log "Created registry key: $Path" -Level Success }
        $script:ChangesCount++
        return $true
    } catch {
        if (-not $Silent) { Write-Log "Could not create registry key $Path - $($_.Exception.Message)" -Level Warning }
        return $false
    }
}

function Restore-ServiceStartup {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$ServiceName, [string]$StartupType, [switch]$Silent)
    try {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($script:ActionPlanCapture) {
            $before = Get-RestoreServicePlanState -ServiceName $ServiceName
            $exists = [bool]$before.Exists
            $currentType = $before.StartType
            $needsChange = $exists -and $currentType -ine $StartupType
            Add-RestoreActionPlanOperation -Kind "Service" -Action $(if($needsChange){"SetStartupType"}else{"NoOp"}) -Target "Service:$ServiceName" -Before $before -After ([pscustomobject][ordered]@{Exists=$true;Name=$ServiceName;StartType=$StartupType;Status=$null;ServiceState=$null;StartName=$before.StartName;PathName=$before.PathName;DelayedAutoStart=$before.DelayedAutoStart}) -Scope "Machine" -RollbackAction "Restore captured service configuration" -CanExecute:$needsChange -Reason $(if($needsChange){$null}elseif(-not $exists){"Service is not installed"}else{"Service startup type already matches"}) -Verification "Service startup type equals $StartupType"
            return $false
        }
        if ($svc) {
            if ($svc.StartType.ToString() -ieq $StartupType) { return $false }
            if ($script:WhatIfRequested) { return $false }
            if (-not $PSCmdlet.ShouldProcess("Service:$ServiceName", "set startup type to $StartupType")) { return $false }
            Set-Service -Name $ServiceName -StartupType $StartupType -ErrorAction Stop
            if (-not $Silent) { Write-Log "Service '$ServiceName' set to $StartupType" -Level Success }
            $script:ChangesCount++
            return $true
        }
    } catch {
        if (-not $Silent) { Write-Log "Failed to configure service $ServiceName - $($_.Exception.Message)" -Level Warning }
    }
    return $false
}

function Enable-ScheduledTaskSafe {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$TaskPath, [string]$TaskName, [switch]$Silent)
    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($script:ActionPlanCapture) {
            $before = Get-RestoreScheduledTaskPlanState -TaskPath $TaskPath -TaskName $TaskName
            $exists = [bool]$before.Exists
            $state = $before.State
            $needsChange = $exists -and $state -eq "Disabled"
            Add-RestoreActionPlanOperation -Kind "ScheduledTask" -Action $(if($needsChange){"Enable"}else{"NoOp"}) -Target "Task:$TaskPath$TaskName" -Before $before -After ([pscustomobject][ordered]@{Exists=$true;Path=$TaskPath;Name=$TaskName;State="Enabled";Xml=$before.Xml;XmlSha256=$before.XmlSha256}) -Scope "Machine" -RollbackAction "Restore captured task configuration and state" -CanExecute:$needsChange -Reason $(if($needsChange){$null}elseif(-not $exists){"Scheduled task is not installed"}else{"Scheduled task is already enabled"}) -Verification "Scheduled task is enabled"
            return $false
        }
        if ($task) {
            if ($task.State -and $task.State.ToString() -ne "Disabled") { return $false }
            if ($script:WhatIfRequested) { return $false }
            if (-not $PSCmdlet.ShouldProcess("Task:$TaskPath$TaskName", "enable scheduled task")) { return $false }
            Enable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
            if (-not $Silent) { Write-Log "Enabled task: $TaskPath$TaskName" -Level Success }
            $script:ChangesCount++
            return $true
        }
    } catch {
        if (-not $Silent) { Write-Log "Failed to enable task $TaskPath$TaskName - $($_.Exception.Message)" -Level Warning }
    }
    return $false
}

function Get-RestoreSha256 {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace "-", "").ToLowerInvariant()) }
    finally { $sha.Dispose() }
}

function Get-RestoreJsonSha256 {
    param([Parameter(Mandatory=$true)][object]$Value)
    $json = $Value | ConvertTo-Json -Depth 50 -Compress
    return (Get-RestoreSha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($json)))
}

function Get-RestoreServicePlanState {
    param([Parameter(Mandatory=$true)][string]$ServiceName)
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $cimService = $null
    try {
        $escapedName = $ServiceName.Replace("'", "''")
        $cimService = Get-CimInstance -ClassName Win32_Service -Filter "Name='$escapedName'" -ErrorAction Stop | Select-Object -First 1
    } catch { Write-Verbose "Could not read CIM service state for $ServiceName" }
    if (-not $service -and -not $cimService) {
        return [pscustomobject][ordered]@{
            Exists=$false; Name=$ServiceName; Status=$null; ServiceState=$null; StartType=$null
            StartName=$null; PathName=$null; DelayedAutoStart=$null
        }
    }
    return [pscustomobject][ordered]@{
        Exists=$true; Name=$ServiceName
        Status=if($service -and $service.Status){$service.Status.ToString()}else{$null}
        ServiceState=if($cimService){[string]$cimService.State}else{if($service -and $service.Status){$service.Status.ToString()}else{$null}}
        StartType=if($service -and $service.StartType){$service.StartType.ToString()}else{if($cimService){[string]$cimService.StartMode}else{$null}}
        StartName=if($cimService){[string]$cimService.StartName}else{$null}
        PathName=if($cimService){[string]$cimService.PathName}else{$null}
        DelayedAutoStart=if($cimService -and $cimService.PSObject.Properties["DelayedAutoStart"]){[bool]$cimService.DelayedAutoStart}else{$null}
    }
}

function Get-RestoreScheduledTaskPlanState {
    param([Parameter(Mandatory=$true)][string]$TaskPath,[Parameter(Mandatory=$true)][string]$TaskName)
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return [pscustomobject][ordered]@{Exists=$false;Path=$TaskPath;Name=$TaskName;State=$null;Xml=$null;XmlSha256=$null}
    }
    $xml = $null
    try { $xml = (@(Export-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop) -join "`n") } catch { Write-Verbose "Could not export scheduled task XML for $TaskPath$TaskName" }
    $rawState = if($task.State){$task.State.ToString()}else{$null}
    return [pscustomobject][ordered]@{
        Exists=$true; Path=$TaskPath; Name=$TaskName; State=if($rawState -eq "Disabled"){"Disabled"}else{"Enabled"}; RawState=$rawState
        Xml=$xml; XmlSha256=if($xml){Get-RestoreSha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($xml))}else{$null}
    }
}

function Get-RestoreAppxPlanState {
    param([Parameter(Mandatory=$true)][string]$PackageName,[string]$Scope="CurrentUser")
    $allUsers = $Scope -in @("AllUsers","Provisioned")
    $packages = @(Get-AppxPackageSafe -Name $PackageName -AllUsers:$allUsers | Where-Object { $_ })
    $summaries = @($packages | ForEach-Object {
        [pscustomobject][ordered]@{
            Name=[string]$_.Name; FullName=[string]$_.PackageFullName; Version=[string]$_.Version
            InstallLocation=[string]$_.InstallLocation; PackageFamilyName=[string]$_.PackageFamilyName
        }
    })
    return [pscustomobject][ordered]@{
        PackageName=$PackageName; Scope=$Scope; Installed=($summaries.Count -gt 0); Packages=$summaries
    }
}

function Get-RestoreFilePlanState {
    param([Parameter(Mandatory=$true)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $hash = $null
        $contentBase64 = $null
        if (-not $item.PSIsContainer) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($Path)
                $hash = Get-RestoreSha256 -Bytes $bytes
                if ($bytes.Length -le $script:RollbackInlineFileBytes) { $contentBase64 = [Convert]::ToBase64String($bytes) }
            } catch { Write-Verbose "Could not hash or inline file bytes for $Path" }
        }
        return [pscustomobject][ordered]@{
            Exists=$true; Path=$Path; IsDirectory=[bool]$item.PSIsContainer; Length=if($item.PSIsContainer){$null}else{[int64]$item.Length}
            LastWriteTimeUtc=$item.LastWriteTimeUtc.ToString("o"); Sha256=$hash; ContentBase64=$contentBase64
        }
    } catch {
        return [pscustomobject][ordered]@{ Exists=$false; Path=$Path; IsDirectory=$false; Length=$null; LastWriteTimeUtc=$null; Sha256=$null; ContentBase64=$null }
    }
}

function Invoke-RestoreFileMutation {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][ValidateSet("Remove","Rename","Move","Copy")][string]$Action,
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$Destination,
        [switch]$Silent
    )
    try {
        $targetPath = $Path
        if ($Action -in @("Rename","Move","Copy")) {
            if ([string]::IsNullOrWhiteSpace($Destination)) { throw "Destination is required for $Action" }
            $targetPath = if ([System.IO.Path]::IsPathRooted($Destination)) { $Destination } else { Join-Path (Split-Path -Parent $Path) $Destination }
        }
        $before = Get-RestoreFilePlanState -Path $Path
        $exists = $before.Exists -eq $true
        $canExecute = $exists
        $after = if ($Action -eq "Remove") {
            [pscustomobject][ordered]@{Exists=$false;Path=$Path;IsDirectory=$before.IsDirectory;Length=$null;Sha256=$null}
        } else {
            [pscustomobject][ordered]@{Exists=$true;Path=$targetPath;SourcePath=$Path;IsDirectory=$before.IsDirectory;Length=$before.Length;Sha256=$before.Sha256}
        }
        if ($script:ActionPlanCapture) {
            Add-RestoreActionPlanOperation -Kind "File" -Action $(if($canExecute){$Action}else{"NoOp"}) -Target $(if($Action -eq "Remove"){$Path}else{"$Path -> $targetPath"}) -Before $before -After $after -Scope "Machine" -RollbackAction "Restore captured file state" -CanExecute:$canExecute -Reason $(if($canExecute){$null}else{"Source file or directory is absent"}) -Verification $(if($Action -eq "Remove"){"Path is absent"}else{"Path exists at the planned destination"}) -Metadata ([pscustomobject]@{Action=$Action;Path=$Path;Destination=$targetPath})
            return $false
        }
        if ($script:WhatIfRequested) { return $false }
        if (-not $canExecute) { return $false }
        if (-not $PSCmdlet.ShouldProcess($(if($Action -eq "Remove"){$Path}else{"$Path -> $targetPath"}), $Action.ToLowerInvariant() + " file state")) { return $false }
        switch ($Action) {
            "Remove" { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
            "Rename" { Rename-Item -LiteralPath $Path -NewName $Destination -Force -ErrorAction Stop }
            "Move" { Move-Item -LiteralPath $Path -Destination $targetPath -Force -ErrorAction Stop }
            "Copy" { Copy-Item -LiteralPath $Path -Destination $targetPath -Force -ErrorAction Stop }
        }
        if (-not $Silent) { Write-Log "$Action file state: $Path" -Level Success }
        $script:ChangesCount++
        return $true
    } catch {
        if (-not $Silent) { Write-Log "Failed to $($Action.ToLowerInvariant()) file state for $Path - $($_.Exception.Message)" -Level Warning }
        return $false
    }
}

function Invoke-RestoreTextFileMutation {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content,
        [string]$Scope="Machine",
        [switch]$Silent
    )
    try {
        $before = Get-RestoreFilePlanState -Path $Path
        $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $contentHash = ([BitConverter]::ToString($sha.ComputeHash($contentBytes)) -replace "-","").ToLowerInvariant() } finally { $sha.Dispose() }
        $sameContent = $false
        if ($before.Exists -and $before.Sha256) { $sameContent = $before.Sha256 -eq $contentHash }
        $after = [pscustomobject][ordered]@{Exists=$true;Path=$Path;Length=$contentBytes.Length;Sha256=$contentHash;Encoding="UTF8"}
        if ($script:ActionPlanCapture) {
            Add-RestoreActionPlanOperation -Kind "File" -Action $(if($sameContent){"NoOp"}else{"Write"}) -Target $Path -Before $before -After $after -Scope $Scope -RollbackAction "Restore captured file bytes" -CanExecute:(-not $sameContent) -Reason $(if($sameContent){"File content already matches"}else{$null}) -Verification "File SHA-256 matches the planned content" -Metadata ([pscustomobject]@{Action="Write";Path=$Path;Content=$Content;Encoding="UTF8"})
            return $false
        }
        if ($script:WhatIfRequested -or $sameContent) { return $false }
        if (-not $PSCmdlet.ShouldProcess($Path, "write planned text file content")) { return $false }
        [System.IO.File]::WriteAllBytes($Path, $contentBytes)
        if (-not $Silent) { Write-Log "Wrote text file: $Path" -Level Success }
        $script:ChangesCount++
        return $true
    } catch {
        if (-not $Silent) { Write-Log "Could not write text file $Path - $($_.Exception.Message)" -Level Warning }
        return $false
    }
}

function Invoke-RestoreServiceControl {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][ValidateSet("Start","Stop")][string]$Action,
        [Parameter(Mandatory=$true)][string]$ServiceName,
        [switch]$Silent
    )
    try {
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        $exists = $null -ne $service
        $status = if($exists){$service.Status.ToString()}else{$null}
        $needsChange = $exists -and (($Action -eq "Start" -and $status -eq "Stopped") -or ($Action -eq "Stop" -and $status -ne "Stopped"))
        if ($script:ActionPlanCapture) {
            $before = Get-RestoreServicePlanState -ServiceName $ServiceName
            Add-RestoreActionPlanOperation -Kind "ServiceControl" -Action $(if($needsChange){$Action}else{"NoOp"}) -Target "Service:$ServiceName" -Before $before -After ([pscustomobject][ordered]@{Exists=$true;Name=$ServiceName;Status=if($Action -eq "Start"){"Running"}else{"Stopped"};ServiceState=if($Action -eq "Start"){"Running"}else{"Stopped"}}) -Scope "Machine" -RollbackAction "Restore captured service running state" -CanExecute:$needsChange -Reason $(if($needsChange){$null}elseif(-not $exists){"Service is not installed"}else{"Service already has the requested running state"}) -Verification "Service status is $(if($Action -eq "Start"){"Running"}else{"Stopped"})"
            return $false
        }
        if ($script:WhatIfRequested -or -not $needsChange) { return $false }
        if (-not $PSCmdlet.ShouldProcess("Service:$ServiceName", "$Action service")) { return $false }
        if ($Action -eq "Start") { Start-Service -Name $ServiceName -ErrorAction Stop } else { Stop-Service -Name $ServiceName -Force -ErrorAction Stop }
        if (-not $Silent) { Write-Log "$Action service: $ServiceName" -Level Success }
        $script:ChangesCount++
        return $true
    } catch {
        if (-not $Silent) { Write-Log "Failed to $($Action.ToLowerInvariant()) service $ServiceName - $($_.Exception.Message)" -Level Warning }
        return $false
    }
}

function Invoke-RestoreScheduledTaskState {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][ValidateSet("Enable","Disable")][string]$Action,
        [object]$InputObject,
        [string]$TaskPath,
        [string]$TaskName,
        [switch]$Silent
    )
    try {
        if ($InputObject) {
            if (-not $TaskPath) { $TaskPath = if($InputObject.PSObject.Properties["TaskPath"]){[string]$InputObject.TaskPath}else{[string]$InputObject.Path} }
            if (-not $TaskName) { $TaskName = if($InputObject.PSObject.Properties["TaskName"]){[string]$InputObject.TaskName}else{[string]$InputObject.Name} }
        }
        if ([string]::IsNullOrWhiteSpace($TaskPath) -or [string]::IsNullOrWhiteSpace($TaskName)) { throw "Scheduled task path and name are required" }
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        $exists = $null -ne $task
        $state = if($exists){(Get-RestoreScheduledTaskPlanState -TaskPath $TaskPath -TaskName $TaskName).State}else{$null}
        $needsChange = $exists -and (($Action -eq "Enable" -and $state -eq "Disabled") -or ($Action -eq "Disable" -and $state -ne "Disabled"))
        if ($script:ActionPlanCapture) {
            $before = Get-RestoreScheduledTaskPlanState -TaskPath $TaskPath -TaskName $TaskName
            Add-RestoreActionPlanOperation -Kind "ScheduledTask" -Action $(if($needsChange){$Action}else{"NoOp"}) -Target "Task:$TaskPath$TaskName" -Before $before -After ([pscustomobject][ordered]@{Exists=$true;Path=$TaskPath;Name=$TaskName;State=if($Action -eq "Enable"){"Enabled"}else{"Disabled"};Xml=$before.Xml;XmlSha256=$before.XmlSha256}) -Scope "Machine" -RollbackAction "Restore captured task configuration and state" -CanExecute:$needsChange -Reason $(if($needsChange){$null}elseif(-not $exists){"Scheduled task is not installed"}else{"Scheduled task already has the requested state"}) -Verification "Scheduled task is $(if($Action -eq "Enable"){"enabled"}else{"disabled"})"
            return $false
        }
        if ($script:WhatIfRequested -or -not $needsChange) { return $false }
        if (-not $PSCmdlet.ShouldProcess("Task:$TaskPath$TaskName", "$Action scheduled task")) { return $false }
        if ($Action -eq "Enable") { Enable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null }
        if (-not $Silent) { Write-Log "$Action scheduled task: $TaskPath$TaskName" -Level Success }
        $script:ChangesCount++
        return $true
    } catch {
        if (-not $Silent) { Write-Log "Failed to $($Action.ToLowerInvariant()) scheduled task $TaskPath$TaskName - $($_.Exception.Message)" -Level Warning }
        return $false
    }
}

function Invoke-RestoreNativeCommand {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList=@(),
        [int[]]$ExpectedExitCodes=@(0),
        [switch]$RequiresReboot,
        [string]$Scope="Machine",
        [switch]$Silent
    )
    $argumentText = @($ArgumentList) -join " "
    $target = "$FilePath $argumentText".Trim()
    $before = [pscustomobject][ordered]@{Executable=$FilePath;Arguments=@($ArgumentList);ExitCode=$null;Observed=$true}
    $after = [pscustomobject][ordered]@{ExpectedExitCodes=@($ExpectedExitCodes);RequiresReboot=[bool]$RequiresReboot;Completed=$true}
    if ($script:ActionPlanCapture) {
        Add-RestoreActionPlanOperation -Kind "NativeCommand" -Action "Execute" -Target $target -Before $before -After $after -Scope $Scope -RollbackAction "No automatic rollback; verify command postcondition" -Risk "High" -Verification "Exit code is one of the expected values" -Metadata ([pscustomobject]@{FilePath=$FilePath;ArgumentList=@($ArgumentList);ExpectedExitCodes=@($ExpectedExitCodes);RequiresReboot=[bool]$RequiresReboot})
        return [pscustomobject]@{Success=$false;ExitCode=$null;Planned=$true;Target=$target}
    }
    if ($script:WhatIfRequested) { return [pscustomobject]@{Success=$false;ExitCode=$null;Planned=$true;Target=$target} }
    try {
        if (-not $PSCmdlet.ShouldProcess($target, "execute native restore command")) { return [pscustomobject]@{Success=$false;ExitCode=$null;Skipped=$true;Target=$target} }
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -Wait -PassThru -ErrorAction Stop
        $exitCode = [int]$process.ExitCode
        $success = $exitCode -in @($ExpectedExitCodes)
        if ($success) { if (-not $Silent) { Write-Log "Native command completed ($exitCode): $target" -Level Success }; $script:ChangesCount++ }
        elseif (-not $Silent) { Write-Log "Native command failed ($exitCode): $target" -Level Warning }
        return [pscustomobject]@{Success=$success;ExitCode=$exitCode;Target=$target;RequiresReboot=[bool]$RequiresReboot}
    } catch {
        if (-not $Silent) { Write-Log "Native command could not run: $target - $($_.Exception.Message)" -Level Warning }
        return [pscustomobject]@{Success=$false;ExitCode=$null;Target=$target;Error=$_.Exception.Message}
    }
}

function Invoke-RestoreAppxRegistration {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][string]$PackageName,
        [string]$ManifestPath,
        [string]$PackageFamilyName,
        [string]$Scope="CurrentUser",
        [switch]$Silent
    )
    $target = if($ManifestPath){"$PackageName ($ManifestPath)"}else{"$PackageName ($PackageFamilyName)"}
    $before = Get-RestoreAppxPlanState -PackageName $PackageName -Scope $Scope
    $before | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $ManifestPath
    $before | Add-Member -NotePropertyName PackageFamilyName -NotePropertyValue $PackageFamilyName
    $after = [pscustomobject][ordered]@{PackageName=$PackageName;Installed=$true;Scope=$Scope;ManifestPath=$ManifestPath;PackageFamilyName=$PackageFamilyName}
    if ($script:ActionPlanCapture) {
        Add-RestoreActionPlanOperation -Kind "AppX" -Action "Register" -Target $target -Before $before -After $after -Scope $Scope -RollbackAction "Restore captured AppX package state" -Risk "High" -Verification "Package is present in the requested scope" -Metadata ([pscustomobject]@{PackageName=$PackageName;ManifestPath=$ManifestPath;PackageFamilyName=$PackageFamilyName;Scope=$Scope})
        return [pscustomobject]@{Success=$false;Planned=$true;Target=$target}
    }
    if ($script:WhatIfRequested) { return [pscustomobject]@{Success=$false;Planned=$true;Target=$target} }
    try {
        if (-not $PSCmdlet.ShouldProcess($target, "register AppX package")) { return [pscustomobject]@{Success=$false;Skipped=$true;Target=$target} }
        if ($ManifestPath) { Add-AppxPackage -DisableDevelopmentMode -Register $ManifestPath -ErrorAction Stop }
        elseif ($PackageFamilyName) { Add-AppxPackage -RegisterByFamilyName -MainPackage $PackageFamilyName -ErrorAction Stop }
        else { throw "ManifestPath or PackageFamilyName is required" }
        if (-not $Silent) { Write-Log "Registered AppX package: $PackageName" -Level Success }
        $script:ChangesCount++
        return [pscustomobject]@{Success=$true;Target=$target}
    } catch {
        if (-not $Silent) { Write-Log "Could not register AppX package $PackageName - $($_.Exception.Message)" -Level Warning }
        return [pscustomobject]@{Success=$false;Target=$target;Error=$_.Exception.Message}
    }
}

function Invoke-RestoreOptionalFeature {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][string]$FeatureName,[switch]$Silent)
    try {
        $feature = Get-WindowsOptionalFeature -FeatureName $FeatureName -Online -ErrorAction Stop
        $state = if($feature){[string]$feature.State}else{"Missing"}
        $needsChange = $null -ne $feature -and $state -ne "Enabled"
        if ($script:ActionPlanCapture) {
            Add-RestoreActionPlanOperation -Kind "OptionalFeature" -Action $(if($needsChange){"Enable"}else{"NoOp"}) -Target $FeatureName -Before ([pscustomobject]@{State=$state;FeatureName=$FeatureName}) -After ([pscustomobject]@{State="Enabled";FeatureName=$FeatureName}) -Scope "Machine" -RollbackAction "Restore captured optional-feature state" -CanExecute:$needsChange -Reason $(if($needsChange){$null}elseif($null -eq $feature){"Optional feature is unavailable"}else{"Optional feature is already enabled"}) -Verification "Optional feature is enabled"
            return $false
        }
        if ($script:WhatIfRequested -or -not $needsChange) { return $false }
        if (-not $PSCmdlet.ShouldProcess($FeatureName, "enable optional Windows feature")) { return $false }
        Enable-WindowsOptionalFeature -FeatureName $FeatureName -Online -NoRestart -LogLevel Errors -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
        if (-not $Silent) { Write-Log "Enabled optional feature: $FeatureName" -Level Success }
        $script:ChangesCount++
        return $true
    } catch {
        if (-not $Silent) { Write-Log "Could not enable optional feature $FeatureName - $($_.Exception.Message)" -Level Warning }
        return $false
    }
}

function Invoke-RestoreEnvironmentVariable {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][ValidateSet("User","Machine")][string]$Scope,
        [string]$Value,
        [switch]$Remove,
        [switch]$Silent
    )
    $beforeValue = [System.Environment]::GetEnvironmentVariable($Name, $Scope)
    $afterValue = if($Remove){$null}else{$Value}
    $action = if($Remove){"Remove"}else{"Set"}
    $needsChange = $beforeValue -ne $afterValue
    if ($script:ActionPlanCapture) {
        Add-RestoreActionPlanOperation -Kind "EnvironmentVariable" -Action $(if($needsChange){$action}else{"NoOp"}) -Target "$Scope`:$Name" -Before ([pscustomobject]@{Name=$Name;Scope=$Scope;Value=$beforeValue}) -After ([pscustomobject]@{Name=$Name;Scope=$Scope;Value=$afterValue}) -Scope $Scope -RollbackAction "Restore captured environment variable" -CanExecute:$needsChange -Reason $(if($needsChange){$null}else{"Environment variable already matches"}) -Verification "Environment variable has the planned value"
        return $false
    }
    if ($script:WhatIfRequested -or -not $needsChange) { return $false }
    try {
        if (-not $PSCmdlet.ShouldProcess("$Scope`:$Name", "$action environment variable")) { return $false }
        [System.Environment]::SetEnvironmentVariable($Name, $afterValue, $Scope)
        if (-not $Silent) { Write-Log "$action $Scope environment variable: $Name" -Level Success }
        $script:ChangesCount++
        return $true
    } catch {
        if (-not $Silent) { Write-Log "Could not update $Scope environment variable $Name - $($_.Exception.Message)" -Level Warning }
        return $false
    }
}

function Invoke-RestoreSystemRestorePoint {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$Description="Before Restore-WindowsDefaults plan",[string]$Drive="$env:SystemDrive\",[switch]$Silent)
    $before = [pscustomobject][ordered]@{Drive=$Drive;LatestRestorePoint=$null}
    try {
        $latest = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object SequenceNumber | Select-Object -Last 1)
        if ($latest.Count -gt 0) { $before.LatestRestorePoint = [string]$latest[0].SequenceNumber }
    } catch { }
    $after = [pscustomobject][ordered]@{Drive=$Drive;Description=$Description;Created=$true}
    if ($script:ActionPlanCapture) {
        Add-RestoreActionPlanOperation -Kind "RestorePoint" -Action "Create" -Target "SystemRestore:$Drive" -Before $before -After $after -Scope "Machine" -RollbackAction "Use the created Windows System Restore point" -Risk "High" -Dependency "Capability:SystemRestore" -Verification "A restore point with the planned description exists" -Metadata ([pscustomobject]@{Description=$Description;Drive=$Drive})
        return [pscustomobject]@{Success=$false;Planned=$true;Target="SystemRestore:$Drive"}
    }
    if ($script:WhatIfRequested) { return [pscustomobject]@{Success=$false;Planned=$true;Target="SystemRestore:$Drive"} }
    try {
        if (-not $PSCmdlet.ShouldProcess("SystemRestore:$Drive", "create restore point '$Description'")) { return [pscustomobject]@{Success=$false;Skipped=$true} }
        Enable-ComputerRestore -Drive $Drive -ErrorAction Stop
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        if (-not $Silent) { Write-Log "Created system restore point: $Description" -Level Success }
        $script:ChangesCount++
        return [pscustomobject]@{Success=$true;Target="SystemRestore:$Drive"}
    } catch {
        if (-not $Silent) { Write-Log "Could not create system restore point - $($_.Exception.Message)" -Level Warning }
        return [pscustomobject]@{Success=$false;Error=$_.Exception.Message;Target="SystemRestore:$Drive"}
    }
}

# ============================================================================
# DATA-DRIVEN INVENTORY AND SNAPSHOT HELPERS
# ============================================================================

$script:RegistrySnapshotSchemaVersion = 1
$script:RegistrySnapshotPaths = @(
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows",
    "HKLM:\SOFTWARE\Policies\Microsoft\Edge",
    "HKLM:\SOFTWARE\Policies\Google",
    "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies",
    "HKCU:\SOFTWARE\Policies\Microsoft\Windows",
    "HKCU:\SOFTWARE\Policies\Google",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
)

# Versioned, data-driven defaults for policy values whose stock state is the
# absence of an override. This catalog is also used by the CLI baseline report.
$script:RegistryDefaultCatalog = @(
    @{Name="Defender anti-spyware policy";Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender";ValueName="DisableAntiSpyware";Action="Remove";Category="chkDefender"},
    @{Name="Defender real-time policy";Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection";ValueName="DisableRealtimeMonitoring";Action="Remove";Category="chkDefender"},
    @{Name="Windows Update automatic updates";Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU";ValueName="NoAutoUpdate";Action="Remove";Category="chkWindowsUpdate"},
    @{Name="Windows Update feature deferral";Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate";ValueName="DeferFeatureUpdatesPeriodInDays";Action="Remove";Category="chkWindowsUpdate"},
    @{Name="Windows Update quality deferral";Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate";ValueName="DeferQualityUpdatesPeriodInDays";Action="Remove";Category="chkWindowsUpdate"},
    @{Name="SmartScreen policy";Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";ValueName="EnableSmartScreen";Action="Remove";Category="chkSmartScreen"},
    @{Name="Edge policy override";Path="HKLM:\SOFTWARE\Policies\Microsoft\Edge";ValueName="SmartScreenEnabled";Action="Remove";Category="chkEdge"},
    @{Name="Background app policy";Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy";ValueName="LetAppsRunInBackground";Action="Remove";Category="chkBgApps"},
    @{Name="OneDrive sync policy";Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive";ValueName="DisableFileSyncNGSC";Action="Remove";Category="chkOneDrive"},
    @{Name="Defender CPU cap";Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Scan";ValueName="AvgCPULoadFactor";Action="Remove";Category="chkDefenderCpuCap"}
)

function Get-RegistryDefaultBaselineReport {
    param([object[]]$Catalog = $script:RegistryDefaultCatalog,[object]$MachineProfile)
    $context = Get-RestoreBaselineContext -MachineProfile $MachineProfile
    $findings = @()
    foreach ($entry in $Catalog) {
        $catalog = Get-RestoreCatalogEntryEvaluation -Entry $entry -Context $context
        $current = Get-ItemProperty -LiteralPath $entry.Path -Name $entry.ValueName -ErrorAction SilentlyContinue
        $present = $current -and $current.PSObject.Properties[$entry.ValueName]
        $matchesDefault = if ($entry.Action -eq "Remove") { -not $present }
            else { $present -and (($current.$($entry.ValueName) | ConvertTo-Json -Compress) -eq ($entry.DefaultValue | ConvertTo-Json -Compress)) }
        $findings += [pscustomobject][ordered]@{
            Name=$entry.Name; Path=$entry.Path; ValueName=$entry.ValueName; Category=$entry.Category
            Action=$entry.Action; CurrentValue=if($present){$current.$($entry.ValueName)}else{$null}
            IsDefault=$matchesDefault; CatalogSchemaVersion=$catalog.CatalogSchemaVersion; CatalogVersion=$catalog.CatalogVersion
            SourceUrl=$catalog.SourceUrl; PolicyMapping=$catalog.PolicyMapping
            SupportedProductFamilies=$catalog.SupportedProductFamilies; SupportedBuildRange=$catalog.SupportedBuildRange
            SupportedEditions=$catalog.SupportedEditions; Confidence=$catalog.Confidence; EvidenceType=$catalog.EvidenceType
            CatalogStatus=$catalog.CatalogStatus; CanAutoFix=$catalog.CanAutoFix; Warning=$catalog.Warning
        }
    }
    return @($findings)
}

function Restore-RegistryDefaultBaseline {
    param([object[]]$Catalog = $script:RegistryDefaultCatalog,[object]$MachineProfile)
    $context = Get-RestoreBaselineContext -MachineProfile $MachineProfile
    foreach ($entry in $Catalog) {
        $catalog = Get-RestoreCatalogEntryEvaluation -Entry $entry -Context $context
        if (-not $catalog.CanAutoFix) { continue }
        if ($entry.Action -eq "Remove") { Remove-RegistryValue -Path $entry.Path -Name $entry.ValueName -Silent }
        elseif ($entry.Action -eq "Set") { Set-RegistryValue -Path $entry.Path -Name $entry.ValueName -Value $entry.DefaultValue -Type $entry.Type -Silent }
    }
}

$script:CoreAppxPackageCatalog = @(
    @{Name="Microsoft.WindowsStore"; Role="Core"},
    @{Name="Microsoft.StorePurchaseApp"; Role="Core"},
    @{Name="Microsoft.DesktopAppInstaller"; Role="Core"},
    @{Name="Microsoft.WindowsCalculator"; Role="Core"},
    @{Name="Microsoft.Windows.Photos"; Role="Core"},
    @{Name="Microsoft.WindowsCamera"; Role="Core"},
    @{Name="Microsoft.WindowsAlarms"; Role="Core"},
    @{Name="Microsoft.WindowsSoundRecorder"; Role="Core"},
    @{Name="Microsoft.WindowsFeedbackHub"; Role="Optional"},
    @{Name="Microsoft.GetHelp"; Role="Optional"},
    @{Name="Microsoft.MSPaint"; Role="Optional"},
    @{Name="Microsoft.MicrosoftStickyNotes"; Role="Optional"},
    @{Name="Microsoft.MicrosoftOfficeHub"; Role="Optional"}
)

# These are evidence-only fingerprints. A detected tool is never treated as
# proof that a domain policy is unwanted; the user still chooses categories.
$script:DebloatToolFingerprints = @(
    @{Name="O&O ShutUp10"; Indicators=@(
        @{Kind="Registry";Path="HKCU:\Software\O&O Software\ShutUp10";Description="O&O ShutUp10 user settings"},
        @{Kind="File";Path="$env:ProgramFiles\OOSU10\OOSU10.exe";Description="OOSU10 executable"},
        @{Kind="File";Path="$env:ProgramFiles\O&O ShutUp10\OOSU10.exe";Description="OOSU10 executable"},
        @{Kind="File";Path="$env:ProgramData\O&O Software\ShutUp10\*";Description="O&O ShutUp10 data"}
    );FixKeys=@("chkPrivacy","chkServices","chkTasks","chkNetwork","chkHostsFile")}
    @{Name="WPD"; Indicators=@(
        @{Kind="Registry";Path="HKCU:\Software\WPD";Description="WPD user settings"},
        @{Kind="File";Path="$env:ProgramFiles\WPD\WPD.exe";Description="WPD executable"},
        @{Kind="File";Path="$env:ProgramFiles\WPD\*";Description="WPD installation"}
    );FixKeys=@("chkPrivacy","chkServices","chkTasks","chkAppx")}
    @{Name="ThisIsWin11"; Indicators=@(
        @{Kind="Registry";Path="HKCU:\Software\ThisIsWin11";Description="ThisIsWin11 user settings"},
        @{Kind="File";Path="$env:ProgramFiles\ThisIsWin11\*";Description="ThisIsWin11 installation"},
        @{Kind="File";Path="$env:ProgramData\ThisIsWin11\*";Description="ThisIsWin11 data"}
    );FixKeys=@("chkPrivacy","chkTaskbar","chkExplorer","chkStartMenu","chkServices")}
    @{Name="Sophia Script"; Indicators=@(
        @{Kind="Registry";Path="HKCU:\Software\Sophia Script";Description="Sophia Script user settings"},
        @{Kind="File";Path="$env:ProgramData\Sophia Script*";Description="Sophia Script data"},
        @{Kind="File";Path="$env:TEMP\Sophia*";Description="Sophia Script log or export"}
    );FixKeys=@("chkPrivacy","chkServices","chkTasks","chkNetwork","chkHostsFile")}
    @{Name="Win10Privacy"; Indicators=@(
        @{Kind="Registry";Path="HKCU:\Software\Win10Privacy";Description="Win10Privacy user settings"},
        @{Kind="File";Path="$env:ProgramFiles\Win10Privacy\*";Description="Win10Privacy installation"},
        @{Kind="File";Path="$env:ProgramData\Win10Privacy\*";Description="Win10Privacy data"}
    );FixKeys=@("chkPrivacy","chkServices","chkTasks","chkNetwork","chkHostsFile")}
)

$script:ServiceTaskFingerprintCatalog = @(
    @{Tool="O&O ShutUp10";Services=@("DiagTrack","dmwappushservice","WerSvc","WSearch","SysMain");Tasks=@(
        @{P="\Microsoft\Windows\Application Experience\";N="Microsoft Compatibility Appraiser"},
        @{P="\Microsoft\Windows\Customer Experience Improvement Program\";N="Consolidator"},
        @{P="\Microsoft\Windows\Feedback\Siuf\";N="DmClient"}
    )},
    @{Tool="WPD";Services=@("DiagTrack","dmwappushservice","lfsvc","MapsBroker");Tasks=@(
        @{P="\Microsoft\Windows\Application Experience\";N="ProgramDataUpdater"},
        @{P="\Microsoft\Windows\Maps\";N="MapsUpdateTask"}
    )},
    @{Tool="ThisIsWin11";Services=@("DiagTrack","WSearch","SysMain","WpnService");Tasks=@(
        @{P="\Microsoft\Windows\WindowsUpdate\";N="Scheduled Start"},
        @{P="\Microsoft\Windows\Windows Defender\";N="Windows Defender Scheduled Scan"}
    )},
    @{Tool="Sophia Script";Services=@("DiagTrack","dmwappushservice","WerSvc","WSearch","SysMain","MapsBroker");Tasks=@(
        @{P="\Microsoft\Windows\Application Experience\";N="StartupAppTask"},
        @{P="\Microsoft\Windows\Customer Experience Improvement Program\";N="KernelCeipTask"},
        @{P="\Microsoft\Windows\WindowsUpdate\";N="Scheduled Start"}
    )},
    @{Tool="Win10Privacy";Services=@("DiagTrack","dmwappushservice","WerSvc","WSearch","SysMain");Tasks=@(
        @{P="\Microsoft\Windows\Application Experience\";N="Microsoft Compatibility Appraiser"},
        @{P="\Microsoft\Windows\Customer Experience Improvement Program\";N="Consolidator"},
        @{P="\Microsoft\Windows\Feedback\Siuf\";N="DmClientOnScenarioDownload"}
    )}
)

$script:ScheduledTaskRestoreMatrix = @(
    @{Source="Windows maintenance";Tools=@("O&O ShutUp10","WPD","ThisIsWin11","Sophia Script","Win10Privacy");P="\Microsoft\Windows\Application Experience\";N="Microsoft Compatibility Appraiser";Category="chkTasks"},
    @{Source="Windows maintenance";Tools=@("WPD","Sophia Script");P="\Microsoft\Windows\Application Experience\";N="ProgramDataUpdater";Category="chkTasks"},
    @{Source="Windows maintenance";Tools=@("O&O ShutUp10","Sophia Script");P="\Microsoft\Windows\Application Experience\";N="StartupAppTask";Category="chkTasks"},
    @{Source="Customer experience";Tools=@("O&O ShutUp10","Sophia Script","Win10Privacy");P="\Microsoft\Windows\Customer Experience Improvement Program\";N="Consolidator";Category="chkTasks"},
    @{Source="Customer experience";Tools=@("Sophia Script");P="\Microsoft\Windows\Customer Experience Improvement Program\";N="KernelCeipTask";Category="chkTasks"},
    @{Source="Feedback";Tools=@("O&O ShutUp10","Win10Privacy");P="\Microsoft\Windows\Feedback\Siuf\";N="DmClient";Category="chkTasks"},
    @{Source="Feedback";Tools=@("Win10Privacy");P="\Microsoft\Windows\Feedback\Siuf\";N="DmClientOnScenarioDownload";Category="chkTasks"},
    @{Source="Windows Defender";Tools=@("ThisIsWin11");P="\Microsoft\Windows\Windows Defender\";N="Windows Defender Scheduled Scan";Category="chkDefender"},
    @{Source="Windows Update";Tools=@("ThisIsWin11","Sophia Script");P="\Microsoft\Windows\WindowsUpdate\";N="Scheduled Start";Category="chkWindowsUpdate"},
    @{Source="Maps";Tools=@("WPD");P="\Microsoft\Windows\Maps\";N="MapsUpdateTask";Category="chkTasks"}
)

function Initialize-RestoreBaselineCatalogMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object[]]$Catalog,
        [Parameter(Mandatory=$true)][string]$CatalogKind,
        [Parameter(Mandatory=$true)][string]$SourceUrl,
        [string]$PolicyMapping,
        [ValidateSet("High","Medium","Low")][string]$Confidence="Medium",
        [ValidateSet("ExplicitBaseline","ExplicitIndicator","InferredDefault")][string]$EvidenceType="ExplicitIndicator"
    )
    foreach ($entry in @($Catalog)) {
        $entry.CatalogSchemaVersion = $script:BaselineCatalogSchemaVersion
        $entry.CatalogVersion = $script:BaselineCatalogVersion
        $entry.CatalogKind = $CatalogKind
        $entry.SourceUrl = if ($entry.SourceUrl) { [string]$entry.SourceUrl } else { $SourceUrl }
        $entry.PolicyMapping = if ($entry.PolicyMapping) { [string]$entry.PolicyMapping } else { $PolicyMapping }
        $entry.SupportedProductFamilies = @($script:BaselineSupportedProductFamilies)
        $entry.SupportedBuildRangeByFamily = $script:BaselineBuildRangeByFamily
        $entry.SupportedBuildRange = $script:BaselineBuildRangeLabel
        $entry.SupportedEditions = @($script:BaselineSupportedEditions)
        $entry.Confidence = if ($entry.Confidence) { [string]$entry.Confidence } else { $Confidence }
        $entry.EvidenceType = if ($entry.EvidenceType) { [string]$entry.EvidenceType } else { $EvidenceType }
    }
}

$null = Initialize-RestoreBaselineCatalogMetadata -Catalog $script:RegistryDefaultCatalog -CatalogKind "RegistryDefault" -SourceUrl $script:BaselinePolicySourceUrl -PolicyMapping "Microsoft policy baseline; absence of the override represents the inferred default" -Confidence "High" -EvidenceType "InferredDefault"
foreach ($registryEntry in @($script:RegistryDefaultCatalog)) {
    $registryEntry.PolicyMapping = "Registry policy $($registryEntry.Path)\$($registryEntry.ValueName)"
}
$null = Initialize-RestoreBaselineCatalogMetadata -Catalog $script:CoreAppxPackageCatalog -CatalogKind "AppXBaseline" -SourceUrl $script:BaselineAppxSourceUrl -PolicyMapping "Windows inbox and Store package baseline" -Confidence "High" -EvidenceType "ExplicitBaseline"
foreach ($appxEntry in @($script:CoreAppxPackageCatalog)) {
    if ($appxEntry.Role -eq "Optional") { $appxEntry.Confidence = "Medium" }
}
$null = Initialize-RestoreBaselineCatalogMetadata -Catalog $script:DebloatToolFingerprints -CatalogKind "DebloatFingerprint" -SourceUrl $script:BaselineCatalogSourceUrl -PolicyMapping "Repository evidence indicator catalog" -Confidence "Medium" -EvidenceType "ExplicitIndicator"
$null = Initialize-RestoreBaselineCatalogMetadata -Catalog $script:ServiceTaskFingerprintCatalog -CatalogKind "ServiceTaskFingerprint" -SourceUrl $script:BaselineCatalogSourceUrl -PolicyMapping "Repository evidence service/task catalog" -Confidence "Medium" -EvidenceType "ExplicitIndicator"
$null = Initialize-RestoreBaselineCatalogMetadata -Catalog $script:ScheduledTaskRestoreMatrix -CatalogKind "ScheduledTaskBaseline" -SourceUrl $script:BaselineCatalogSourceUrl -PolicyMapping "Repository scheduled-task restoration matrix" -Confidence "Medium" -EvidenceType "ExplicitIndicator"

function Get-RestoreBaselineContext {
    [CmdletBinding()]
    param([object]$MachineProfile)
    $catalogMachineProfile = if ($MachineProfile) { $MachineProfile } elseif ($script:CapabilityProfile) { $script:CapabilityProfile } else {
        try { Get-RestoreMachineProfile } catch { $null }
    }
    $family = if ($catalogMachineProfile -and $catalogMachineProfile.PSObject.Properties["ProductFamily"]) { [string]$catalogMachineProfile.ProductFamily } else { $null }
    if ([string]::IsNullOrWhiteSpace($family) -and $catalogMachineProfile -and $catalogMachineProfile.PSObject.Properties["ProductName"]) {
        $family = if ([string]$catalogMachineProfile.ProductName -match "Windows\s+11") { "Windows 11" } elseif ([string]$catalogMachineProfile.ProductName -match "Windows\s+10") { "Windows 10" } else { $null }
    }
    $edition = $null
    foreach ($propertyName in @("Edition","EditionID","InstallationType")) {
        if ($catalogMachineProfile -and $catalogMachineProfile.PSObject.Properties[$propertyName] -and -not [string]::IsNullOrWhiteSpace([string]$catalogMachineProfile.$propertyName)) {
            $edition = [string]$catalogMachineProfile.$propertyName
            break
        }
    }
    $build = $null
    foreach ($propertyName in @("Build","CurrentBuild","CurrentBuildNumber")) {
        $candidate = 0
        if ($catalogMachineProfile -and $catalogMachineProfile.PSObject.Properties[$propertyName] -and [int]::TryParse([string]$catalogMachineProfile.$propertyName,[ref]$candidate)) {
            $build = $candidate
            break
        }
    }
    return [pscustomobject][ordered]@{
        Status=if ($family -and $edition -and $null -ne $build) { "Known" } else { "Unknown" }
        ProductFamily=$family; Edition=$edition; Build=$build; MachineProfile=$catalogMachineProfile
    }
}

function Get-RestoreCatalogValue {
    param([Parameter(Mandatory=$true)][object]$Entry,[Parameter(Mandatory=$true)][string]$Name)
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Name)) { return $Entry[$Name] }
    if ($Entry.PSObject.Properties[$Name]) { return $Entry.PSObject.Properties[$Name].Value }
    return $null
}

function Get-RestoreCatalogEntryEvaluation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$Entry,
        [Parameter(Mandatory=$true)][object]$Context
    )
    $catalogVersion = [string](Get-RestoreCatalogValue -Entry $Entry -Name "CatalogVersion")
    $sourceUrl = [string](Get-RestoreCatalogValue -Entry $Entry -Name "SourceUrl")
    $policyMapping = [string](Get-RestoreCatalogValue -Entry $Entry -Name "PolicyMapping")
    $families = @((Get-RestoreCatalogValue -Entry $Entry -Name "SupportedProductFamilies"))
    $buildRanges = Get-RestoreCatalogValue -Entry $Entry -Name "SupportedBuildRangeByFamily"
    $editions = @((Get-RestoreCatalogValue -Entry $Entry -Name "SupportedEditions"))
    $confidence = [string](Get-RestoreCatalogValue -Entry $Entry -Name "Confidence")
    $evidenceType = [string](Get-RestoreCatalogValue -Entry $Entry -Name "EvidenceType")
    $missing = @()
    if ([string]::IsNullOrWhiteSpace($catalogVersion)) { $missing += "catalog version" }
    if ([string]::IsNullOrWhiteSpace($sourceUrl) -and [string]::IsNullOrWhiteSpace($policyMapping)) { $missing += "source URL or policy mapping" }
    if ($families.Count -eq 0) { $missing += "supported product families" }
    if (-not $buildRanges) { $missing += "supported build range" }
    if ($editions.Count -eq 0) { $missing += "supported editions" }
    if ([string]::IsNullOrWhiteSpace($confidence)) { $missing += "confidence" }
    if ([string]::IsNullOrWhiteSpace($evidenceType)) { $missing += "evidence type" }
    $status = "Verified"
    $warning = $null
    if ($missing.Count -gt 0) {
        $status = "Unknown"
        $warning = "Catalog entry is missing: $($missing -join ', ')"
    } elseif ($Context.Status -ne "Known") {
        $status = "Unknown"
        $warning = "Operating-system build or edition is unknown; the entry is not eligible for automatic fixes"
    } elseif ($Context.ProductFamily -notin $families) {
        $status = "Unsupported"
        $warning = "Catalog does not support product family $($Context.ProductFamily)"
    } elseif ($editions -notcontains "All" -and $Context.Edition -notin $editions) {
        $status = "Unsupported"
        $warning = "Catalog does not support edition $($Context.Edition)"
    } else {
        $range = if ($buildRanges -is [System.Collections.IDictionary]) { $buildRanges[$Context.ProductFamily] } else { $null }
        if (-not $range) {
            $status = "Unsupported"
            $warning = "Catalog has no build range for product family $($Context.ProductFamily)"
        } elseif ($Context.Build -lt [int]$range.Minimum -or ($null -ne $range.Maximum -and $Context.Build -gt [int]$range.Maximum)) {
            $status = "Unsupported"
            $warning = "Build $($Context.Build) is outside the catalog range for $($Context.ProductFamily)"
        }
    }
    return [pscustomobject][ordered]@{
        CatalogSchemaVersion=Get-RestoreCatalogValue -Entry $Entry -Name "CatalogSchemaVersion"
        CatalogVersion=$catalogVersion; CatalogKind=[string](Get-RestoreCatalogValue -Entry $Entry -Name "CatalogKind")
        SourceUrl=$sourceUrl; PolicyMapping=$policyMapping
        SupportedProductFamilies=$families; SupportedBuildRange=[string](Get-RestoreCatalogValue -Entry $Entry -Name "SupportedBuildRange")
        SupportedBuildRangeByFamily=$buildRanges; SupportedEditions=$editions
        Confidence=$confidence; EvidenceType=$evidenceType
        CatalogStatus=$status; CanAutoFix=($status -eq "Verified"); Warning=$warning
    }
}

function Get-RestoreBaselineCatalogReport {
    [CmdletBinding()]
    param([object]$MachineProfile)
    $context = Get-RestoreBaselineContext -MachineProfile $MachineProfile
    $catalogSets = @(
        [pscustomobject]@{Kind="RegistryDefault";Entries=@($script:RegistryDefaultCatalog);NameProperty="Name"},
        [pscustomobject]@{Kind="AppXBaseline";Entries=@($script:CoreAppxPackageCatalog);NameProperty="Name"},
        [pscustomobject]@{Kind="DebloatFingerprint";Entries=@($script:DebloatToolFingerprints);NameProperty="Name"},
        [pscustomobject]@{Kind="ServiceTaskFingerprint";Entries=@($script:ServiceTaskFingerprintCatalog);NameProperty="Tool"},
        [pscustomobject]@{Kind="ScheduledTaskBaseline";Entries=@($script:ScheduledTaskRestoreMatrix);NameProperty="N"}
    )
    $entries = @()
    foreach ($catalogSet in $catalogSets) {
        foreach ($entry in @($catalogSet.Entries)) {
            $evaluation = Get-RestoreCatalogEntryEvaluation -Entry $entry -Context $context
            $nameValue = Get-RestoreCatalogValue -Entry $entry -Name $catalogSet.NameProperty
            $name = if ($null -ne $nameValue) { [string]$nameValue } else { $catalogSet.Kind }
            $entries += [pscustomobject][ordered]@{
                CatalogKind=$catalogSet.Kind; Name=$name; CatalogSchemaVersion=$evaluation.CatalogSchemaVersion
                CatalogVersion=$evaluation.CatalogVersion; SourceUrl=$evaluation.SourceUrl; PolicyMapping=$evaluation.PolicyMapping
                SupportedProductFamilies=$evaluation.SupportedProductFamilies; SupportedBuildRange=$evaluation.SupportedBuildRange
                SupportedEditions=$evaluation.SupportedEditions; Confidence=$evaluation.Confidence
                EvidenceType=$evaluation.EvidenceType; CatalogStatus=$evaluation.CatalogStatus
                CanAutoFix=$evaluation.CanAutoFix; Warning=$evaluation.Warning
            }
        }
    }
    $warnings = @($entries | Where-Object { $_.CatalogStatus -ne "Verified" })
    return [pscustomobject][ordered]@{
        SchemaVersion=$script:BaselineCatalogSchemaVersion; CatalogVersion=$script:BaselineCatalogVersion
        CapturedAtUtc=(Get-Date).ToUniversalTime().ToString("o"); Status=if ($warnings.Count) { "Warnings" } else { "Ready" }
        SourceUrl=$script:BaselineCatalogSourceUrl; Context=$context; Entries=@($entries); Warnings=$warnings
    }
}

function Get-DebloatToolFingerprintReport {
    param(
        [object[]]$Catalog = $script:DebloatToolFingerprints,
        [switch]$IncludeUndetected,
        [object]$MachineProfile
    )
    $context = Get-RestoreBaselineContext -MachineProfile $MachineProfile
    $reports = @()
    foreach ($tool in $Catalog) {
        $catalog = Get-RestoreCatalogEntryEvaluation -Entry $tool -Context $context
        $evidence = @()
        foreach ($indicator in @($tool.Indicators)) {
            try {
                $matched = $false
                switch ($indicator.Kind) {
                    "Registry" { $matched = Test-Path -LiteralPath $indicator.Path }
                    "File" { $matched = Test-Path -Path $indicator.Path }
                }
                if ($matched) { $evidence += $indicator.Description + ": " + $indicator.Path }
            } catch { Write-Verbose "Could not inspect fingerprint indicator $($indicator.Path)" }
        }
        $detected = $evidence.Count -gt 0
        if ($detected -or $IncludeUndetected) {
            $confidence = if ($evidence.Count -ge 2) { "High" } elseif ($detected) { "Medium" } else { "None" }
            $reports += [pscustomobject][ordered]@{
                Tool=$tool.Name; Detected=$detected; Confidence=$confidence; CatalogConfidence=$catalog.Confidence
                Evidence=@($evidence); FixKeys=if($catalog.CanAutoFix){@($tool.FixKeys)}else{@()}
                CatalogSchemaVersion=$catalog.CatalogSchemaVersion; CatalogVersion=$catalog.CatalogVersion; CatalogKind=$catalog.CatalogKind
                SourceUrl=$catalog.SourceUrl; PolicyMapping=$catalog.PolicyMapping; SupportedProductFamilies=$catalog.SupportedProductFamilies
                SupportedBuildRange=$catalog.SupportedBuildRange; SupportedEditions=$catalog.SupportedEditions
                EvidenceType=$catalog.EvidenceType; CatalogStatus=$catalog.CatalogStatus; CanAutoFix=$catalog.CanAutoFix
                Warning=$catalog.Warning
            }
        }
    }
    return @($reports)
}

function Get-ScheduledTaskRestoreMatrix {
    param(
        [object[]]$Matrix = $script:ScheduledTaskRestoreMatrix,
        [switch]$IncludeHealthy,
        [scriptblock]$TaskProvider,
        [object]$MachineProfile
    )
    $context = Get-RestoreBaselineContext -MachineProfile $MachineProfile
    $results = @()
    foreach ($entry in $Matrix) {
        $catalog = Get-RestoreCatalogEntryEvaluation -Entry $entry -Context $context
        $task = $null
        try {
            if ($TaskProvider) { $task = & $TaskProvider $entry.P $entry.N }
            else { $task = Get-ScheduledTask -TaskPath $entry.P -TaskName $entry.N -ErrorAction Stop }
        } catch { $task = $null }
        $state = if (-not $task) { "Missing" } elseif ($task.State -and $task.State.ToString() -eq "Disabled") { "Disabled" } else { "Enabled" }
        if ($IncludeHealthy -or $state -ne "Enabled") {
            $results += [pscustomobject][ordered]@{
                ToolSources=@($entry.Tools); Source=$entry.Source; Path=$entry.P; Name=$entry.N
                Category=$entry.Category; State=$state; NeedsRestore=($state -eq "Disabled")
                CatalogSchemaVersion=$catalog.CatalogSchemaVersion; CatalogVersion=$catalog.CatalogVersion; CatalogKind=$catalog.CatalogKind
                SourceUrl=$catalog.SourceUrl; PolicyMapping=$catalog.PolicyMapping; SupportedProductFamilies=$catalog.SupportedProductFamilies
                SupportedBuildRange=$catalog.SupportedBuildRange; SupportedEditions=$catalog.SupportedEditions
                Confidence=$catalog.Confidence; EvidenceType=$catalog.EvidenceType; CatalogStatus=$catalog.CatalogStatus
                CanAutoFix=$catalog.CanAutoFix; Warning=$catalog.Warning
            }
        }
    }
    return @($results)
}

function Get-ServiceTaskFingerprintReport {
    param(
        [object[]]$Catalog = $script:ServiceTaskFingerprintCatalog,
        [switch]$IncludeHealthy,
        [scriptblock]$ServiceProvider,
        [scriptblock]$TaskProvider,
        [object]$MachineProfile
    )
    $context = Get-RestoreBaselineContext -MachineProfile $MachineProfile
    $results = @()
    foreach ($definition in $Catalog) {
        $catalog = Get-RestoreCatalogEntryEvaluation -Entry $definition -Context $context
        foreach ($serviceName in @($definition.Services)) {
            $service = $null
            try {
                if ($ServiceProvider) { $service = & $ServiceProvider $serviceName }
                else { $service = Get-Service -Name $serviceName -ErrorAction Stop }
            } catch { $service = $null }
            if ($service) {
                $disabled = $service.StartType.ToString() -eq "Disabled"
                if ($IncludeHealthy -or $disabled) {
                    $results += [pscustomobject][ordered]@{
                        Tool=$definition.Tool; Kind="Service"; Name=$serviceName
                        Path=$null; State=$service.StartType.ToString(); NeedsRestore=$disabled
                        CatalogSchemaVersion=$catalog.CatalogSchemaVersion; CatalogVersion=$catalog.CatalogVersion; CatalogKind=$catalog.CatalogKind
                        SourceUrl=$catalog.SourceUrl; PolicyMapping=$catalog.PolicyMapping; SupportedProductFamilies=$catalog.SupportedProductFamilies
                        SupportedBuildRange=$catalog.SupportedBuildRange; SupportedEditions=$catalog.SupportedEditions
                        Confidence=$catalog.Confidence; EvidenceType=$catalog.EvidenceType; CatalogStatus=$catalog.CatalogStatus
                        CanAutoFix=$catalog.CanAutoFix; Warning=$catalog.Warning
                    }
                }
            }
        }
        foreach ($taskInfo in @($definition.Tasks)) {
            $task = $null
            try {
                if ($TaskProvider) { $task = & $TaskProvider $taskInfo.P $taskInfo.N }
                else { $task = Get-ScheduledTask -TaskPath $taskInfo.P -TaskName $taskInfo.N -ErrorAction Stop }
            } catch { $task = $null }
            if ($task) {
                $disabled = $task.State -and $task.State.ToString() -eq "Disabled"
                if ($IncludeHealthy -or $disabled) {
                    $results += [pscustomobject][ordered]@{
                        Tool=$definition.Tool; Kind="Task"; Name=$taskInfo.N
                        Path=$taskInfo.P; State=$task.State.ToString(); NeedsRestore=$disabled
                        CatalogSchemaVersion=$catalog.CatalogSchemaVersion; CatalogVersion=$catalog.CatalogVersion; CatalogKind=$catalog.CatalogKind
                        SourceUrl=$catalog.SourceUrl; PolicyMapping=$catalog.PolicyMapping; SupportedProductFamilies=$catalog.SupportedProductFamilies
                        SupportedBuildRange=$catalog.SupportedBuildRange; SupportedEditions=$catalog.SupportedEditions
                        Confidence=$catalog.Confidence; EvidenceType=$catalog.EvidenceType; CatalogStatus=$catalog.CatalogStatus
                        CanAutoFix=$catalog.CanAutoFix; Warning=$catalog.Warning
                    }
                }
            }
        }
    }
    return @($results)
}

function ConvertTo-SnapshotRegistryPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $normalized = $Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    $normalized = $normalized -replace '^HKEY_LOCAL_MACHINE', 'HKLM:'
    $normalized = $normalized -replace '^HKEY_CURRENT_USER', 'HKCU:'
    $normalized = $normalized -replace '^HKEY_CLASSES_ROOT', 'HKCR:'
    $normalized = $normalized -replace '^HKEY_USERS', 'HKU:'
    return $normalized
}

function Get-RegistrySnapshot {
    param([string[]]$Path = $script:RegistrySnapshotPaths)
    $entries = New-Object System.Collections.Generic.List[object]
    $seenKeys = @{}
    foreach ($root in @($Path)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $keys = @()
        try { $keys += Get-Item -LiteralPath $root -ErrorAction Stop } catch { Write-Verbose "Could not read registry root $root" }
        try { $keys += @(Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue) } catch { Write-Verbose "Could not enumerate registry root $root" }
        foreach ($key in $keys) {
            $keyPath = ConvertTo-SnapshotRegistryPath -Path ([string]$key.PSPath)
            if ($seenKeys.ContainsKey($keyPath)) { continue }
            $seenKeys[$keyPath] = $true
            $propertyNames = @($key.Property | Where-Object { $_ -and $_ -notmatch '^PS' })
            if ($propertyNames.Count -eq 0) { continue }
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            foreach ($propertyName in $propertyNames) {
                $value = $properties.$propertyName
                $valueType = if ($value -is [byte[]]) { "Binary" }
                    elseif ($value -is [string[]]) { "MultiString" }
                    elseif ($value -is [long] -or $value -is [int64]) { "QWord" }
                    elseif ($value -is [int] -or $value -is [int32] -or $value -is [bool]) { "DWord" }
                    else { "String" }
                $entries.Add([pscustomobject][ordered]@{
                    Path=$keyPath; Name=[string]$propertyName; Type=$valueType; Value=$value
                })
            }
        }
    }
    $entryArray = @($entries.ToArray())
    return [pscustomobject][ordered]@{
        SchemaVersion=$script:RegistrySnapshotSchemaVersion
        CreatedAt=(Get-Date).ToUniversalTime().ToString("o")
        ComputerName=$env:COMPUTERNAME
        Entries=$entryArray
    }
}

function Export-RegistrySnapshot {
    param(
        [Parameter(Mandatory=$true)][string]$OutputPath,
        [string[]]$Path = $script:RegistrySnapshotPaths
    )
    $snapshot = Get-RegistrySnapshot -Path $Path
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $fullPath = [System.IO.Path]::GetFullPath($OutputPath)
    $json = $snapshot | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($fullPath, $json, [System.Text.Encoding]::UTF8)
    return $snapshot
}

function Import-RegistrySnapshot {
    param([Parameter(Mandatory=$true)][string]$InputPath)
    if (-not (Test-Path -LiteralPath $InputPath)) { throw "Snapshot not found: $InputPath" }
    $snapshot = Get-Content -LiteralPath $InputPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($snapshot.SchemaVersion -ne $script:RegistrySnapshotSchemaVersion) {
        throw "Unsupported registry snapshot schema: $($snapshot.SchemaVersion)"
    }
    if (-not $snapshot.PSObject.Properties['Entries']) { throw "Snapshot is missing Entries" }
    return $snapshot
}

function Compare-RegistrySnapshot {
    param(
        [Parameter(Mandatory=$true)]$Before,
        [Parameter(Mandatory=$true)]$After
    )
    if ($Before -is [string]) {
        if ([System.IO.Path]::GetExtension($Before) -ieq ".reg") { $Before = Import-RegExportSnapshot -RegPath $Before }
        else { $Before = Import-RegistrySnapshot -InputPath $Before }
    }
    if ($After -is [string]) {
        if ([System.IO.Path]::GetExtension($After) -ieq ".reg") { $After = Import-RegExportSnapshot -RegPath $After }
        else { $After = Import-RegistrySnapshot -InputPath $After }
    }
    $beforeMap = @{}; $afterMap = @{}
    foreach ($entry in @($Before.Entries)) { $beforeMap["$($entry.Path)|$($entry.Name)"] = $entry }
    foreach ($entry in @($After.Entries)) { $afterMap["$($entry.Path)|$($entry.Name)"] = $entry }
    $added = @(); $removed = @(); $changed = @()
    foreach ($key in $afterMap.Keys) {
        if (-not $beforeMap.ContainsKey($key)) {
            $added += [pscustomobject]@{Kind="Added";Path=$afterMap[$key].Path;Name=$afterMap[$key].Name;Before=$null;After=$afterMap[$key]}
        } else {
            $beforeValue = $beforeMap[$key] | ConvertTo-Json -Depth 12 -Compress
            $afterValue = $afterMap[$key] | ConvertTo-Json -Depth 12 -Compress
            if ($beforeValue -ne $afterValue) {
                $changed += [pscustomobject]@{Kind="Changed";Path=$afterMap[$key].Path;Name=$afterMap[$key].Name;Before=$beforeMap[$key];After=$afterMap[$key]}
            }
        }
    }
    foreach ($key in $beforeMap.Keys) {
        if (-not $afterMap.ContainsKey($key)) {
            $removed += [pscustomobject]@{Kind="Removed";Path=$beforeMap[$key].Path;Name=$beforeMap[$key].Name;Before=$beforeMap[$key];After=$null}
        }
    }
    return [pscustomobject][ordered]@{
        SchemaVersion=$script:RegistrySnapshotSchemaVersion
        Added=@($added); Removed=@($removed); Changed=@($changed)
        TotalChanges=$added.Count + $removed.Count + $changed.Count
        Summary="Added $($added.Count), removed $($removed.Count), changed $($changed.Count) registry values"
    }
}

function Get-AppxPackageRemovalReport {
    param(
        [object[]]$ExpectedPackages = $script:CoreAppxPackageCatalog,
        [object[]]$InstalledPackages,
        [object[]]$ProvisionedPackages,
        [object]$MachineProfile
    )
    $context = Get-RestoreBaselineContext -MachineProfile $MachineProfile
    if ($PSBoundParameters.ContainsKey('InstalledPackages')) { $installed = @($InstalledPackages) }
    else { $installed = @(Get-AppxPackageSafe) }
    if ($PSBoundParameters.ContainsKey('ProvisionedPackages')) { $provisioned = @($ProvisionedPackages) }
    else {
        try { $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { $provisioned = @() }
    }
    $installedNames = @($installed | ForEach-Object {
        if ($_.Name) { [string]$_.Name } elseif ($_.PackageName) { [string]$_.PackageName } else { [string]$_ }
    })
    $provisionedNames = @($provisioned | ForEach-Object {
        if ($_.DisplayName) { [string]$_.DisplayName } elseif ($_.PackageName) { [string]$_.PackageName } else { [string]$_ }
    })
    $missing = @(); $present = @(); $provisionedOnly = @(); $findings = @()
    foreach ($expected in @($ExpectedPackages)) {
        $name = if ($expected -is [string]) { $expected } elseif ($expected.Name) { [string]$expected.Name } else { [string]$expected }
        $role = if ($expected -is [string]) { $null } else { [string](Get-RestoreCatalogValue -Entry $expected -Name "Role") }
        $catalog = if ($expected -is [string]) {
            [pscustomobject][ordered]@{CatalogSchemaVersion=$null;CatalogVersion=$null;CatalogKind=$null;SourceUrl=$null;PolicyMapping=$null;SupportedProductFamilies=@();SupportedBuildRange=$null;SupportedEditions=@();Confidence=$null;EvidenceType=$null;CatalogStatus="Unknown";CanAutoFix=$false;Warning="Package is not linked to a versioned baseline catalog"}
        } else { Get-RestoreCatalogEntryEvaluation -Entry $expected -Context $context }
        $installedMatch = @($installedNames | Where-Object { $_ -eq $name -or $_ -like ($name + "_*") }).Count -gt 0
        $provisionedMatch = @($provisionedNames | Where-Object { $_ -eq $name -or $_ -like ($name + "_*") }).Count -gt 0
        $status = if ($installedMatch) { "Present" } elseif ($provisionedMatch) { "ProvisionedOnly" } else { "Missing" }
        if ($status -eq "Present") { $present += $name }
        elseif ($status -eq "ProvisionedOnly") { $provisionedOnly += $name }
        else { $missing += $name }
        $findings += [pscustomobject][ordered]@{
            Name=$name; Role=$role; Status=$status; CatalogSchemaVersion=$catalog.CatalogSchemaVersion
            CatalogVersion=$catalog.CatalogVersion; CatalogKind=$catalog.CatalogKind; SourceUrl=$catalog.SourceUrl
            PolicyMapping=$catalog.PolicyMapping; SupportedProductFamilies=$catalog.SupportedProductFamilies
            SupportedBuildRange=$catalog.SupportedBuildRange; SupportedEditions=$catalog.SupportedEditions
            Confidence=$catalog.Confidence; EvidenceType=$catalog.EvidenceType; CatalogStatus=$catalog.CatalogStatus
            CanAutoFix=$catalog.CanAutoFix; Warning=$catalog.Warning
        }
    }
    $catalogWarnings = @($findings | Where-Object { $_.CatalogStatus -ne "Verified" })
    $confidence = if ($catalogWarnings.Count) { "Unknown" } elseif (@($findings | Where-Object Confidence -eq "Medium").Count) { "Medium" } else { "High" }
    return [pscustomobject][ordered]@{
        ExpectedCount=@($ExpectedPackages).Count; InstalledCount=$installedNames.Count
        ProvisionedCount=$provisionedNames.Count; Present=@($present)
        ProvisionedOnly=@($provisionedOnly); Missing=@($missing)
        MissingCount=$missing.Count; ProvisionedOnlyCount=$provisionedOnly.Count
        SchemaVersion=$script:BaselineCatalogSchemaVersion; CatalogVersion=$script:BaselineCatalogVersion
        CatalogKind="AppXBaseline"; CatalogStatus=if($catalogWarnings.Count){"Warnings"}else{"Verified"}
        Confidence=$confidence; CanAutoFix=($catalogWarnings.Count -eq 0); Findings=@($findings)
        UnknownExpectedPackages=@($catalogWarnings.Name); Warnings=@($catalogWarnings | ForEach-Object { $_.Warning })
    }
}

function Compare-AppxPackageBaseline {
    param(
        [string]$BaselinePath,
        [string]$WimPath,
        [int]$ImageIndex = 1,
        [object[]]$InstalledPackages,
        [object[]]$ProvisionedPackages
    )
    $baselineNames = @()
    if ($BaselinePath) {
        $baseline = Get-Content -LiteralPath $BaselinePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $items = if ($baseline.PSObject.Properties['Packages']) { $baseline.Packages } else { $baseline }
        $baselineNames = @($items | ForEach-Object {
            if ($_ -is [string]) { $_ } elseif ($_.DisplayName) { $_.DisplayName } elseif ($_.PackageName) { $_.PackageName } elseif ($_.Name) { $_ } else { [string]$_ }
        })
    } elseif ($WimPath) {
        if (-not (Test-Path -LiteralPath $WimPath)) { throw "WIM not found: $WimPath" }
        $dism = Get-Command dism.exe -ErrorAction SilentlyContinue
        if (-not $dism) { throw "DISM is unavailable; cannot inspect the WIM baseline" }
        $dismOutput = @(& $dism.Source /English /ImageFile:$WimPath /Index:$ImageIndex /Get-ProvisionedAppxPackages 2>&1)
        $baselineNames = @($dismOutput | ForEach-Object {
            if ($_ -match 'PackageName\s*:\s*(\S+)') { $Matches[1] }
        })
    } else { throw "Specify BaselinePath or WimPath" }
    $report = Get-AppxPackageRemovalReport -ExpectedPackages $baselineNames -InstalledPackages $InstalledPackages -ProvisionedPackages $ProvisionedPackages
    $report | Add-Member -NotePropertyName BaselinePath -NotePropertyValue $BaselinePath
    $report | Add-Member -NotePropertyName WimPath -NotePropertyValue $WimPath
    return $report
}

# ============================================================================
# RESTORATION DEPTH AND OPERATIONS
# ============================================================================

function Get-PolicyManagementState {
    $domainJoined = $false
    $domainKnown = $false
    $queryErrors = New-Object System.Collections.Generic.List[string]
    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $domainJoined = [bool]$computerSystem.PartOfDomain
        $domainKnown = $true
    } catch {
        $queryErrors.Add("Domain membership query failed: $($_.Exception.Message)")
    }
    $mdmPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Enrollments",
        "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts",
        "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device"
    )
    $mdmSignals = @()
    foreach ($mdmPath in $mdmPaths) {
        try {
            if (Test-Path -LiteralPath $mdmPath) { $mdmSignals += $mdmPath }
        } catch { $queryErrors.Add("Management signal query failed for $mdmPath") }
    }
    $mdmEnrolled = $mdmSignals.Count -gt 0
    return [pscustomobject][ordered]@{
        SchemaVersion=$script:CapabilitySchemaVersion
        DomainJoined=$domainJoined; MdmEnrolled=$mdmEnrolled
        IsManaged=($domainJoined -or $mdmEnrolled)
        IsKnown=($domainKnown -and $queryErrors.Count -eq 0)
        Signals=@($mdmSignals)
        QueryErrors=@($queryErrors)
        Ownership=if ($domainJoined -or $mdmEnrolled) { "Organization" } else { "Local" }
        ComputerName=$env:COMPUTERNAME
    }
}

function Get-EdgePolicyState {
    $machinePath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    $userPath = "HKCU:\SOFTWARE\Policies\Microsoft\Edge"
    $machinePolicies = @(); $userPolicies = @()
    if (Test-Path -LiteralPath $machinePath) { $machinePolicies = @((Get-Item -LiteralPath $machinePath -ErrorAction SilentlyContinue).Property) }
    if (Test-Path -LiteralPath $userPath) { $userPolicies = @((Get-Item -LiteralPath $userPath -ErrorAction SilentlyContinue).Property) }
    $management = Get-PolicyManagementState
    $hasPolicies = ($machinePolicies.Count + $userPolicies.Count) -gt 0
    $source = if (-not $hasPolicies) { "None" }
        elseif ($management.IsManaged -and $machinePolicies.Count) { "Managed machine policy" }
        elseif ($machinePolicies.Count) { "Local machine policy" }
        else { "User policy" }
    return [pscustomobject][ordered]@{
        Managed=($management.IsManaged -and $machinePolicies.Count -gt 0)
        HasPolicies=$hasPolicies; Source=$source
        MachinePolicies=@($machinePolicies); UserPolicies=@($userPolicies)
        DomainJoined=$management.DomainJoined; MdmEnrolled=$management.MdmEnrolled
    }
}

function Reset-WindowsUpdateChannelAndDeferral {
    [CmdletBinding(SupportsShouldProcess=$true)]
    [OutputType([bool])]
    param([switch]$ForceManaged)
    if (-not $PSCmdlet.ShouldProcess("Windows Update policy and deferral state", "reset")) { return $false }
    $management = Get-PolicyManagementState
    $policyRoots = @(
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching",
        "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    )
    if ($management.IsManaged -and -not $ForceManaged) {
        Write-Log "Managed policy state detected; preserving policy containers and removing only explicit pause/deferral values" -Level Warning
    } else {
        foreach ($root in $policyRoots) { Remove-RegistryKey -Path $root -Silent }
    }
    $policyValues = @(
        "NoAutoUpdate","AUOptions","UseWUServer","WUServer","WUStatusServer",
        "DeferFeatureUpdates","DeferFeatureUpdatesPeriodInDays","DeferQualityUpdates",
        "DeferQualityUpdatesPeriodInDays","BranchReadinessLevel","TargetReleaseVersion",
        "TargetReleaseVersionInfo","ProductVersion","ManagePreviewBuilds",
        "ManagePreviewBuildsPolicyValue","PauseFeatureUpdatesStartTime",
        "PauseQualityUpdatesStartTime","PauseUpdatesStartTime","PauseUpdatesExpiryTime",
        "FlightSettingsMaxPauseDays","ConfigureDeadlineForFeatureUpdates",
        "ConfigureDeadlineForQualityUpdates","ConfigureDeadlineGracePeriod",
        "ConfigureDeadlineNoAutoReboot"
    )
    foreach ($path in @(
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU",
        "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate",
        "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings",
        "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\Settings",
        "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\PolicyState"
    )) {
        foreach ($name in $policyValues) { Remove-RegistryValue -Path $path -Name $name -Silent }
    }
    foreach ($name in @("Pause","PauseFeatureUpdates","PauseQualityUpdates","RequireDeferUpgrade","DeferFeatureUpdatesPeriodInDays","DeferQualityUpdatesPeriodInDays")) {
        Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Update\$name" -Name "value" -Silent
    }
    Write-Log "Windows Update channel, release targeting, and deferral state reset" -Level Success
}

function Restore-SecurityCenterFullReset {
    param([switch]$ForceManaged)
    Write-Log "=== WINDOWS SECURITY CENTER FULL RESET ===" -Level Section
    Restore-DefenderSettings
    Restore-FirewallSettings
    Restore-SmartScreenSettings
    Restore-WindowsUpdateSettings -ForceManaged:$ForceManaged
    Restore-WindowsSecurityUI
    Write-Log "Windows Security Center full reset: Complete" -Level Success
}

function Restore-DefenderCpuCap {
    Write-Log "=== DEFENDER CPU CAP ===" -Level Section
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Scan" -Name "AvgCPULoadFactor" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows Defender\Scan" -Name "AvgCPULoadFactor" -Silent
    Write-Log "Defender CPU cap removed; Windows will manage scan scheduling" -Level Success
}

function Restore-SearchIndexer {
    param([switch]$Rebuild)
    Write-Log "=== SEARCH INDEXER ===" -Level Section
    Restore-ServiceStartup -ServiceName "WSearch" -StartupType "Automatic" -Silent
    try {
        $service = Get-Service -Name "WSearch" -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq "Stopped") { Invoke-RestoreServiceControl -Action Start -ServiceName "WSearch" -Silent }
    } catch { Write-Log "Could not start Windows Search; reboot may be required" -Level Warning }
    if ($Rebuild) {
        $indexPath = "$env:ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb"
        if (Test-Path -LiteralPath $indexPath) {
            try {
                Invoke-RestoreServiceControl -Action Stop -ServiceName "WSearch" -Silent
                $backupPath = "$indexPath.restore-backup"
                Invoke-RestoreFileMutation -Action Move -Path $indexPath -Destination $backupPath -Silent
                Write-Log "Search index moved to $(Split-Path $backupPath -Leaf); Windows Search will rebuild it" -Level Success
                Invoke-RestoreServiceControl -Action Start -ServiceName "WSearch" -Silent
            } catch { Write-Log "Search index rebuild was partial: $($_.Exception.Message)" -Level Warning }
        } else { Write-Log "Search index database was not present; Windows Search will create it" -Level Info }
    }
    Write-Log "Search Indexer: Complete" -Level Success
}

function Restore-StoreWingetServiceChain {
    Write-Log "=== STORE AND WINGET SERVICE CHAIN ===" -Level Section
    @(
        @{N="AppXSvc";T="Manual"}, @{N="ClipSVC";T="Manual"},
        @{N="LicenseManager";T="Manual"}, @{N="InstallService";T="Manual"},
        @{N="BITS";T="Manual"}, @{N="wuauserv";T="Manual"},
        @{N="DoSvc";T="Automatic"}
    ) | ForEach-Object { Restore-ServiceStartup -ServiceName $_.N -StartupType $_.T -Silent }
    @(
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore";N="RemoveWindowsStore"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore";N="DisableStoreApps"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore";N="AutoDownload"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore";N="RequirePrivateStoreOnly"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx";N="BlockNonAdminUserInstall"}
    ) | ForEach-Object { Remove-RegistryValue -Path $_.P -Name $_.N -Silent }
    foreach ($packageName in @("Microsoft.WindowsStore","Microsoft.DesktopAppInstaller","Microsoft.StorePurchaseApp")) {
        foreach ($package in @(Get-AppxPackageSafe -Name $packageName -AllUsers)) {
            $manifest = if ($package.InstallLocation) { Join-Path $package.InstallLocation "AppxManifest.xml" } else { $null }
            if ($manifest -and (Test-Path -LiteralPath $manifest)) {
                try {
                    $registration = Invoke-RestoreAppxRegistration -PackageName $packageName -ManifestPath $manifest -Scope "AllUsers" -Silent
                    if ($registration.Success -or $registration.Planned) { Write-Log "Re-registered $packageName" -Level Success }
                } catch { Write-Log "Could not re-register $packageName" -Level Warning }
            }
        }
    }
    Write-Log "Store and WinGet service chain: Complete" -Level Success
}

function Restore-DevicePrivacySlider {
    Write-Log "=== CAMERA, MICROPHONE, AND BLUETOOTH PRIVACY ===" -Level Section
    $capabilities = @("webcam","microphone","bluetooth","location","radios")
    foreach ($capability in $capabilities) {
        Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccess$capability" -Silent
        Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccess$($capability)_UserInControlOfTheseApps" -Silent
        Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$capability" -Name "Value" -Silent
        Remove-RegistryKey -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$capability\NonPackaged" -Silent
    }
    Write-Log "Device privacy sliders reset to Windows-managed defaults" -Level Success
}

function Get-AccountSignInState {
    $azureJoined = $false; $workplaceJoined = $false; $dsregDomainJoined = $false
    try {
        $dsregOutput = @(& dsregcmd.exe /status 2>$null)
        foreach ($line in $dsregOutput) {
            if ($line -match 'AzureAdJoined\s*:\s*YES') { $azureJoined = $true }
            if ($line -match 'WorkplaceJoined\s*:\s*YES') { $workplaceJoined = $true }
            if ($line -match 'DomainJoined\s*:\s*YES') { $dsregDomainJoined = $true }
        }
    } catch { Write-Verbose "dsregcmd.exe was unavailable or did not return account state" }
    $management = Get-PolicyManagementState
    $kind = if ($azureJoined) { "Azure AD / Microsoft account capable" }
        elseif ($dsregDomainJoined -or $management.DomainJoined) { "Domain account" }
        elseif ($workplaceJoined) { "Workplace account" }
        else { "Local account or unjoined device" }
    return [pscustomobject][ordered]@{
        AccountKind=$kind; AzureAdJoined=$azureJoined; WorkplaceJoined=$workplaceJoined
        DomainJoined=($dsregDomainJoined -or $management.DomainJoined)
        UserName="$env:USERDOMAIN\$env:USERNAME"
    }
}

function Restore-AccountSignIn {
    Write-Log "=== ACCOUNT SIGN-IN COMPONENTS ===" -Level Section
    $state = Get-AccountSignInState
    Write-Log "Detected sign-in context: $($state.AccountKind) ($($state.UserName))" -Level Info
    @(
        @{N="wlidsvc";T="Manual"}, @{N="TokenBroker";T="Manual"},
        @{N="NgcSvc";T="Manual"}, @{N="NgcCtnrSvc";T="Manual"},
        @{N="UserManager";T="Automatic"}, @{N="ProfSvc";T="Automatic"}
    ) | ForEach-Object { Restore-ServiceStartup -ServiceName $_.N -StartupType $_.T -Silent }
    @(
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";N="BlockUserFromShowingAccountDetailsOnSignin"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";N="DontDisplayNetworkSelectionUI"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork";N="Enabled"},
        @{P="HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions";N="value"}
    ) | ForEach-Object { Remove-RegistryValue -Path $_.P -Name $_.N -Silent }
    Write-Log "Account sign-in components restored without changing account membership" -Level Success
}

function Get-MissingTaskRegistrationPlan {
    param(
        [object[]]$Matrix = $script:ScheduledTaskRestoreMatrix,
        [scriptblock]$TaskProvider,
        [scriptblock]$FileExistsProvider
    )
    $matrixReport = @(Get-ScheduledTaskRestoreMatrix -Matrix $Matrix -TaskProvider $TaskProvider)
    $plan = @()
    foreach ($item in @($matrixReport | Where-Object { $_.State -eq "Missing" })) {
        $xmlPath = Join-Path "$env:WINDIR\System32\Tasks" ($item.Path.TrimStart("\") + $item.Name)
        $exists = if ($FileExistsProvider) { & $FileExistsProvider $xmlPath } else { Test-Path -LiteralPath $xmlPath }
        if ($exists) {
            $plan += [pscustomobject][ordered]@{
                TaskName=($item.Path + $item.Name); XmlPath=$xmlPath; Category=$item.Category
                ToolSources=@($item.ToolSources)
            }
        }
    }
    return @($plan)
}

function Restore-MissingScheduledTask {
    param([object[]]$Matrix = $script:ScheduledTaskRestoreMatrix)
    $plan = @(Get-MissingTaskRegistrationPlan -Matrix $Matrix)
    foreach ($item in $plan) {
        try {
            $registration = Invoke-RestoreNativeCommand -FilePath "schtasks.exe" -ArgumentList @("/Create","/TN",$item.TaskName,"/XML",$item.XmlPath,"/F") -ExpectedExitCodes @(0) -Scope "Machine" -Silent
            if ($registration.Success -or $registration.Planned) { Write-Log "Re-imported missing scheduled task: $($item.TaskName)" -Level Success }
            else { Write-Log "Could not re-import scheduled task $($item.TaskName)" -Level Warning }
        } catch { Write-Log "Could not re-import scheduled task $($item.TaskName)" -Level Warning }
    }
    if ($plan.Count -eq 0) { Write-Log "No missing task registrations found in the golden task directory" -Level Info }
    return @($plan)
}

# ============================================================================
# CATEGORY 1: PRIVACY & TELEMETRY (COMPREHENSIVE)
# ============================================================================

# ============================================================================
# RESTORATION FUNCTIONS - COMPREHENSIVE v3.1
# Covers: privacy.sexy, debloat scripts, group policies, registry tweaks
# ============================================================================

function Restore-PrivacyTelemetry {
    Write-Log "=== PRIVACY & TELEMETRY (COMPREHENSIVE) ===" -Level Section

    # ---- CapabilityAccessManager ConsentStore (restore ALL to Allow) ----
    Write-Log "Restoring app capability access permissions..." -Level Info
    @(
        "documentsLibrary","picturesLibrary","videosLibrary","musicLibrary",
        "broadFileSystemAccess","phoneCallHistory","phoneCall","chat",
        "bluetooth","bluetoothSync","activity","appointments","contacts",
        "email","userDataTasks","userNotificationListener","radios",
        "userAccountInformation","webcam","microphone","location",
        "appDiagnostics","gazeInput","graphicsCaptureProgrammatic",
        "graphicsCaptureWithoutBorder","humanInterfaceDevice","humanPresence",
        "backgroundSpatialPerception","spatialPerception"
    ) | ForEach-Object {
        Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$_" -Name "Value" -Value "Allow" -Type "String" -Silent
    }

    # ---- AppPrivacy GPO (remove ALL forced deny/allow) ----
    Write-Log "Removing AppPrivacy group policies..." -Level Info
    @(
        "LetAppsAccessCallHistory","LetAppsAccessPhone","LetAppsAccessMessaging",
        "LetAppsSyncWithDevices","LetAppsAccessTrustedDevices","LetAppsAccessMotion",
        "LetAppsAccessCamera","LetAppsAccessMicrophone","LetAppsAccessLocation",
        "LetAppsAccessAccountInfo","LetAppsAccessContacts","LetAppsAccessCalendar",
        "LetAppsAccessEmail","LetAppsAccessTasks","LetAppsAccessRadios",
        "LetAppsAccessNotifications","LetAppsGetDiagnosticInfo","LetAppsAccessGazeInput",
        "LetAppsRunInBackground","LetAppsActivateWithVoice","LetAppsActivateWithVoiceAboveLock",
        "LetAppsAccessBackgroundSpatialPerception","LetAppsAccessGraphicsCaptureProgrammatic",
        "LetAppsAccessGraphicsCaptureWithoutBorder","LetAppsAccessHumanPresence"
    ) | ForEach-Object {
        $base = $_
        Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name $base -Silent
        Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "${base}_UserInControlOfTheseApps" -Silent
        Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "${base}_ForceAllowTheseApps" -Silent
        Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "${base}_ForceDenyTheseApps" -Silent
    }
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Silent

    # ---- Legacy DeviceAccess GUIDs (pre-1903) ----
    Write-Log "Restoring legacy device access settings..." -Level Info
    @(
        "LooselyCoupled",
        "{C1D23ACC-752B-43E5-8448-8D0E519CD6D6}",
        "{2EEF81BE-33FA-4800-9670-1CD474972C3F}",
        "{52079E78-A92B-413F-B213-E8FE35712E72}",
        "{7D7E8402-7C54-4821-A34E-AEEFD62DED93}",
        "{D89823BA-7180-4B81-B50C-7E471E6121A3}",
        "{8BC668CF-7728-45BD-93F8-CF2B3B41D7AB}",
        "{9231CB4C-BF57-4AF3-8C55-FDA7BFCC04C5}",
        "{E6AD100E-5F4E-44CD-BE0F-2265D88D14F5}",
        "{2297E4E2-5DBE-466D-A12B-0F8286F0D9CA}",
        "{E390DF20-07DF-446D-B962-F5C953062741}",
        "{992AFA70-6F47-4148-B3E9-3003349C1548}",
        "{21157C1F-2651-4CC1-90CA-1F28B02263F6}",
        "{BFA794E4-F964-4FDB-90F6-51056BFE4B44}",
        "{E5323777-F976-4f5b-9B55-B94699C46E44}",
        "{A8804298-2D5F-42E3-9531-9C8C39EB29CE}"
    ) | ForEach-Object {
        Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\$_" -Name "Value" -Silent
    }

    # ---- Telemetry & Diagnostics ----
    Write-Log "Restoring telemetry and diagnostics settings..." -Level Info
    # DataCollection policies
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowTelemetry" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "MaxTelemetryAllowed" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "DoNotShowFeedbackNotifications" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowDeviceNameInTelemetry" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowCommercialDataPipeline" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "MicrosoftEdgeDataOptIn" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowDesktopAnalyticsProcessing" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowUpdateComplianceProcessing" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowWUfBCloudProcessing" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "LimitEnhancedDiagnosticDataWindowsAnalytics" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "DisableOneSettingsDownloads" -Silent

    # SQM Client
    Remove-RegistryValue -Path "HKLM:\Software\Microsoft\SQMClient\Windows" -Name "CEIPEnable" -Silent
    Remove-RegistryValue -Path "HKLM:\Software\Policies\Microsoft\SQMClient\Windows" -Name "CEIPEnable" -Silent
    Remove-RegistryValue -Path "HKLM:\Software\Microsoft\SQMClient" -Name "MSFTInternal" -Silent

    # VS/CEIP SQM
    @("14.0","15.0","16.0","17.0") | ForEach-Object {
        Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\VSCommon\$_\SQM" -Name "OptIn" -Silent
        Remove-RegistryValue -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\VSCommon\$_\SQM" -Name "OptIn" -Silent
    }

    # License telemetry
    Remove-RegistryValue -Path "HKLM:\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform" -Name "NoGenTicket" -Silent

    # Customer Experience
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -Silent

    # TIPC (text input telemetry)
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Input\TIPC" -Name "Enabled" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Input\TIPC" -Name "Enabled" -Silent

    # Input personalization
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore" -Name "HarvestContacts" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Personalization\Settings" -Name "AcceptedPrivacyPolicy" -Silent
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization" -Silent

    # Handwriting error reports
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HandwritingErrorReports" -Silent
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC" -Silent

    # Advertising ID
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Silent
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" -Silent

    # Feedback
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Siuf\Rules" -Name "NumberOfSIUFInPeriod" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Siuf\Rules" -Name "PeriodInNanoSeconds" -Silent

    # Privacy consent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" -Name "DisablePrivacyExperience" -Silent

    # App Compatibility / Telemetry collector
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" -Silent
    Remove-RegistryKey -Path "HKLM:\Software\Policies\Microsoft\Windows\AppCompat" -Silent

    # IFEO blocks on telemetry executables (remove debugger redirects)
    @("CompatTelRunner.exe","DeviceCensus.exe","upfc.exe") | ForEach-Object {
        Remove-RegistryKey -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$_" -Silent
    }

    # Restore CompatTelRunner.exe and DeviceCensus.exe if renamed to .OLD
    @("$env:SystemRoot\System32\CompatTelRunner.exe","$env:SystemRoot\System32\DeviceCensus.exe") | ForEach-Object {
        $oldPath = "$_.OLD"
        if ((Test-Path $oldPath) -and !(Test-Path $_)) {
            try { Invoke-RestoreFileMutation -Action Rename -Path $oldPath -Destination (Split-Path $_ -Leaf) -Silent } catch { Write-Verbose "Could not restore renamed compatibility executable $oldPath" }
        }
    }

    # Bluetooth telemetry
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowBuildPreview" -Silent

    # Disk diagnostics
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WDI\{9c5a40da-b965-4fc3-8781-88dd50a6299d}" -Name "ScenarioExecutionEnabled" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WDI\{29689E29-2CE9-4751-B4FC-8EFF5066E3FD}" -Name "ScenarioExecutionEnabled" -Silent

    # Experimentation
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\System\AllowExperimentation" -Name "value" -Silent

    # Location sensor overrides
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}" -Name "SensorPermissionState" -Silent

    # Location/sensors policy
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" -Silent

    # Location service configuration
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration" -Name "Status" -Silent

    # Wi-Fi Sense
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots" -Name "value" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting" -Name "value" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config" -Name "AutoConnectAllowedOEM" -Silent

    # Website Language List access
    Remove-RegistryValue -Path "HKCU:\Control Panel\International\User Profile" -Name "HttpAcceptLanguageOptOut" -Silent

    # Activity Feed / Timeline
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Silent

    # App launch tracking
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Start_TrackProgs" -Silent

    # Maps auto-download
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps" -Silent

    # Game DVR/screen recording
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Silent
    Remove-RegistryValue -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Silent

    # DRM internet access
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\WMDRM" -Silent

    # Cloud speech recognition
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" -Name "HasAccepted" -Silent
    Remove-RegistryValue -Path "HKLM:\Software\Microsoft\Speech_OneCore\Preferences" -Name "ModelDownloadAllowed" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Speech_OneCore\Preferences" -Name "VoiceActivationOn" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps" -Name "AgentActivationEnabled" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps" -Name "AgentActivationOnLockScreenEnabled" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps" -Name "AgentActivationLastUsed" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps" -Name "ActiveAboveLockLastUsed" -Silent

    # Recall
    Remove-RegistryValue -Path "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI" -Name "DisableAIDataAnalysis" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name "DisableAIDataAnalysis" -Silent

    # Restore DiagTrack / diagnostics services
    @(
        @{N="DiagTrack"; T="Automatic"},
        @{N="dmwappushservice"; T="Manual"},
        @{N="diagnosticshub.standardcollector.service"; T="Manual"},
        @{N="diagsvc"; T="Manual"},
        @{N="PcaSvc"; T="Manual"},
        @{N="wercplsupport"; T="Manual"},
        @{N="wersvc"; T="Manual"}
    ) | ForEach-Object { Restore-ServiceStartup -ServiceName $_.N -StartupType $_.T -Silent }

    # Restore telemetry scheduled tasks
    @(
        @{P="\Microsoft\Windows\Application Experience\"; N="Microsoft Compatibility Appraiser"},
        @{P="\Microsoft\Windows\Application Experience\"; N="ProgramDataUpdater"},
        @{P="\Microsoft\Windows\Application Experience\"; N="AitAgent"},
        @{P="\Microsoft\Windows\Application Experience\"; N="StartupAppTask"},
        @{P="\Microsoft\Windows\Application Experience\"; N="PcaPatchDbTask"},
        @{P="\Microsoft\Windows\Application Experience\"; N="SdbinstMergeDbTask"},
        @{P="\Microsoft\Windows\Application Experience\"; N="MareBackup"},
        @{P="\Microsoft\Windows\Autochk\"; N="Proxy"},
        @{P="\Microsoft\Windows\Customer Experience Improvement Program\"; N="Consolidator"},
        @{P="\Microsoft\Windows\Customer Experience Improvement Program\"; N="UsbCeip"},
        @{P="\Microsoft\Windows\Customer Experience Improvement Program\"; N="KernelCeipTask"},
        @{P="\Microsoft\Windows\Device Information\"; N="Device"},
        @{P="\Microsoft\Windows\Device Information\"; N="Device User"},
        @{P="\Microsoft\Windows\DiskDiagnostic\"; N="Microsoft-Windows-DiskDiagnosticDataCollector"},
        @{P="\Microsoft\Windows\DiskDiagnostic\"; N="Microsoft-Windows-DiskDiagnosticResolver"},
        @{P="\Microsoft\Windows\Feedback\Siuf\"; N="DmClient"},
        @{P="\Microsoft\Windows\Feedback\Siuf\"; N="DmClientOnScenarioDownload"},
        @{P="\Microsoft\Windows\PI\"; N="Sqm-Tasks"},
        @{P="\Microsoft\Windows\NetTrace\"; N="GatherNetworkInfo"}
    ) | ForEach-Object { Enable-ScheduledTaskSafe -TaskPath $_.P -TaskName $_.N -Silent }

    Write-Log "Privacy & Telemetry: Complete" -Level Success
}

function Restore-CopilotCortanaAI {
    Write-Log "=== COPILOT, CORTANA & AI ===" -Level Section

    # ---- Copilot ----
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowCopilotButton" -Silent

    # ---- Cortana (comprehensive) ----
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Experience\AllowCortana" -Name "value" -Silent
    # Cortana policies
    @(
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search",
        "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
    ) | ForEach-Object {
        Remove-RegistryValue -Path $_ -Name "AllowCortana" -Silent
        Remove-RegistryValue -Path $_ -Name "AllowCortanaAboveLock" -Silent
        Remove-RegistryValue -Path $_ -Name "AllowSearchToUseLocation" -Silent
        Remove-RegistryValue -Path $_ -Name "ConnectedSearchUseWeb" -Silent
        Remove-RegistryValue -Path $_ -Name "ConnectedSearchUseWebOverMeteredConnections" -Silent
        Remove-RegistryValue -Path $_ -Name "DisableWebSearch" -Silent
        Remove-RegistryValue -Path $_ -Name "AllowCloudSearch" -Silent
        Remove-RegistryValue -Path $_ -Name "EnableDynamicContentInWSB" -Silent
    }
    # Cortana user settings
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "VoiceShortcut" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "CanCortanaBeEnabled" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "DeviceHistoryEnabled" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "CortanaEnabled" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "CortanaConsent" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "HasAboveLockTips" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "HistoryViewEnabled" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "IsAssignedAccess" -Silent

    # Cortana indexing settings
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowIndexingEncryptedStoresOrItems" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AlwaysUseAutoLangDetection" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "PreventRemoteQueries" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "PreventUnindexedItemsInSearchResults" -Silent

    Write-Log "Copilot, Cortana & AI: Complete" -Level Success
}

function Restore-BingSearchWidgets {
    Write-Log "=== BING SEARCH & WIDGETS ===" -Level Section

    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchSpokenEnabled" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "CortanaConsent" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" -Name "IsAADCloudSearchEnabled" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" -Name "IsMSACloudSearchEnabled" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" -Name "IsDeviceSearchHistoryEnabled" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" -Name "IsDynamicSearchBoxEnabled" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Silent

    # Widgets / Web Experience Pack
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarDa" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Silent

    # Windows search highlights
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "EnableDynamicContentInWSB" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings" -Name "IsDynamicSearchBoxEnabled" -Silent

    Write-Log "Bing Search & Widgets: Complete" -Level Success
}

function Restore-TaskbarUI {
    Write-Log "=== TASKBAR & UI ===" -Level Section

    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowTaskViewButton" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarDa" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarMn" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarAl" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowCopilotButton" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People" -Name "PeopleBand" -Silent
    # Meet Now
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "HideSCAMeetNow" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "HideSCAMeetNow" -Silent

    Write-Log "Taskbar & UI: Complete" -Level Success
}

function Restore-ExplorerSettings {
    Write-Log "=== EXPLORER SETTINGS ===" -Level Section

    # This PC folder restores (remove registry deletions that hid folders)
    @(
        "{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}",  # Desktop
        "{d3162b92-9365-467a-956b-92703aca08af}",    # Documents
        "{088e3905-0323-4b02-9826-5d99428e115f}",    # Downloads
        "{3dfdf296-dbec-4fb4-81d1-6a3438bcf4de}",    # Music
        "{24ad3ad4-a569-4530-98e1-ab02f9417aa8}",    # Pictures
        "{f86fa3ab-70d2-4fc7-9c99-fcbf05467f3a}",    # Videos
        "{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}"     # 3D Objects
    ) | ForEach-Object {
        $keyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\$_"
        New-RestoreRegistryKey -Path $keyPath -Silent
    }
    # FolderDescriptions PropertyBag (restore ThisPCPolicy to Show)
    @(
        "0ddd015d-b06c-45d5-8c4c-f59713854639",  # Documents
        "35286a68-3c57-41a1-bbb1-0eae73d76c95",   # Videos
        "7d83ee9b-2244-4e70-b1f5-5393042af1e4",   # Downloads
        "a0c69a99-21c8-4671-8703-7934162fcf1d",    # Music
        "f42ee2d3-909f-4907-8871-4c22fc0bf756"     # Pictures
    ) | ForEach-Object {
        Set-RegistryValue -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions\{$_}\PropertyBag" -Name "ThisPCPolicy" -Value "Show" -Type "String" -Silent
        Set-RegistryValue -Path "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions\{$_}\PropertyBag" -Name "ThisPCPolicy" -Value "Show" -Type "String" -Silent
    }

    # Explorer policies
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name "NoNewAppAlert" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "NoNewAppAlert" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowSyncProviderNotifications" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Start_TrackDocs" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "LaunchTo" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Hidden" -Silent

    # Recent documents
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoRecentDocsHistory" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "ClearRecentDocsOnExit" -Silent

    # Sync provider notifications
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowSyncProviderNotifications" -Silent

    # Internet file association / web publishing
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoInternetOpenWith" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoOnlinePrintsWizard" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoPublishingWizard" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoWebServices" -Silent

    Write-Log "Explorer Settings: Complete" -Level Success
}

function Restore-StartMenuSettings {
    Write-Log "=== START MENU ===" -Level Section
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Start_TrackProgs" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Start_IrisRecommendations" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Start_AccountNotifications" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Start_Layout" -Silent
    Write-Log "Start Menu: Complete" -Level Success
}

function Restore-ThemeSettings {
    Write-Log "=== THEME & PERSONALIZATION ===" -Level Section
    # Windows Tips
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Silent
    Remove-RegistryKey -Path "HKLM:\Software\Policies\Microsoft\Windows\CloudContent" -Silent
    # Content Delivery Manager
    @(
        "SubscribedContent-338387Enabled","SubscribedContent-338389Enabled",
        "SubscribedContent-338393Enabled","SubscribedContent-353694Enabled",
        "SubscribedContent-353696Enabled","SubscribedContent-310093Enabled",
        "SubscribedContent-338388Enabled","SubscribedContent-314563Enabled",
        "SubscribedContent-353698Enabled","RotatingLockScreenEnabled",
        "RotatingLockScreenOverlayEnabled","SilentInstalledAppsEnabled",
        "SoftLandingEnabled","SystemPaneSuggestionsEnabled",
        "ContentDeliveryAllowed","OemPreInstalledAppsEnabled",
        "PreInstalledAppsEnabled","PreInstalledAppsEverEnabled",
        "FeatureManagementEnabled","RemediationRequired"
    ) | ForEach-Object {
        Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name $_ -Silent
    }
    # Suggested content in Settings
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-338393Enabled" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-353694Enabled" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-353696Enabled" -Silent
    # Spotlight / lock screen
    Remove-RegistryValue -Path "HKCU:\Software\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsSpotlightFeatures" -Silent
    # Camera on/off OSD
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\OEM\Device\Capture" -Name "NoPhysicalCameraLED" -Silent

    Write-Log "Theme & Personalization: Complete" -Level Success
}

function Restore-ContentDeliveryManager {
    Write-Log "=== CONTENT DELIVERY / ADS ===" -Level Section
    @(
        "SubscribedContent-338387Enabled","SubscribedContent-338389Enabled",
        "SubscribedContent-338393Enabled","SubscribedContent-353694Enabled",
        "SubscribedContent-353696Enabled","SubscribedContent-310093Enabled",
        "SubscribedContent-338388Enabled","SubscribedContent-314563Enabled",
        "SubscribedContent-353698Enabled","RotatingLockScreenEnabled",
        "RotatingLockScreenOverlayEnabled","SilentInstalledAppsEnabled",
        "SoftLandingEnabled","SystemPaneSuggestionsEnabled",
        "ContentDeliveryAllowed","OemPreInstalledAppsEnabled",
        "PreInstalledAppsEnabled","PreInstalledAppsEverEnabled",
        "FeatureManagementEnabled","RemediationRequired"
    ) | ForEach-Object {
        Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name $_ -Silent
    }
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Silent
    Remove-RegistryKey -Path "HKLM:\Software\Policies\Microsoft\Windows\CloudContent" -Silent
    Write-Log "Content Delivery: Complete" -Level Success
}

function Restore-BluetoothSettings {
    Write-Log "=== BLUETOOTH ===" -Level Section
    @(
        @{N="bthserv"; T="Manual"},
        @{N="BTAGService"; T="Manual"},
        @{N="BthAvctpSvc"; T="Manual"}
    ) | ForEach-Object { Restore-ServiceStartup -ServiceName $_.N -StartupType $_.T -Silent }
    Write-Log "Bluetooth: Complete" -Level Success
}

function Restore-NotificationSettings {
    Write-Log "=== NOTIFICATIONS ===" -Level Section
    Remove-RegistryValue -Path "HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications" -Name "NoToastApplicationNotification" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings" -Name "NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" -Name "LockScreenToastEnabled" -Silent
    # Live tiles
    Remove-RegistryValue -Path "HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications" -Name "NoCloudApplicationNotification" -Silent
    # App suggestions (Look for app in Store)
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost" -Name "EnableWebContentEvaluation" -Silent

    Write-Log "Notifications: Complete" -Level Success
}

function Restore-OOBESettings {
    Write-Log "=== OOBE & SETUP ===" -Level Section
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" -Name "DisablePrivacyExperience" -Silent
    # Reserved storage
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" -Name "ShippedWithReserves" -Silent
    # NTP server restore
    Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters" -Name "NtpServer" -Value "time.windows.com,0x9" -Type "String" -Silent
    Write-Log "OOBE & Setup: Complete" -Level Success
}

function Restore-DefenderSettings {
    Write-Log "=== WINDOWS DEFENDER (EXHAUSTIVE) ===" -Level Section

    # ---- Remove ALL Defender group policies ----
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Silent
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Microsoft Antimalware" -Silent

    # ---- Individual policy reversals (extensive - every known GPO value) ----
    $defBase = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
    @(
        @{P=$defBase; N="DisableAntiSpyware"},
        @{P=$defBase; N="DisableAntiVirus"},
        @{P=$defBase; N="DisableRoutinelyTakingAction"},
        @{P=$defBase; N="ServiceKeepAlive"},
        @{P=$defBase; N="AllowFastServiceStartup"},
        @{P=$defBase; N="PUAProtection"},
        @{P=$defBase; N="RandomizeScheduleTaskTimes"},
        @{P="$defBase\Real-Time Protection"; N="DisableRealtimeMonitoring"},
        @{P="$defBase\Real-Time Protection"; N="DisableBehaviorMonitoring"},
        @{P="$defBase\Real-Time Protection"; N="DisableOnAccessProtection"},
        @{P="$defBase\Real-Time Protection"; N="DisableScanOnRealtimeEnable"},
        @{P="$defBase\Real-Time Protection"; N="DisableIOAVProtection"},
        @{P="$defBase\Real-Time Protection"; N="DisableIntrusionPreventionSystem"},
        @{P="$defBase\Real-Time Protection"; N="DisableRawWriteNotification"},
        @{P="$defBase\Real-Time Protection"; N="DisableInformationProtectionControl"},
        @{P="$defBase\Real-Time Protection"; N="RealtimeScanDirection"},
        @{P="$defBase\Real-Time Protection"; N="LocalSettingOverrideDisableRealtimeMonitoring"},
        @{P="$defBase\Real-Time Protection"; N="IOAVMaxSize"},
        @{P="$defBase\Spynet"; N="SpyNetReporting"},
        @{P="$defBase\Spynet"; N="SubmitSamplesConsent"},
        @{P="$defBase\Spynet"; N="DisableBlockAtFirstSeen"},
        @{P="$defBase\Spynet"; N="LocalSettingOverrideSpynetReporting"},
        @{P="$defBase\MpEngine"; N="MpEnablePus"},
        @{P="$defBase\MpEngine"; N="MpCloudBlockLevel"},
        @{P="$defBase\MpEngine"; N="MpBafsExtendedTimeout"},
        @{P="$defBase\MpEngine"; N="EnableFileHashComputation"},
        @{P="$defBase\Reporting"; N="DisableEnhancedNotifications"},
        @{P="$defBase\Reporting"; N="DisableGenericRePorts"},
        @{P="$defBase\Scan"; N="DisableArchiveScanning"},
        @{P="$defBase\Scan"; N="DisableRemovableDriveScanning"},
        @{P="$defBase\Scan"; N="DisableEmailScanning"},
        @{P="$defBase\Scan"; N="DisableScanningMappedNetworkDrivesForFullScan"},
        @{P="$defBase\Scan"; N="DisableScanningNetworkFiles"},
        @{P="$defBase\Scan"; N="DisablePackedExeScanning"},
        @{P="$defBase\Scan"; N="DisableReparsePointScanning"},
        @{P="$defBase\Scan"; N="DisableHeuristics"},
        @{P="$defBase\Scan"; N="DisableScanOnUpdate"},
        @{P="$defBase\Scan"; N="DisableCatchupFullScan"},
        @{P="$defBase\Scan"; N="DisableCatchupQuickScan"},
        @{P="$defBase\Scan"; N="DisableRestorePoint"},
        @{P="$defBase\Scan"; N="CheckForSignaturesBeforeRunningScan"},
        @{P="$defBase\Scan"; N="ScanParameters"},
        @{P="$defBase\Scan"; N="ScheduleDay"},
        @{P="$defBase\Scan"; N="ScheduleTime"},
        @{P="$defBase\Scan"; N="ScheduleQuickScanTime"},
        @{P="$defBase\Scan"; N="AvgCPULoadFactor"},
        @{P="$defBase\Scan"; N="LowCpuPriority"},
        @{P="$defBase\Scan"; N="ScanOnlyIfIdle"},
        @{P="$defBase\Scan"; N="PurgeItemsAfterDelay"},
        @{P="$defBase\Scan"; N="MissedScheduledScanCountBeforeCatchup"},
        @{P="$defBase\Scan"; N="ArchiveMaxDepth"},
        @{P="$defBase\Scan"; N="ArchiveMaxSize"},
        @{P="$defBase\Signature Updates"; N="ForceUpdateFromMU"},
        @{P="$defBase\Signature Updates"; N="UpdateOnStartUp"},
        @{P="$defBase\Signature Updates"; N="SignatureUpdateInterval"},
        @{P="$defBase\Signature Updates"; N="ScheduleDay"},
        @{P="$defBase\Signature Updates"; N="ScheduleTime"},
        @{P="$defBase\Signature Updates"; N="ASSignatureDue"},
        @{P="$defBase\Signature Updates"; N="AVSignatureDue"},
        @{P="$defBase\Signature Updates"; N="SignatureUpdateCatchupInterval"},
        @{P="$defBase\Signature Updates"; N="DisableUpdateOnStartupWithoutEngine"},
        @{P="$defBase\Signature Updates"; N="SignatureDisableNotification"},
        @{P="$defBase\Signature Updates"; N="FallbackOrder"},
        @{P="$defBase\Signature Updates"; N="DefinitionUpdateFileSharesSources"},
        @{P="$defBase\Signature Updates"; N="SignatureFirstAuGracePeriod"},
        @{P="$defBase\Windows Defender Exploit Guard\ASR"; N="ExploitGuard_ASR_Rules"},
        @{P="$defBase\Windows Defender Exploit Guard\Network Protection"; N="EnableNetworkProtection"},
        @{P="$defBase\Windows Defender Exploit Guard\Controlled Folder Access"; N="EnableControlledFolderAccess"},
        @{P="$defBase\Features"; N="TamperProtection"},
        @{P="$defBase\UX Configuration"; N="Notification_Suppress"},
        @{P="$defBase\UX Configuration"; N="UILockdown"},
        @{P="$defBase\Remediation"; N="Scan_ScheduleDay"},
        @{P="$defBase\Remediation"; N="LocalSettingOverrideScan_ScheduleDay"},
        @{P="$defBase\Quarantine"; N="PurgeItemsAfterDelay"},
        @{P="$defBase\Quarantine"; N="LocalPurgeItemsAfterDelay"}
    ) | ForEach-Object { Remove-RegistryValue -Path $_.P -Name $_.N -Silent }

    # ---- User-level Defender overrides ----
    @("DisableAntiSpyware","DisableAntiVirus","PassiveMode") | ForEach-Object {
        Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows Defender" -Name $_ -Silent
    }
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableRealtimeMonitoring" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows Defender\Features" -Name "TamperProtection" -Silent

    # ---- Remove exclusions added by debloat scripts ----
    @("Paths","Extensions","Processes","TemporaryPaths","IpAddresses") | ForEach-Object {
        Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions\$_" -Silent
    }
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions" -Silent

    # ---- IFEO blocks (remove debugger redirects that block Defender EXEs) ----
    Write-Log "Removing Image File Execution Options blocks on Defender..." -Level Info
    @(
        "MsMpEng.exe","NisSrv.exe","MpCmdRun.exe","MpCopyAccelerator.exe",
        "MpDefenderCoreService.exe","MpDlpCmd.exe","MpDlpService.exe",
        "ConfigSecurityPolicy.exe","SecurityHealthHost.exe","SecurityHealthService.exe",
        "SgrmBroker.exe","SgrmLpac.exe","smartscreen.exe"
    ) | ForEach-Object {
        Remove-RegistryKey -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$_" -Silent
    }

    # ---- Restore renamed Defender EXEs (.OLD files) ----
    Write-Log "Checking for renamed Defender executables..." -Level Info
    $defenderPaths = @(
        "$env:ProgramFiles\Windows Defender",
        "$env:ProgramFiles\Windows Defender Advanced Threat Protection",
        "$env:ProgramData\Microsoft\Windows Defender\Platform"
    )
    foreach ($dp in $defenderPaths) {
        if (Test-Path $dp) {
            Get-ChildItem -Path $dp -Filter "*.OLD" -Recurse -EA 0 | ForEach-Object {
                $newName = $_.FullName -replace '\.OLD$',''
                if (!(Test-Path $newName)) {
                    try {
                        $restoreResult = Invoke-RestoreFileMutation -Action Rename -Path $_.FullName -Destination (Split-Path $newName -Leaf) -Silent
                        if ($restoreResult) { Write-Log "Restored: $($_.Name)" -Level Success }
                    } catch { Write-Log "Could not restore $($_.Name): $($_.Exception.Message)" -Level Warning }
                }
            }
        }
    }

    # ---- Restore Defender services (comprehensive) ----
    Write-Log "Restoring Defender services..." -Level Info
    @(
        @{N="WinDefend"; T="Automatic"},
        @{N="WdNisSvc"; T="Manual"},
        @{N="WdFilter"; T="Boot"},
        @{N="WdBoot"; T="Boot"},
        @{N="WdNisDrv"; T="Manual"},
        @{N="SecurityHealthService"; T="Manual"},
        @{N="wscsvc"; T="Automatic"},
        @{N="Sense"; T="Manual"},
        @{N="SgrmAgent"; T="Manual"},
        @{N="SgrmBroker"; T="Automatic"},
        @{N="MsSecCore"; T="Manual"},
        @{N="MsSecFlt"; T="Boot"},
        @{N="MsSecWfp"; T="Boot"},
        @{N="MDDlpSvc"; T="Manual"},
        @{N="webthreatdefsvc"; T="Manual"},
        @{N="webthreatdefusersvc"; T="Manual"}
    ) | ForEach-Object {
        Restore-ServiceStartup -ServiceName $_.N -StartupType $_.T -Silent
        # Boot/System drivers: also fix via registry Start value
        if ($_.T -eq "Boot") {
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.N)"
            if (Test-Path $regPath) { Set-RegistryValue -Path $regPath -Name "Start" -Value 0 -Type "DWord" -Silent }
        }
    }

    # ---- ETW / Event Log providers ----
    Set-RegistryValue -Path "HKLM:\System\CurrentControlSet\Control\WMI\Autologger\DefenderApiLogger" -Name "Start" -Value 1 -Silent
    Set-RegistryValue -Path "HKLM:\System\CurrentControlSet\Control\WMI\Autologger\DefenderAuditLogger" -Name "Start" -Value 1 -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels\Microsoft-Windows-Windows Defender/Operational" -Name "Enabled" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels\Microsoft-Windows-Windows Defender/WHC" -Name "Enabled" -Silent

    # ---- AMSI (re-enable) ----
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows Script Host\Settings" -Name "Enabled" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\AMSI\Providers" -Name "ForceDisable" -Silent

    # ---- Scheduled Tasks ----
    @(
        "Windows Defender Cache Maintenance","Windows Defender Cleanup",
        "Windows Defender Scheduled Scan","Windows Defender Verification",
        "Windows Defender ExploitGuard MDM Refresh"
    ) | ForEach-Object { Enable-ScheduledTaskSafe -TaskPath "\Microsoft\Windows\Windows Defender\" -TaskName $_ -Silent }

    # ---- Security Center notifications ----
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center" -Silent

    # ---- Restore Security Health tray ----
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "SecurityHealth" -Value "%ProgramFiles%\Windows Defender\MSASCuiL.exe" -Type "ExpandString" -Silent

    # ---- Malicious Software Removal Tool ----
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\MRT" -Name "DontReportInfectionInformation" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\MRT" -Name "DontOfferThroughWUAU" -Silent

    # ---- Start WinDefend if stopped ----
    try {
        $def = Get-Service -Name "WinDefend" -EA 0
        if ($def -and $def.Status -eq 'Stopped') {
            if (Invoke-RestoreServiceControl -Action Start -ServiceName "WinDefend" -Silent) { Write-Log "Started WinDefend service" -Level Success }
        }
    } catch { Write-Log "Could not start WinDefend - reboot required" -Level Warning }

    # ---- Force signature update ----
    try {
        $mpCmd = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
        if (Test-Path $mpCmd) {
            $signatureUpdate = Invoke-RestoreNativeCommand -FilePath $mpCmd -ArgumentList @("-SignatureUpdate") -ExpectedExitCodes @(0) -Scope "Machine" -Silent
            if ($signatureUpdate.Success -or $signatureUpdate.Planned) { Write-Log "Defender signature update triggered" -Level Success }
        }
    } catch { Write-Log "Could not trigger signature update" -Level Warning }

    Write-Log "Windows Defender: Complete" -Level Success
}

function Restore-SmartScreenSettings {
    Write-Log "=== SMARTSCREEN (COMPREHENSIVE) ===" -Level Section

    # IFEO block on smartscreen.exe
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\smartscreen.exe" -Silent

    # SmartScreen policies
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" -Name "SmartScreenEnabled" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableSmartScreen" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "ShellSmartScreenLevel" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "ConfigureAppInstallControl" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "ConfigureAppInstallControlEnabled" -Silent

    # SmartScreen for Store apps
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\AppHost" -Name "EnableWebContentEvaluation" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\AppHost" -Name "PreventOverride" -Silent

    # Edge SmartScreen
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "SmartScreenEnabled" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "SmartScreenPuaEnabled" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "PreventSmartScreenPromptOverride" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "PreventSmartScreenPromptOverrideForFiles" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "SmartScreenDnsRequestsEnabled" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "SmartScreenForTrustedDownloadsEnabled" -Silent

    # Edge Legacy SmartScreen
    Remove-RegistryValue -Path "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppContainer\Storage\microsoft.microsoftedge_8wekyb3d8bbwe\MicrosoftEdge\PhishingFilter" -Name "EnabledV9" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppContainer\Storage\microsoft.microsoftedge_8wekyb3d8bbwe\MicrosoftEdge\PhishingFilter" -Name "PreventOverride" -Silent

    # IE SmartScreen
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Internet Explorer\PhishingFilter" -Name "EnabledV9" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Internet Explorer\PhishingFilter" -Name "PreventOverride" -Silent

    # Enhanced Phishing Protection
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WTDS\Components" -Silent

    # Restore SmartScreen EXE if renamed
    $ssPath = "$env:SystemRoot\System32\smartscreen.exe"
    if ((Test-Path "$ssPath.OLD") -and !(Test-Path $ssPath)) {
        try { Invoke-RestoreFileMutation -Action Rename -Path "$ssPath.OLD" -Destination "smartscreen.exe" -Silent } catch { }
    }

    Write-Log "SmartScreen: Complete" -Level Success
}

function Restore-FirewallSettings {
    Write-Log "=== WINDOWS FIREWALL (COMPREHENSIVE) ===" -Level Section

    # ---- Firewall registry (all profiles) ----
    @("DomainProfile","PublicProfile","StandardProfile") | ForEach-Object {
        Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\$_" -Name "EnableFirewall" -Value 1 -Silent
        Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\$_" -Name "DoNotAllowExceptions" -Silent
    }

    # ---- Firewall policies ----
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall" -Silent

    # ---- Firewall services ----
    @(
        @{N="MpsSvc"; T="Automatic"},
        @{N="mpsdrv"; T="Manual"},
        @{N="BFE"; T="Automatic"},
        @{N="SharedAccess"; T="Manual"}
    ) | ForEach-Object { Restore-ServiceStartup -ServiceName $_.N -StartupType $_.T -Silent }

    # ---- WFP callout driver ----
    Restore-ServiceStartup -ServiceName "MsSecWfp" -StartupType "Boot" -Silent

    # ---- Enable firewall via netsh ----
    try {
        $firewallResult = Invoke-RestoreNativeCommand -FilePath "netsh" -ArgumentList @("advfirewall","set","allprofiles","state","on") -ExpectedExitCodes @(0) -Scope "Machine" -Silent
        if ($firewallResult.Success -or $firewallResult.Planned) { Write-Log "Firewall enabled via netsh" -Level Success }
    } catch { Write-Log "Could not enable firewall via netsh" -Level Warning }

    # ---- Windows Security Firewall section ----
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Firewall and network protection" -Name "UILockdown" -Silent

    Write-Log "Windows Firewall: Complete" -Level Success
}

function Restore-WindowsSecurityUI {
    Write-Log "=== WINDOWS SECURITY UI ===" -Level Section

    # ---- Security Center sections (re-enable all hidden sections) ----
    @(
        "Virus and threat protection",
        "Firewall and network protection",
        "App and browser control",
        "Device security",
        "Device performance and health",
        "Family options",
        "Account protection"
    ) | ForEach-Object {
        Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\$_" -Name "UILockdown" -Silent
    }
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Device security" -Name "DisableClearTpmButton" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Device security" -Name "HideSecureBoot" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Device security" -Name "HideTPMTroubleshooting" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Device security" -Name "DisableTpmFirmwareUpdateWarning" -Silent
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center" -Silent

    # ---- Security and Maintenance notifications ----
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance" -Name "Enabled" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance" -Name "Enabled" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name "DisableNotificationCenter" -Silent

    # ---- Defender notification settings ----
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\UX Configuration" -Name "Notification_Suppress" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Reporting" -Name "DisableEnhancedNotifications" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "UILockdown" -Silent

    # ---- Restore "Scan with Defender" context menu ----
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked" -Name "{09A47860-11B0-4DA5-AFA5-26D86198A780}" -Silent

    # ---- Security Health Agent ----
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SecurityHealthService" -Name "Start" -Silent

    # ---- VBS / Device Guard (restore defaults, don't force enable) ----
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name "EnableVirtualizationBasedSecurity" -Silent
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name "RequirePlatformSecurityFeatures" -Silent
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name "Enabled" -Silent

    Write-Log "Windows Security UI: Complete" -Level Success
}

function Restore-WindowsUpdateSettings {
    param([switch]$ForceManaged)
    Write-Log "=== WINDOWS UPDATE (FULL REPAIR) ===" -Level Section

    # ---- Reset update channel, release targeting, and deferral policies ----
    $management = Get-PolicyManagementState
    Reset-WindowsUpdateChannelAndDeferral -ForceManaged:$ForceManaged
    if ($ForceManaged -or -not $management.IsManaged) {
        Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Silent
        Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Silent
        Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Silent
    }

    # ---- AU policy reversals ----
    @("NoAutoUpdate","AUOptions","AutoInstallMinorUpdates","NoAutoRebootWithLoggedOnUsers",
      "RebootRelaunchTimeout","RebootRelaunchTimeoutEnabled","RebootWarningTimeout",
      "RebootWarningTimeoutEnabled","ScheduledInstallDay","ScheduledInstallTime","UseWUServer",
      "AlwaysAutoRebootAtScheduledTime","AlwaysAutoRebootAtScheduledTimeMinutes",
      "IncludeRecommendedUpdates","AutomaticMaintenanceEnabled","DetectionFrequency",
      "DetectionFrequencyEnabled","RescheduleWaitTime","RescheduleWaitTimeEnabled"
    ) | ForEach-Object { Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name $_ -Silent }

    # ---- WU base policies ----
    @("WUServer","WUStatusServer","UpdateServiceUrlAlternate","DisableWindowsUpdateAccess",
      "SetDisableUXWUAccess","ExcludeWUDriversInQualityUpdate","ManagePreviewBuilds",
      "ManagePreviewBuildsPolicyValue","DeferFeatureUpdates","DeferFeatureUpdatesPeriodInDays",
      "BranchReadinessLevel","DeferQualityUpdates","DeferQualityUpdatesPeriodInDays",
      "TargetReleaseVersion","TargetReleaseVersionInfo","ProductVersion",
      "SetPolicyDrivenUpdateSourceForFeatureUpdates","SetPolicyDrivenUpdateSourceForQualityUpdates",
      "SetPolicyDrivenUpdateSourceForDriverUpdates","SetPolicyDrivenUpdateSourceForOtherUpdates",
      "DisableDualScan","DoNotEnforceEnterpriseTLSCertPinningForUpdateDetection",
      "SetProxyBehaviorForUpdateDetection","AllowAutoWindowsUpdateDownloadOverMeteredNetwork",
      "SetAutoRestartNotificationDisable","SetEDURestart","SetRestartWarningSchd",
      "SetUpdateNotificationLevel","ConfigureDeadlineForFeatureUpdates",
      "ConfigureDeadlineForQualityUpdates","ConfigureDeadlineGracePeriod",
      "ConfigureDeadlineNoAutoReboot","DoNotConnectToWindowsUpdateInternetLocations",
      "SetPolicyDrivenUpdateSourceForFeatureUpdates","SetPolicyDrivenUpdateSourceForQualityUpdates",
      "SetPolicyDrivenUpdateSourceForDriverUpdates","SetPolicyDrivenUpdateSourceForOtherUpdates"
    ) | ForEach-Object { Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name $_ -Silent }

    # ---- UX Settings ----
    @("ActiveHoursStart","ActiveHoursEnd","PauseFeatureUpdatesStartTime","PauseFeatureUpdatesEndTime",
      "PauseQualityUpdatesStartTime","PauseQualityUpdatesEndTime","PauseUpdatesStartTime",
      "PauseUpdatesExpiryTime","FlightSettingsMaxPauseDays","IsExpedited","LastActiveHoursState"
    ) | ForEach-Object { Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name $_ -Silent }

    # ---- PolicyManager update policies ----
    @("Pause","PauseFeatureUpdates","PauseQualityUpdates","RequireDeferUpgrade",
      "DeferFeatureUpdatesPeriodInDays","DeferQualityUpdatesPeriodInDays",
      "ExcludeWUDriversInQualityUpdate","ConfigureDeadlineForFeatureUpdates",
      "ConfigureDeadlineForQualityUpdates"
    ) | ForEach-Object {
        Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Update\$_" -Name "value" -Silent
    }

    # ---- WU driver search ----
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching" -Name "SearchOrderConfig" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching" -Name "DontSearchWindowsUpdate" -Silent
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Silent

    # ---- Delivery Optimization ----
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization" -Name "SystemSettingsDownloadMode" -Silent
    Remove-RegistryValue -Path "HKU:\S-1-5-20\Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings" -Name "DownloadMode" -Silent

    # ---- WSUS/SCCM cleanup ----
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" -Name "AUOptions" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" -Name "EnableFeaturedSoftware" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" -Name "IncludeRecommendedUpdates" -Silent

    # ---- IFEO blocks on WU executables ----
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\WaaSMedicAgent.exe" -Silent
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\upfc.exe" -Silent

    # ---- UpdatePolicy ----
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\Settings" -Name "PausedQualityDate" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\Settings" -Name "PausedFeatureDate" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\PolicyState" -Name "PausedQualityDate" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\PolicyState" -Name "PausedFeatureDate" -Silent

    # ---- Restore WU services ----
    @(
        @{N="wuauserv"; T="Manual"},
        @{N="WaaSMedicSvc"; T="Manual"},
        @{N="UsoSvc"; T="Automatic"},
        @{N="DoSvc"; T="Automatic"},
        @{N="BITS"; T="Manual"},
        @{N="TrustedInstaller"; T="Manual"},
        @{N="InstallService"; T="Manual"},
        @{N="msiserver"; T="Manual"},
        @{N="CryptSvc"; T="Automatic"},
        @{N="AppReadiness"; T="Manual"},
        @{N="uhssvc"; T="Manual"}
    ) | ForEach-Object { Restore-ServiceStartup -ServiceName $_.N -StartupType $_.T -Silent }

    # ---- Start critical services ----
    @("CryptSvc","BITS","wuauserv") | ForEach-Object {
        try { $s = Get-Service -Name $_ -EA 0; if ($s -and $s.Status -eq 'Stopped') { Invoke-RestoreServiceControl -Action Start -ServiceName $_ -Silent } } catch { }
    }

    # ---- Restore WU scheduled tasks (exhaustive) ----
    @(
        @{P="\Microsoft\Windows\WindowsUpdate\"; N="Scheduled Start"},
        @{P="\Microsoft\Windows\WindowsUpdate\"; N="sih"},
        @{P="\Microsoft\Windows\WindowsUpdate\"; N="sihboot"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Schedule Scan"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Schedule Scan Static Task"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="USO_UxBroker"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Report policies"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Schedule Maintenance Work"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Schedule Work"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Schedule Wake To Work"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="UpdateModelTask"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Refresh Settings"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Reboot"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Reboot_AC"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Reboot_Battery"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="RestoreDevice"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="ScanForUpdates"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="ScanForUpdatesAsUser"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="SmartRetry"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="WakeUpAndContinueUpdates"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="WakeUpAndScanForUpdates"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Start Oobe Expedite Work"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="StartOobeAppsScan_LicenseAccepted"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="StartOobeAppsScan_OobeAppReady"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="StartOobeAppsScanAfterUpdate"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="UUS Failover Task"},
        @{P="\Microsoft\Windows\WaaSMedic\"; N="PerformRemediation"},
        @{P="\Microsoft\Windows\Servicing\"; N="StartComponentCleanup"}
    ) | ForEach-Object { Enable-ScheduledTaskSafe -TaskPath $_.P -TaskName $_.N -Silent }

    # ---- Reset SoftwareDistribution and catroot2 ----
    Write-Log "Resetting Windows Update component stores..." -Level Info
    try {
        @("wuauserv","BITS","CryptSvc","msiserver") | ForEach-Object { Invoke-RestoreServiceControl -Action Stop -ServiceName $_ -Silent }
        $sdPath = "$env:SystemRoot\SoftwareDistribution"
        $sdBak = "$env:SystemRoot\SoftwareDistribution.bak"
        if (Test-Path $sdPath) {
            if (Test-Path $sdBak) { Invoke-RestoreFileMutation -Action Remove -Path $sdBak -Silent }
            try {
                if (Invoke-RestoreFileMutation -Action Rename -Path $sdPath -Destination "SoftwareDistribution.bak" -Silent) { Write-Log "Renamed SoftwareDistribution to .bak" -Level Success }
            } catch { Write-Log "SoftwareDistribution in use - will reset after reboot" -Level Warning }
        }
        $crPath = "$env:SystemRoot\System32\catroot2"
        $crBak = "$env:SystemRoot\System32\catroot2.bak"
        if (Test-Path $crPath) {
            if (Test-Path $crBak) { Invoke-RestoreFileMutation -Action Remove -Path $crBak -Silent }
            try {
                if (Invoke-RestoreFileMutation -Action Rename -Path $crPath -Destination "catroot2.bak" -Silent) { Write-Log "Renamed catroot2 to .bak" -Level Success }
            } catch { Write-Log "catroot2 in use - will reset after reboot" -Level Warning }
        }
        @("CryptSvc","BITS","wuauserv") | ForEach-Object { Invoke-RestoreServiceControl -Action Start -ServiceName $_ -Silent }
    } catch { Write-Log "Component reset partial - reboot recommended" -Level Warning }

    # ---- Re-register WU DLLs ----
    Write-Log "Re-registering Windows Update DLLs..." -Level Info
    @("atl.dll","urlmon.dll","mshtml.dll","shdocvw.dll","browseui.dll","jscript.dll","vbscript.dll",
      "scrrun.dll","msxml.dll","msxml3.dll","msxml6.dll","actxprxy.dll","softpub.dll","wintrust.dll",
      "dssenh.dll","rsaenh.dll","gpkcsp.dll","sccbase.dll","slbcsp.dll","cryptdlg.dll","oleaut32.dll",
      "ole32.dll","shell32.dll","initpki.dll","wuapi.dll","wuaueng.dll","wuaueng1.dll","wucltui.dll",
      "wups.dll","wups2.dll","wuweb.dll","qmgr.dll","qmgrprxy.dll","wucltux.dll","muweb.dll","wuwebv.dll"
    ) | ForEach-Object {
        $dll = "$env:SystemRoot\System32\$_"
        if (Test-Path $dll) { Invoke-RestoreNativeCommand -FilePath "regsvr32.exe" -ArgumentList @("/s",$dll) -ExpectedExitCodes @(0) -Scope "Machine" -Silent }
    }
    Write-Log "WU DLLs re-registered" -Level Success

    # ---- Winsock and proxy reset ----
    Invoke-RestoreNativeCommand -FilePath "netsh" -ArgumentList @("winsock","reset") -ExpectedExitCodes @(0) -Scope "Machine" -Silent
    Invoke-RestoreNativeCommand -FilePath "netsh" -ArgumentList @("winhttp","reset","proxy") -ExpectedExitCodes @(0) -Scope "Machine" -Silent
    Write-Log "Winsock and proxy reset" -Level Success

    # ---- Settings visibility ----
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "SettingsPageVisibility" -Silent

    # ---- Zone information / attachments ----
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments" -Name "SaveZoneInformation" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments" -Name "SaveZoneInformation" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments" -Name "ScanWithAntiVirus" -Silent

    # ---- Trigger WU scan ----
    try {
        $scanResult = Invoke-RestoreNativeCommand -FilePath "UsoClient.exe" -ArgumentList @("StartScan") -ExpectedExitCodes @(0) -Scope "Machine" -Silent
        if ($scanResult.Success -or $scanResult.Planned) { Write-Log "Windows Update scan triggered" -Level Success }
    } catch { Write-Log "Could not trigger WU scan - will happen after reboot" -Level Warning }

    Write-Log "Windows Update: Complete (reboot recommended)" -Level Success
}

function Restore-EdgeSettings {
    param([switch]$ForceManaged)
    Write-Log "=== MICROSOFT EDGE (COMPREHENSIVE) ===" -Level Section

    # Preserve enterprise-managed machine policy unless explicitly overridden.
    $edgeState = Get-EdgePolicyState
    Write-Log "Edge policy state: $($edgeState.Source)" -Level Info
    if ($edgeState.Managed -and -not $ForceManaged) {
        Write-Log "Managed Edge policies preserved; use ForceManaged only for a deliberate enterprise reset" -Level Warning
    } else {
        Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Silent
        Remove-RegistryKey -Path "HKCU:\SOFTWARE\Policies\Microsoft\Edge" -Silent
        Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate" -Silent
        Remove-RegistryKey -Path "HKCU:\SOFTWARE\Policies\Microsoft\EdgeUpdate" -Silent
    }

    # Edge (Legacy)
    Remove-RegistryValue -Path "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppContainer\Storage\microsoft.microsoftedge_8wekyb3d8bbwe\MicrosoftEdge\Main" -Name "DoNotTrack" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppContainer\Storage\microsoft.microsoftedge_8wekyb3d8bbwe\MicrosoftEdge\FlipAhead" -Name "FPEnabled" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppContainer\Storage\microsoft.microsoftedge_8wekyb3d8bbwe\MicrosoftEdge\ServiceUI" -Name "ShowSearchHistory" -Silent

    # Edge update IFEO
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\MicrosoftEdgeUpdate.exe" -Silent

    # Edge update services
    @(
        @{N="edgeupdate"; T="Automatic"},
        @{N="edgeupdatem"; T="Manual"},
        @{N="MicrosoftEdgeElevationService"; T="Manual"}
    ) | ForEach-Object { Restore-ServiceStartup -ServiceName $_.N -StartupType $_.T -Silent }

    # Edge update scheduled tasks
    Get-ScheduledTask -TaskName "MicrosoftEdgeUpdate*" -EA 0 | ForEach-Object {
        Invoke-RestoreScheduledTaskState -Action Enable -InputObject $_ -Silent
    }

    Write-Log "Edge: Complete" -Level Success
}

function Restore-ChromeSettings {
    Write-Log "=== CHROME & GOOGLE ===" -Level Section
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Google\Chrome" -Silent
    Remove-RegistryKey -Path "HKCU:\SOFTWARE\Policies\Google\Chrome" -Silent
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Google\Update" -Silent
    # Software Reporter Tool IFEO
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\software_reporter_tool.exe" -Silent
    # Google update services
    @(
        @{N="gupdate"; T="Automatic"},
        @{N="gupdatem"; T="Manual"},
        @{N="GoogleChromeElevationService"; T="Manual"}
    ) | ForEach-Object { Restore-ServiceStartup -ServiceName $_.N -StartupType $_.T -Silent }
    # Google update tasks
    Get-ScheduledTask -TaskName "GoogleUpdate*" -EA 0 | ForEach-Object {
        Invoke-RestoreScheduledTaskState -Action Enable -InputObject $_ -Silent
    }
    Write-Log "Chrome & Google: Complete" -Level Success
    # Also restore Firefox
    Restore-FirefoxSettings
}

function Restore-FirefoxSettings {
    Write-Log "=== FIREFOX ===" -Level Section
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Mozilla\Firefox" -Silent
    Remove-RegistryKey -Path "HKCU:\SOFTWARE\Policies\Mozilla\Firefox" -Silent
    Write-Log "Firefox: Complete" -Level Success
}

function Restore-OfficeSettings {
    Write-Log "=== MICROSOFT OFFICE ===" -Level Section
    @("15.0","16.0") | ForEach-Object {
        Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Office\$_\Common\General" -Name "ShownFirstRunOptin" -Silent
        Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Office\$_\Common" -Name "QMEnable" -Silent
        Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Office\$_\Common" -Name "UpdateReliabilityData" -Silent
        Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Office\$_\Common\Feedback" -Name "Enabled" -Silent
        Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Office\$_\Common\ClientTelemetry" -Name "DisableTelemetry" -Silent
        Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Office\$_\Outlook\Options\Mail" -Name "EnableLogging" -Silent
        Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Office\$_\Word\Options" -Name "EnableLogging" -Silent
    }
    # Office telemetry agent task
    Get-ScheduledTask -TaskPath "\Microsoft\Office\" -TaskName "OfficeTelemetryAgentFallBack*" -EA 0 | ForEach-Object {
        Invoke-RestoreScheduledTaskState -Action Enable -InputObject $_ -Silent
    }
    Get-ScheduledTask -TaskPath "\Microsoft\Office\" -TaskName "OfficeTelemetryAgentLogOn*" -EA 0 | ForEach-Object {
        Invoke-RestoreScheduledTaskState -Action Enable -InputObject $_ -Silent
    }
    # Subscription heartbeat
    Get-ScheduledTask -TaskPath "\Microsoft\Office\" -TaskName "Office*" -EA 0 | ForEach-Object {
        Invoke-RestoreScheduledTaskState -Action Enable -InputObject $_ -Silent
    }
    Write-Log "Office: Complete" -Level Success
}

function Restore-NetworkSettings {
    Write-Log "=== NETWORK CONNECTIVITY ===" -Level Section

    # ---- NCSI (Network Connectivity Status Indicator) ----
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator" -Silent
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet" -Name "EnableActiveProbing" -Silent

    # ---- Restore NCSI EXE if renamed ----
    $ncsiPath = "$env:SystemRoot\System32\NCSI.dll"
    if ((Test-Path "$ncsiPath.OLD") -and !(Test-Path $ncsiPath)) {
        try { Invoke-RestoreFileMutation -Action Rename -Path "$ncsiPath.OLD" -Destination "NCSI.dll" -Silent } catch { }
    }

    # ---- NLA and network services ----
    @(
        @{N="NlaSvc"; T="Automatic"},
        @{N="netprofm"; T="Manual"},
        @{N="Dnscache"; T="Automatic"},
        @{N="WinHttpAutoProxySvc"; T="Manual"},
        @{N="LanmanServer"; T="Automatic"},
        @{N="LanmanWorkstation"; T="Automatic"},
        @{N="lmhosts"; T="Manual"},
        @{N="iphlpsvc"; T="Automatic"},
        @{N="SSDPSRV"; T="Manual"},
        @{N="upnphost"; T="Manual"},
        @{N="Dhcp"; T="Automatic"},
        @{N="WlanSvc"; T="Automatic"}
    ) | ForEach-Object { Restore-ServiceStartup -ServiceName $_.N -StartupType $_.T -Silent }

    # ---- Admin shares ----
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" -Name "AutoShareServer" -Silent
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" -Name "AutoShareWks" -Silent

    Write-Log "Network Connectivity: Complete" -Level Success
}

function Restore-HostsFile {
    Write-Log "=== HOSTS FILE CLEANUP ===" -Level Section

    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    if (!(Test-Path $hostsPath)) { Write-Log "Hosts file not found" -Level Warning; return }

    try {
        $content = [System.IO.File]::ReadAllText($hostsPath, [System.Text.Encoding]::UTF8)
        $originalLen = $content.Length

        # Remove all privacy.sexy managed entries
        $content = $content -replace "(?m)^0\.0\.0\.0\t[^\r\n]+# managed by privacy\.sexy\r?\n?", ""
        $content = $content -replace "(?m)^::1\t[^\r\n]+# managed by privacy\.sexy\r?\n?", ""

        # Also remove common debloat script host blocks (0.0.0.0 entries for MS telemetry)
        $knownBlockedDomains = @(
            "vortex-win.data.microsoft.com","v10.events.data.microsoft.com",
            "v10c.events.data.microsoft.com","v10.vortex-win.data.microsoft.com",
            "watson.telemetry.microsoft.com","settings-win.data.microsoft.com",
            "settings.data.microsoft.com","telecommand.telemetry.microsoft.com",
            "self.events.data.microsoft.com","umwatson.events.data.microsoft.com",
            "functional.events.data.microsoft.com","oca.telemetry.microsoft.com",
            "eu-v10c.events.data.microsoft.com","us-v10c.events.data.microsoft.com"
        )
        foreach ($domain in $knownBlockedDomains) {
            $content = $content -replace "(?m)^0\.0\.0\.0\s+$([regex]::Escape($domain))\s*.*\r?\n?", ""
            $content = $content -replace "(?m)^::1\s+$([regex]::Escape($domain))\s*.*\r?\n?", ""
            $content = $content -replace "(?m)^127\.0\.0\.1\s+$([regex]::Escape($domain))\s*.*\r?\n?", ""
        }

        # Clean up excessive blank lines
        $content = $content -replace "(\r?\n){3,}", "`r`n`r`n"

        if ($content.Length -ne $originalLen) {
            if (Invoke-RestoreTextFileMutation -Path $hostsPath -Content $content -Scope "Machine" -Silent) { Write-Log "Removed blocked host entries from hosts file" -Level Success }
        } else {
            Write-Log "No blocked entries found in hosts file" -Level Info
        }
    } catch {
        Write-Log "Could not modify hosts file: $($_.Exception.Message)" -Level Warning
    }

    # ---- Flush DNS cache ----
    try {
        $flushResult = Invoke-RestoreNativeCommand -FilePath "ipconfig" -ArgumentList @("/flushdns") -ExpectedExitCodes @(0) -Scope "Machine" -Silent
        if ($flushResult.Success -or $flushResult.Planned) { Write-Log "DNS cache flushed" -Level Success }
    } catch { }

    Write-Log "Hosts File Cleanup: Complete" -Level Success
}

function Restore-GamingSettings {
    Write-Log "=== GAMING & XBOX ===" -Level Section
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Silent
    Remove-RegistryValue -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Silent
    @(
        @{N="XblAuthManager"; T="Manual"},
        @{N="XblGameSave"; T="Manual"},
        @{N="XboxGipSvc"; T="Manual"},
        @{N="XboxNetApiSvc"; T="Manual"},
        @{N="GamingServices"; T="Manual"},
        @{N="GamingServicesNet"; T="Manual"}
    ) | ForEach-Object { Restore-ServiceStartup -ServiceName $_.N -StartupType $_.T -Silent }
    Write-Log "Gaming & Xbox: Complete" -Level Success
}

function Restore-BiometricsSettings {
    Write-Log "=== BIOMETRICS ===" -Level Section
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Biometrics" -Silent
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Biometrics\Credential Provider" -Silent
    Restore-ServiceStartup -ServiceName "WbioSrvc" -StartupType "Manual" -Silent
    Write-Log "Biometrics: Complete" -Level Success
}

function Restore-ClipboardSettings {
    Write-Log "=== CLIPBOARD ===" -Level Section
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "AllowClipboardHistory" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "AllowCrossDeviceClipboard" -Silent
    # Clipboard service
    @("cbdhsvc","cbdhsvc_*") | ForEach-Object {
        $svc = Get-Service -Name $_ -EA 0
        if ($svc) { Restore-ServiceStartup -ServiceName $svc.Name -StartupType "Automatic" -Silent }
    }
    Write-Log "Clipboard: Complete" -Level Success
}

function Restore-ErrorReporting {
    Write-Log "=== ERROR REPORTING ===" -Level Section
    Remove-RegistryKey -Path "HKLM:\Software\Policies\Microsoft\Windows\Windows Error Reporting" -Silent
    Remove-RegistryValue -Path "HKLM:\Software\Microsoft\Windows\Windows Error Reporting" -Name "Disabled" -Silent
    Remove-RegistryValue -Path "HKLM:\Software\Microsoft\Windows\Windows Error Reporting\Consent" -Name "DefaultConsent" -Silent
    Remove-RegistryValue -Path "HKLM:\Software\Microsoft\Windows\Windows Error Reporting\Consent" -Name "DefaultOverrideBehavior" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name "DontSendAdditionalData" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name "LoggingDisabled" -Silent
    Restore-ServiceStartup -ServiceName "wersvc" -StartupType "Manual" -Silent
    Restore-ServiceStartup -ServiceName "wercplsupport" -StartupType "Manual" -Silent
    Write-Log "Error Reporting: Complete" -Level Success
}

function Restore-SecurityProtocols {
    Write-Log "=== SECURITY PROTOCOLS ===" -Level Section
    Write-Log "Note: Security protocol changes are left as-is (hardening) unless explicitly requested" -Level Info
    # These are SECURITY HARDENING changes - we restore the registry keys but don't weaken security
    # Only restore things that might break functionality

    # ---- LSA protections (restore defaults, not weaken) ----
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name "RestrictAnonymousSAM" -Silent
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name "RestrictAnonymous" -Silent
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name "NoLMHash" -Silent
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name "LmCompatibilityLevel" -Silent

    # ---- Admin shares (restore) ----
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" -Name "RestrictNullSessAccess" -Silent
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" -Name "AutoShareServer" -Silent
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" -Name "AutoShareWks" -Silent

    # ---- Remote Assistance ----
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance" -Name "fAllowToGetHelp" -Silent

    # ---- Windows Connect Now ----
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WCN\Registrars" -Silent

    # ---- SMBv1 driver (restore if disabled) ----
    Restore-ServiceStartup -ServiceName "mrxsmb10" -StartupType "Manual" -Silent

    Write-Log "Security Protocols: Complete" -Level Success
}

function Restore-RemoteDesktopSettings {
    Write-Log "=== REMOTE DESKTOP ===" -Level Section
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Silent
    @(
        @{N="TermService"; T="Manual"},
        @{N="UmRdpService"; T="Manual"},
        @{N="SessionEnv"; T="Manual"}
    ) | ForEach-Object { Restore-ServiceStartup -ServiceName $_.N -StartupType $_.T -Silent }
    Write-Log "Remote Desktop: Complete" -Level Success
}

function Restore-AccessibilitySettings {
    Write-Log "=== ACCESSIBILITY ===" -Level Section
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableCAD" -Silent
    Restore-ServiceStartup -ServiceName "TabletInputService" -StartupType "Manual" -Silent
    Write-Log "Accessibility: Complete" -Level Success
}

function Restore-InputSettings {
    Write-Log "=== INPUT ===" -Level Section
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore" -Name "HarvestContacts" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Personalization\Settings" -Name "AcceptedPrivacyPolicy" -Silent
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization" -Silent
    Write-Log "Input: Complete" -Level Success
}

function Restore-PowerSettings {
    Write-Log "=== POWER & HIBERNATION ===" -Level Section
    # Restore hibernation if it was disabled
    try {
        $hibernateResult = Invoke-RestoreNativeCommand -FilePath "powercfg" -ArgumentList @("/hibernate","on") -ExpectedExitCodes @(0) -Scope "Machine" -Silent
        if ($hibernateResult.Success -or $hibernateResult.Planned) { Write-Log "Hibernation re-enabled" -Level Success }
    } catch { Write-Log "Could not re-enable hibernation" -Level Warning }
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "HibernateEnabled" -Silent
    Write-Log "Power: Complete" -Level Success
}

function Restore-MemoryPerformance {
    Write-Log "=== MEMORY & PERFORMANCE ===" -Level Section
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "ClearPageFileAtShutdown" -Silent
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters" -Name "EnablePrefetcher" -Silent
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters" -Name "EnableSuperfetch" -Silent
    # SideBySide configuration
    Remove-RegistryValue -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\SideBySide\Configuration" -Name "DisableResetbase" -Silent
    Write-Log "Memory & Performance: Complete" -Level Success
}

function Restore-StorageSettings {
    Write-Log "=== STORAGE ===" -Level Section
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense" -Name "AllowStorageSenseGlobal" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" -Name "ShippedWithReserves" -Silent
    Write-Log "Storage: Complete" -Level Success
}

function Restore-PrintingSettings {
    Write-Log "=== PRINTING ===" -Level Section
    Restore-ServiceStartup -ServiceName "Spooler" -StartupType "Automatic" -Silent
    Restore-ServiceStartup -ServiceName "PrintNotify" -StartupType "Manual" -Silent
    Write-Log "Printing: Complete" -Level Success
}

function Restore-UACSettings {
    Write-Log "=== UAC & SECURITY POLICIES ===" -Level Section
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorUser" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "PromptOnSecureDesktop" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableInstallerDetection" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableSecureUIAPaths" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "FilterAdministratorToken" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableVirtualization" -Silent
    # Windows Installer elevated privileges
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer" -Name "AlwaysInstallElevated" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer" -Name "AlwaysInstallElevated" -Silent
    # CMD disable
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "DisableCMD" -Silent
    # Lock screen
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreen" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreenCamera" -Silent
    Write-Log "UAC: Complete" -Level Success
}

function Restore-OneDriveSettings {
    Write-Log "=== ONEDRIVE ===" -Level Section
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" -Silent
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" -Name "System.IsPinnedToNameSpaceTree" -Value 1 -Silent
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Classes\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" -Name "System.IsPinnedToNameSpaceTree" -Value 1 -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" -Name "OneDrive" -Silent
    Set-RegistryValue -Path "HKCU:\Environment" -Name "OneDrive" -Value "%USERPROFILE%\OneDrive" -Type "ExpandString" -Silent
    Get-ScheduledTask -TaskPath "\" -TaskName "OneDrive*" -EA 0 | ForEach-Object {
        Invoke-RestoreScheduledTaskState -Action Enable -InputObject $_ -Silent
    }
    Write-Log "OneDrive: Complete" -Level Success
}

function Restore-SyncSettings {
    Write-Log "=== SYNC ===" -Level Section
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" -Silent
    # Individual sync group overrides
    @("Credentials","Language") | ForEach-Object {
        Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync\Groups\$_" -Name "Enabled" -Silent
    }
    # Sync services
    @("OneSyncSvc","OneSyncSvc_*") | ForEach-Object {
        $svc = Get-Service -Name $_ -EA 0
        if ($svc) { Restore-ServiceStartup -ServiceName $svc.Name -StartupType "Automatic" -Silent }
    }
    Write-Log "Sync: Complete" -Level Success
}

function Restore-WindowsInsiderSettings {
    Write-Log "=== INSIDER ===" -Level Section
    Remove-RegistryKey -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\UI\Visibility" -Name "HideInsiderPage" -Silent
    Restore-ServiceStartup -ServiceName "wisvc" -StartupType "Manual" -Silent
    Write-Log "Insider: Complete" -Level Success
}

function Restore-ContextMenus {
    Write-Log "=== CONTEXT MENUS ===" -Level Section
    Remove-RegistryKey -Path "HKCU:\SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked" -Name "{7AD84985-87B4-4a16-BE58-8B72A5B390F7}" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked" -Name "{1d27f844-3a1f-4410-85ac-14651078412d}" -Silent
    Write-Log "Context Menus: Complete" -Level Success
}

function Restore-NvidiaTelemetry {
    Write-Log "=== NVIDIA TELEMETRY ===" -Level Section
    # Nvidia telemetry tasks
    @("NvTmMon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}",
      "NvTmRep_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}",
      "NvTmRepOnLogon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}"
    ) | ForEach-Object {
        Enable-ScheduledTaskSafe -TaskPath "\" -TaskName $_ -Silent
    }
    Restore-ServiceStartup -ServiceName "NvTelemetryContainer" -StartupType "Automatic" -Silent
    # Nvidia driver telemetry registry
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup" -Name "SendTelemetryData" -Silent
    Remove-RegistryValue -Path "HKLM:\Software\Nvidia Corporation\NvControlPanel2\Client" -Name "OptInOrOutPreference" -Silent
    Write-Log "Nvidia: Complete" -Level Success
}

function Restore-ThirdPartyServices {
    Write-Log "=== THIRD-PARTY SERVICES ===" -Level Section
    @(
        @{N="AdobeARMservice"; T="Automatic"; Opt=$true},
        @{N="adobeupdateservice"; T="Automatic"; Opt=$true},
        @{N="dbupdate"; T="Automatic"; Opt=$true},
        @{N="dbupdatem"; T="Automatic"; Opt=$true},
        @{N="WMPNetworkSvc"; T="Manual"; Opt=$false},
        @{N="Razer Game Scanner Service"; T="Manual"; Opt=$true},
        @{N="LogiRegistryService"; T="Automatic"; Opt=$true},
        @{N="VSStandardCollectorService150"; T="Manual"; Opt=$true}
    ) | ForEach-Object {
        $svc = Get-Service -Name $_.N -EA 0
        if ($svc -or !$_.Opt) { Restore-ServiceStartup -ServiceName $_.N -StartupType $_.T -Silent }
    }
    # Adobe update task
    Get-ScheduledTask -TaskName "Adobe Acrobat Update Task" -EA 0 | ForEach-Object {
        Invoke-RestoreScheduledTaskState -Action Enable -InputObject $_ -Silent
    }
    # Dropbox tasks
    Get-ScheduledTask -TaskName "DropboxUpdate*" -EA 0 | ForEach-Object {
        Invoke-RestoreScheduledTaskState -Action Enable -InputObject $_ -Silent
    }
    # CCleaner
    Remove-RegistryValue -Path "HKCU:\Software\Piriform\CCleaner" -Name "Monitoring" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Piriform\CCleaner" -Name "HelpImproveCCleaner" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Piriform\CCleaner" -Name "SystemMonitoring" -Silent
    Write-Log "Third-Party Services: Complete" -Level Success
}

function Restore-MiscPolicies {
    Write-Log "=== MISC POLICIES & SETTINGS ===" -Level Section

    # ---- Snipping Tool ----
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\TabletPC" -Name "DisableSnippingTool" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "DisabledHotkeys" -Silent
    Remove-RegistryValue -Path "HKCU:\Control Panel\Keyboard" -Name "PrintScreenKeyForSnippingEnabled" -Silent

    # ---- Copilot auto-launch ----
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowCopilotButton" -Silent

    # ---- Retail Demo ----
    Restore-ServiceStartup -ServiceName "RetailDemo" -StartupType "Manual" -Silent

    # ---- Microsoft Account Sign-in Assistant ----
    Restore-ServiceStartup -ServiceName "wlidsvc" -StartupType "Manual" -Silent

    # ---- Downloaded Maps Manager ----
    Restore-ServiceStartup -ServiceName "MapsBroker" -StartupType "Automatic" -Silent

    # ---- User Data services ----
    @("UserDataSvc","UserDataSvc_*","UnistoreSvc","UnistoreSvc_*") | ForEach-Object {
        $svc = Get-Service -Name $_ -EA 0
        if ($svc) { Restore-ServiceStartup -ServiceName $svc.Name -StartupType "Manual" -Silent }
    }

    # ---- Messaging Service ----
    @("MessagingService","MessagingService_*") | ForEach-Object {
        $svc = Get-Service -Name $_ -EA 0
        if ($svc) { Restore-ServiceStartup -ServiceName $svc.Name -StartupType "Manual" -Silent }
    }

    # ---- Push Notifications ----
    @(
        @{N="WpnService"; T="Automatic"},
        @{N="WpnUserService"; T="Automatic"}
    ) | ForEach-Object {
        $svc = Get-Service -Name $_.N -EA 0
        if ($svc) { Restore-ServiceStartup -ServiceName $_.N -StartupType $_.T -Silent }
        # Also wildcard versions
        $wc = Get-Service -Name "$($_.N)_*" -EA 0
        if ($wc) { Restore-ServiceStartup -ServiceName $wc.Name -StartupType $_.T -Silent }
    }

    # ---- Shadow Copy (Volume Snapshot) ----
    Restore-ServiceStartup -ServiceName "VSS" -StartupType "Manual" -Silent

    # ---- Location Service ----
    Restore-ServiceStartup -ServiceName "lfsvc" -StartupType "Manual" -Silent

    # ---- DEP (Data Execution Prevention) - restore default ----
    try {
        $depResult = Invoke-RestoreNativeCommand -FilePath "bcdedit" -ArgumentList @("/set","{current}","nx","OptIn") -ExpectedExitCodes @(0) -Scope "Machine" -Silent
        if ($depResult.Success -or $depResult.Planned) { Write-Log "DEP restored to OptIn" -Level Success }
    } catch { }

    # ---- AutoPlay/AutoRun ----
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Silent
    Remove-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" -Name "DisableAutoplay" -Silent

    # ---- Steps Recorder (restore if renamed) ----
    $psrPath = "$env:SystemRoot\System32\psr.exe"
    if ((Test-Path "$psrPath.OLD") -and !(Test-Path $psrPath)) {
        try { Invoke-RestoreFileMutation -Action Rename -Path "$psrPath.OLD" -Destination "psr.exe" -Silent } catch { }
    }

    Write-Log "Misc Policies: Complete" -Level Success
}

function Restore-Services {
    Write-Log "=== CORE WINDOWS SERVICES ===" -Level Section
    $servicesToRestore = @{
        'wscsvc'='Automatic';'MpsSvc'='Automatic';'BFE'='Automatic'
        'TrkWks'='Automatic';'iphlpsvc'='Automatic';'lmhosts'='Manual';'NlaSvc'='Automatic'
        'Dnscache'='Automatic';'WinHttpAutoProxySvc'='Manual';'LanmanServer'='Automatic'
        'LanmanWorkstation'='Automatic';'SSDPSRV'='Manual';'upnphost'='Manual';'netprofm'='Manual'
        'bthserv'='Manual';'BTAGService'='Manual';'BthAvctpSvc'='Manual'
        'TermService'='Manual';'UmRdpService'='Manual';'SessionEnv'='Manual';'RemoteRegistry'='Disabled'
        'Audiosrv'='Automatic';'AudioEndpointBuilder'='Automatic'
        'Spooler'='Automatic';'PrintNotify'='Manual'
        'PhoneSvc'='Manual';'TapiSrv'='Manual';'SmsRouter'='Manual'
        'XblAuthManager'='Manual';'XblGameSave'='Manual';'XboxGipSvc'='Manual';'XboxNetApiSvc'='Manual'
        'GamingServices'='Manual';'GamingServicesNet'='Manual'
        'wlidsvc'='Manual';'MapsBroker'='Automatic';'lfsvc'='Manual';'VSS'='Manual'
        'WalletService'='Manual';'WpcMonSvc'='Manual';'WbioSrvc'='Manual'
        'TabletInputService'='Manual';'Fax'='Manual';'WMPNetworkSvc'='Manual';'icssvc'='Manual'
        'wisvc'='Manual';'CDPSvc'='Automatic';'ShellHWDetection'='Automatic'
        'Themes'='Automatic';'FontCache'='Automatic';'EventLog'='Automatic';'Schedule'='Automatic'
        'Power'='Automatic';'ProfSvc'='Automatic';'gpsvc'='Automatic';'Winmgmt'='Automatic'
        'CryptSvc'='Automatic';'Dhcp'='Automatic';'RpcSs'='Automatic';'SamSs'='Automatic'
        'WpnService'='Automatic';'W32Time'='Manual';'WlanSvc'='Automatic';'RetailDemo'='Manual'
    }
    $counter = 0
    foreach ($svc in $servicesToRestore.GetEnumerator()) {
        $counter++; Restore-ServiceStartup -ServiceName $svc.Key -StartupType $svc.Value -Silent
    }
    Write-Log "Services: $counter processed" -Level Success
}

function Restore-ScheduledTasks {
    Write-Log "=== SCHEDULED TASKS ===" -Level Section
    $tasksToEnable = @(
        @{P="\Microsoft\Windows\Application Experience\"; N="Microsoft Compatibility Appraiser"},
        @{P="\Microsoft\Windows\Application Experience\"; N="ProgramDataUpdater"},
        @{P="\Microsoft\Windows\Application Experience\"; N="StartupAppTask"},
        @{P="\Microsoft\Windows\Application Experience\"; N="PcaPatchDbTask"},
        @{P="\Microsoft\Windows\Autochk\"; N="Proxy"},
        @{P="\Microsoft\Windows\Customer Experience Improvement Program\"; N="Consolidator"},
        @{P="\Microsoft\Windows\Customer Experience Improvement Program\"; N="UsbCeip"},
        @{P="\Microsoft\Windows\Customer Experience Improvement Program\"; N="KernelCeipTask"},
        @{P="\Microsoft\Windows\Defrag\"; N="ScheduledDefrag"},
        @{P="\Microsoft\Windows\Device Information\"; N="Device"},
        @{P="\Microsoft\Windows\Device Information\"; N="Device User"},
        @{P="\Microsoft\Windows\DiskDiagnostic\"; N="Microsoft-Windows-DiskDiagnosticDataCollector"},
        @{P="\Microsoft\Windows\DiskFootprint\"; N="Diagnostics"},
        @{P="\Microsoft\Windows\DiskFootprint\"; N="StorageSense"},
        @{P="\Microsoft\Windows\Feedback\Siuf\"; N="DmClient"},
        @{P="\Microsoft\Windows\Feedback\Siuf\"; N="DmClientOnScenarioDownload"},
        @{P="\Microsoft\Windows\Maps\"; N="MapsToastTask"},
        @{P="\Microsoft\Windows\Maps\"; N="MapsUpdateTask"},
        @{P="\Microsoft\Windows\PI\"; N="Sqm-Tasks"},
        @{P="\Microsoft\Windows\Power Efficiency Diagnostics\"; N="AnalyzeSystem"},
        @{P="\Microsoft\Windows\RemoteAssistance\"; N="RemoteAssistanceTask"},
        @{P="\Microsoft\Windows\Servicing\"; N="StartComponentCleanup"},
        @{P="\Microsoft\Windows\SettingSync\"; N="NetworkStateChangeTask"},
        @{P="\Microsoft\Windows\SettingSync\"; N="BackgroundUploadTask"},
        @{P="\Microsoft\Windows\SettingSync\"; N="BackupTask"},
        @{P="\Microsoft\Windows\Windows Defender\"; N="Windows Defender Cache Maintenance"},
        @{P="\Microsoft\Windows\Windows Defender\"; N="Windows Defender Cleanup"},
        @{P="\Microsoft\Windows\Windows Defender\"; N="Windows Defender Scheduled Scan"},
        @{P="\Microsoft\Windows\Windows Defender\"; N="Windows Defender Verification"},
        @{P="\Microsoft\Windows\Windows Defender\"; N="Windows Defender ExploitGuard MDM Refresh"},
        @{P="\Microsoft\Windows\WindowsUpdate\"; N="Scheduled Start"},
        @{P="\Microsoft\Windows\WindowsUpdate\"; N="sih"},
        @{P="\Microsoft\Windows\WindowsUpdate\"; N="sihboot"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Schedule Scan"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Schedule Scan Static Task"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="USO_UxBroker"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Report policies"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Schedule Maintenance Work"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Schedule Work"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Schedule Wake To Work"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="UpdateModelTask"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Refresh Settings"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Reboot"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Reboot_AC"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Reboot_Battery"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="RestoreDevice"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="ScanForUpdates"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="ScanForUpdatesAsUser"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="SmartRetry"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="WakeUpAndContinueUpdates"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="WakeUpAndScanForUpdates"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="Start Oobe Expedite Work"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="StartOobeAppsScan_LicenseAccepted"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="StartOobeAppsScan_OobeAppReady"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="StartOobeAppsScanAfterUpdate"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\"; N="UUS Failover Task"},
        @{P="\Microsoft\Windows\WaaSMedic\"; N="PerformRemediation"},
        @{P="\Microsoft\Windows\Maintenance\"; N="WinSAT"},
        @{P="\Microsoft\Windows\NetTrace\"; N="GatherNetworkInfo"},
        @{P="\Microsoft\Windows\Diagnosis\"; N="Scheduled"},
        @{P="\Microsoft\Windows\Diagnosis\"; N="RecommendedTroubleshootingScanner"},
        @{P="\Microsoft\Windows\Clip\"; N="License Validation"},
        @{P="\Microsoft\Windows\File Classification Infrastructure\"; N="Property Definition Sync"},
        @{P="\Microsoft\Windows\Management\Provisioning\"; N="Logon"},
        @{P="\Microsoft\Windows\CloudExperienceHost\"; N="CreateObjectTask"},
        @{P="\Microsoft\Windows\Windows Error Reporting\"; N="QueueReporting"}
    ) | ForEach-Object { Enable-ScheduledTaskSafe -TaskPath $_.P -TaskName $_.N -Silent }

    Restore-MissingScheduledTask | Out-Null
    Write-Log "Scheduled Tasks: Complete" -Level Success
}

function Restore-CryptoProtocols {
    Write-Log "=== CRYPTO PROTOCOLS & SCHANNEL ===" -Level Section

    # ---- SCHANNEL Protocol Defaults (remove all explicit Enabled/DisabledByDefault overrides) ----
    # Restoring to Windows defaults means removing explicit registry entries
    # Windows will use its built-in defaults (TLS 1.2/1.3 enabled, SSL 2.0/3.0/TLS 1.0/1.1 disabled)
    Write-Log "Restoring SCHANNEL protocol settings to Windows defaults..." -Level Info
    $schBase = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL"

    # Protocols - remove all explicit overrides (let Windows manage defaults)
    @("SSL 2.0","SSL 3.0","TLS 1.0","TLS 1.1","TLS 1.2","TLS 1.3","DTLS 1.0","DTLS 1.2") | ForEach-Object {
        $proto = $_
        @("Client","Server") | ForEach-Object {
            $path = "$schBase\Protocols\$proto\$_"
            Remove-RegistryValue -Path $path -Name "Enabled" -Silent
            Remove-RegistryValue -Path $path -Name "DisabledByDefault" -Silent
        }
    }

    # ---- Ciphers (remove explicit disable overrides, let Windows manage) ----
    Write-Log "Restoring cipher settings..." -Level Info
    @(
        "DES 56/56","NULL","RC2 128/128","RC2 40/128","RC2 56/128",
        "RC4 128/128","RC4 40/128","RC4 56/128","RC4 64/128",
        "Triple DES 168","Triple DES 168/168"
    ) | ForEach-Object {
        $cipherPath = "$schBase\Ciphers\$_"
        Remove-RegistryValue -Path $cipherPath -Name "Enabled" -Silent
        if (Test-Path $cipherPath) {
            $props = (Get-Item $cipherPath -EA 0).Property
            if (!$props -or $props.Count -eq 0) { Remove-RegistryKey -Path $cipherPath -Silent }
        }
    }

    # ---- Hashes ----
    Write-Log "Restoring hash algorithm settings..." -Level Info
    @("MD5","SHA") | ForEach-Object {
        $hashPath = "$schBase\Hashes\$_"
        Remove-RegistryValue -Path $hashPath -Name "Enabled" -Silent
        if (Test-Path $hashPath) {
            $props = (Get-Item $hashPath -EA 0).Property
            if (!$props -or $props.Count -eq 0) { Remove-RegistryKey -Path $hashPath -Silent }
        }
    }

    # ---- Key Exchange Algorithms (remove minimum key length overrides) ----
    Write-Log "Restoring key exchange settings..." -Level Info
    @("Diffie-Hellman","PKCS") | ForEach-Object {
        $kePath = "$schBase\KeyExchangeAlgorithms\$_"
        Remove-RegistryValue -Path $kePath -Name "ClientMinKeyBitLength" -Silent
        Remove-RegistryValue -Path $kePath -Name "ServerMinKeyBitLength" -Silent
    }

    # ---- SCHANNEL base settings ----
    Remove-RegistryValue -Path $schBase -Name "AllowInsecureRenegoClients" -Silent
    Remove-RegistryValue -Path $schBase -Name "AllowInsecureRenegoServers" -Silent
    Remove-RegistryValue -Path $schBase -Name "DisableRenegoOnClient" -Silent
    Remove-RegistryValue -Path $schBase -Name "DisableRenegoOnServer" -Silent
    Remove-RegistryValue -Path $schBase -Name "UseScsvForTls" -Silent

    # ---- .NET Framework Strong Crypto (remove forced overrides) ----
    Write-Log "Restoring .NET Framework crypto settings..." -Level Info
    @(
        "HKLM:\SOFTWARE\Microsoft\.NETFramework\v2.0.50727",
        "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v2.0.50727",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319"
    ) | ForEach-Object {
        Remove-RegistryValue -Path $_ -Name "SchUseStrongCrypto" -Silent
        Remove-RegistryValue -Path $_ -Name "SystemDefaultTlsVersions" -Silent
    }

    # ---- WinRM basic auth (remove policy override) ----
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRM\Client" -Name "AllowBasic" -Silent
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service" -Name "AllowBasic" -Silent

    # ---- NetBIOS (restore to default DHCP-controlled) ----
    Write-Log "Restoring NetBIOS to default (DHCP-controlled)..." -Level Info
    try {
        $key = "HKLM:\SYSTEM\CurrentControlSet\services\NetBT\Parameters\Interfaces"
        if (Test-Path $key) {
            Get-ChildItem $key -EA 0 | ForEach-Object {
                Set-RegistryValue -Path "$key\$($_.PSChildName)" -Name "NetbiosOptions" -Value 0 -Type "DWord" -Silent
            }
        }
    } catch { Write-Log "Could not restore NetBIOS settings" -Level Warning }

    # ---- SEHOP (Structured Exception Handler Overwrite Protection) ----
    Remove-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel" -Name "DisableExceptionChainValidation" -Silent

    Write-Log "Crypto Protocols: Complete" -Level Success
    # Also handle related security protocol settings
    Restore-SecurityProtocols
}

function Restore-WindowsFeatures {
    Write-Log "=== WINDOWS OPTIONAL FEATURES ===" -Level Section
    Write-Log "Re-enabling Windows optional features (this may take several minutes)..." -Level Info

    # Features that are enabled by default on a fresh Windows install
    $defaultEnabledFeatures = @(
        "MicrosoftWindowsPowerShellV2",
        "MicrosoftWindowsPowerShellV2Root",
        "WCF-TCP-PortSharing45",
        "SmbDirect",
        "Printing-Foundation-Features",
        "Printing-PrintToPDFServices-Features",
        "Printing-XPSServices-Features",
        "SearchEngine-Client-Package",
        "MediaPlayback",
        "WindowsMediaPlayer",
        "WorkFolders-Client"
    )

    # Features disabled by default (skip restoring these - they were disabled for security)
    $defaultDisabledFeatures = @(
        "SMB1Protocol","SMB1Protocol-Client","SMB1Protocol-Server",
        "TelnetClient","TFTP","DirectPlay","LegacyComponents",
        "FaxServicesClientPackage",
        "Internet-Explorer-Optional-amd64","Internet-Explorer-Optional-x64",
        "Xps-Foundation-Xps-Viewer","ScanManagementConsole",
        "Printing-Foundation-InternetPrinting-Client",
        "Printing-Foundation-LPDPrintService","Printing-Foundation-LPRPortMonitor"
    )

    foreach ($feature in $defaultEnabledFeatures) {
        try {
            $f = Get-WindowsOptionalFeature -FeatureName $feature -Online -EA Stop
            if ($f -and $f.State -ne 'Enabled') {
                Write-Log "Re-enabling feature: $feature" -Level Info
                if (Invoke-RestoreOptionalFeature -FeatureName $feature -Silent) { Write-Log "Enabled: $feature" -Level Success }
            }
        } catch {
            Write-Log "Could not enable $feature : $($_.Exception.Message)" -Level Warning
        }
    }

    Write-Log "Note: Security features (SMB1, Telnet, TFTP, DirectPlay) left disabled intentionally" -Level Info
    Write-Log "Windows Features: Complete" -Level Success
}

function Restore-AppxPackages {
    Write-Log "=== APPX PACKAGE RESTORATION ===" -Level Section
    Write-Log "Attempting to reinstall removed Windows Store apps..." -Level Info

    # Core Windows packages that should be present on a stock install
    $corePackages = @(
        @{N="Microsoft.WindowsStore"; P="cw5n1h2txyewy"},
        @{N="Microsoft.StorePurchaseApp"; P="cw5n1h2txyewy"},
        @{N="Microsoft.DesktopAppInstaller"; P="cw5n1h2txyewy"},
        @{N="Microsoft.WindowsCalculator"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.Photos"; P="cw5n1h2txyewy"},
        @{N="Microsoft.WindowsCamera"; P="cw5n1h2txyewy"},
        @{N="Microsoft.WindowsAlarms"; P="cw5n1h2txyewy"},
        @{N="Microsoft.WindowsSoundRecorder"; P="cw5n1h2txyewy"},
        @{N="Microsoft.WindowsMaps"; P="cw5n1h2txyewy"},
        @{N="Microsoft.WindowsFeedbackHub"; P="cw5n1h2txyewy"},
        @{N="Microsoft.GetHelp"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Getstarted"; P="cw5n1h2txyewy"},
        @{N="Microsoft.MSPaint"; P="cw5n1h2txyewy"},
        @{N="Microsoft.People"; P="cw5n1h2txyewy"},
        @{N="Microsoft.ScreenSketch"; P="cw5n1h2txyewy"},
        @{N="Microsoft.MicrosoftStickyNotes"; P="8wekyb3d8bbwe"},
        @{N="Microsoft.MicrosoftOfficeHub"; P="cw5n1h2txyewy"},
        @{N="microsoft.windowscommunicationsapps"; P="cw5n1h2txyewy"},
        @{N="Microsoft.YourPhone"; P="cw5n1h2txyewy"},
        @{N="Microsoft.HEIFImageExtension"; P="cw5n1h2txyewy"},
        @{N="Microsoft.VP9VideoExtensions"; P="cw5n1h2txyewy"},
        @{N="Microsoft.WebMediaExtensions"; P="cw5n1h2txyewy"},
        @{N="Microsoft.WebpImageExtension"; P="cw5n1h2txyewy"},
        @{N="Microsoft.RawImageExtension"; P="cw5n1h2txyewy"},
        @{N="Microsoft.HEVCVideoExtension"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Xbox.TCUI"; P="cw5n1h2txyewy"},
        @{N="Microsoft.XboxIdentityProvider"; P="cw5n1h2txyewy"},
        @{N="Microsoft.XboxGamingOverlay"; P="cw5n1h2txyewy"},
        @{N="Microsoft.XboxGameOverlay"; P="cw5n1h2txyewy"},
        @{N="Microsoft.XboxSpeechToTextOverlay"; P="cw5n1h2txyewy"},
        @{N="Microsoft.GamingApp"; P="cw5n1h2txyewy"},
        @{N="Microsoft.BingWeather"; P="cw5n1h2txyewy"},
        @{N="Microsoft.BingNews"; P="cw5n1h2txyewy"},
        @{N="Microsoft.ZuneMusic"; P="cw5n1h2txyewy"},
        @{N="Microsoft.ZuneVideo"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Todos"; P="cw5n1h2txyewy"}
    )

    # Critical system packages (must be present for Windows to function)
    $systemPackages = @(
        @{N="Microsoft.Windows.SecHealthUI"; P="cw5n1h2txyewy"},
        @{N="Microsoft.SecHealthUI"; P="8wekyb3d8bbwe"},
        @{N="Microsoft.AAD.BrokerPlugin"; P="cw5n1h2txyewy"},
        @{N="Microsoft.AccountsControl"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.CloudExperienceHost"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.ContentDeliveryManager"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.Search"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.ShellExperienceHost"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.PeopleExperienceHost"; P="cw5n1h2txyewy"},
        @{N="Microsoft.CredDialogHost"; P="cw5n1h2txyewy"},
        @{N="Microsoft.BioEnrollment"; P="cw5n1h2txyewy"},
        @{N="Microsoft.LockApp"; P="cw5n1h2txyewy"},
        @{N="Microsoft.ECApp"; P="cw5n1h2txyewy"},
        @{N="Microsoft.AsyncTextService"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Win32WebViewHost"; P="cw5n1h2txyewy"},
        @{N="Microsoft.PPIProjection"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.Apprep.ChxApp"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.CapturePicker"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.OOBENetworkCaptivePortal"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.OOBENetworkConnectionFlow"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.PinningConfirmationDialog"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.ParentalControls"; P="cw5n1h2txyewy"},
        @{N="Microsoft.XboxGameCallableUI"; P="cw5n1h2txyewy"},
        @{N="NcsiUwpApp"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.PrintQueueActionCenter"; P="cw5n1h2txyewy"},
        @{N="MicrosoftWindows.Client.CBS"; P="cw5n1h2txyewy"},
        @{N="MicrosoftWindows.UndockedDevKit"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.SecondaryTileExperience"; P="cw5n1h2txyewy"},
        @{N="Microsoft.Windows.XGpuEjectDialog"; P="cw5n1h2txyewy"}
    )

    $allPackages = $systemPackages + $corePackages
    $installed = 0; $failed = 0; $skipped = 0

    foreach ($pkg in $allPackages) {
        $name = $pkg.N
        $pub = $pkg.P

        # Check if already installed
        if (Get-AppxPackageSafe -Name $name) {
            $skipped++; continue
        }

        # Method 1: Try manifest from another user profile
        $otherPkgs = @(Get-AppxPackageSafe -Name $name -AllUsers)
        $success = $false
        if ($otherPkgs) {
            foreach ($op in $otherPkgs) {
                if ($op.InstallLocation -and (Test-Path "$($op.InstallLocation)\AppxManifest.xml")) {
                    try {
                        $registration = Invoke-RestoreAppxRegistration -PackageName $name -ManifestPath "$($op.InstallLocation)\AppxManifest.xml" -Scope "CurrentUser" -Silent
                        if ($registration.Success -or $registration.Planned) {
                            $installed++; $success = $true
                            Write-Log "Reinstalled: $name (manifest)" -Level Success
                            break
                        }
                    } catch { }
                }
            }
        }
        if ($success) { continue }

        # Method 2: Try package family name
        $familyName = "${name}_${pub}"
        try {
            $registration = Invoke-RestoreAppxRegistration -PackageName $name -PackageFamilyName $familyName -Scope "CurrentUser" -Silent
            if ($registration.Success -or $registration.Planned) {
                $installed++
                Write-Log "Reinstalled: $name (family)" -Level Success
                continue
            }
        } catch { Write-Verbose "Could not re-register package family $familyName" }

        $failed++
        Write-Log "Could not reinstall: $name (may need Store or Windows Update)" -Level Warning
    }

    Write-Log "AppX Packages: $installed reinstalled, $skipped already present, $failed unavailable" -Level Success
}

function Restore-EnvironmentVariables {
    Write-Log "=== ENVIRONMENT VARIABLES ===" -Level Section

    # Remove telemetry opt-out variables (restore to default = telemetry enabled)
    @("DOTNET_CLI_TELEMETRY_OPTOUT","POWERSHELL_TELEMETRY_OPTOUT") | ForEach-Object {
        $val = [System.Environment]::GetEnvironmentVariable($_, "User")
        if ($null -ne $val) {
            if (Invoke-RestoreEnvironmentVariable -Name $_ -Scope User -Remove -Silent) { Write-Log "Removed user env var: $_" -Level Success }
        }
        $val = [System.Environment]::GetEnvironmentVariable($_, "Machine")
        if ($null -ne $val) {
            if (Invoke-RestoreEnvironmentVariable -Name $_ -Scope Machine -Remove -Silent) { Write-Log "Removed machine env var: $_" -Level Success }
        }
    }

    Write-Log "Environment Variables: Complete" -Level Success
}

function Restore-BackgroundApps {
    Write-Log "=== BACKGROUND APPS ===" -Level Section
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" -Name "GlobalUserDisabled" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" -Name "Migrated" -Silent
    Remove-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "BackgroundAppGlobalToggle" -Silent
    # Group Policy
    Remove-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsRunInBackground" -Silent
    Write-Log "Background Apps: Complete" -Level Success
}

function Get-RestoreFunctionMap {
    return @{
        chkPrivacy={Restore-PrivacyTelemetry}; chkCopilot={Restore-CopilotCortanaAI}
        chkBing={Restore-BingSearchWidgets}; chkCDM={Restore-ContentDeliveryManager}
        chkSync={Restore-SyncSettings}; chkInsider={Restore-WindowsInsiderSettings}
        chkBgApps={Restore-BackgroundApps}; chkEnvVars={Restore-EnvironmentVariables}
        chkNotifications={Restore-NotificationSettings}; chkOOBE={Restore-OOBESettings}
        chkTaskbar={Restore-TaskbarUI}; chkExplorer={Restore-ExplorerSettings}
        chkStartMenu={Restore-StartMenuSettings}; chkTheme={Restore-ThemeSettings}
        chkContextMenus={Restore-ContextMenus}; chkMisc={Restore-MiscPolicies}
        chkClipboard={Restore-ClipboardSettings}
        chkWindowsUpdate={Restore-WindowsUpdateSettings}; chkErrorReport={Restore-ErrorReporting}
        chkEdge={Restore-EdgeSettings}; chkChrome={Restore-ChromeSettings}
        chkOffice={Restore-OfficeSettings}; chkNvidia={Restore-NvidiaTelemetry}
        chk3rdParty={Restore-ThirdPartyServices}
        chkDefender={Restore-DefenderSettings}; chkSmartScreen={Restore-SmartScreenSettings}
        chkDefenderCpuCap={Restore-DefenderCpuCap}
        chkFirewall={Restore-FirewallSettings}; chkUAC={Restore-UACSettings}
        chkSecurityUI={Restore-WindowsSecurityUI}
        chkBiometrics={Restore-BiometricsSettings}; chkGaming={Restore-GamingSettings}
        chkOneDrive={Restore-OneDriveSettings}; chkRemoteDesktop={Restore-RemoteDesktopSettings}
        chkNetwork={Restore-NetworkSettings}; chkBluetooth={Restore-BluetoothSettings}
        chkAccessibility={Restore-AccessibilitySettings}; chkInput={Restore-InputSettings}
        chkPrinting={Restore-PrintingSettings}; chkPower={Restore-PowerSettings}
        chkMemory={Restore-MemoryPerformance}; chkStorage={Restore-StorageSettings}
        chkServices={Restore-Services}; chkTasks={Restore-ScheduledTasks}
        chkHostsFile={Restore-HostsFile}; chkCrypto={Restore-CryptoProtocols}
        chkFeatures={Restore-WindowsFeatures}; chkAppx={Restore-AppxPackages}
        chkDevicePrivacy={Restore-DevicePrivacySlider}; chkSearchIndexer={Restore-SearchIndexer -Rebuild}
        chkStoreChain={Restore-StoreWingetServiceChain}; chkAccount={Restore-AccountSignIn}
        chkGroupPolicy={Restore-LocalGroupPolicyDefault}
    }
}

function ConvertTo-RestoreArchitecture {
    param([object]$Value)
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    if ($text -match '^(AMD64|x64|64-bit)$') { return "x64" }
    if ($text -match '^(x86|i386|32-bit)$') { return "x86" }
    if ($text -match '^(ARM64|aarch64)$') { return "arm64" }
    return $text.ToLowerInvariant()
}

function Get-RestoreMachineProfile {
    [CmdletBinding()]
    param(
        [scriptblock]$OperatingSystemProvider,
        [object]$ManagementState
    )

    $validationIssues = New-Object System.Collections.Generic.List[string]
    $os = $null
    if ($OperatingSystemProvider) {
        try { $os = & $OperatingSystemProvider } catch { $validationIssues.Add("Operating system provider failed: $($_.Exception.Message)") }
    } else {
        $currentVersionPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
        try {
            $version = Get-ItemProperty -LiteralPath $currentVersionPath -ErrorAction Stop
            $cim = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $os = [pscustomobject][ordered]@{
                ProductName=$version.ProductName; ProductFamily=$null; EditionID=$version.EditionID
                DisplayVersion=$version.DisplayVersion; ReleaseId=$version.ReleaseId
                CurrentBuild=$version.CurrentBuild; CurrentBuildNumber=$version.CurrentBuildNumber
                UBR=$version.UBR; Architecture=$cim.OSArchitecture; Locale=$cim.MUILanguages | Select-Object -First 1
                IsWindows=$true; IsOnline=$true
            }
        } catch {
            $validationIssues.Add("Windows version inventory failed: $($_.Exception.Message)")
        }
    }

    if (-not $os) { $os = [pscustomobject]@{} }
    $productName = if ($os.PSObject.Properties['ProductName']) { [string]$os.ProductName } else { $null }
    $productFamily = if ($os.PSObject.Properties['ProductFamily'] -and $os.ProductFamily) { [string]$os.ProductFamily } else {
        if ($productName -match 'Windows\s+11') { "Windows 11" }
        elseif ($productName -match 'Windows\s+10') { "Windows 10" }
        else { $null }
    }
    $edition = $null
    foreach ($editionProperty in @('Edition','EditionID','InstallationType')) {
        if ($os.PSObject.Properties[$editionProperty] -and -not [string]::IsNullOrWhiteSpace([string]$os.$editionProperty)) {
            $edition = [string]$os.$editionProperty
            break
        }
    }
    $build = $null
    foreach ($buildProperty in @('Build','CurrentBuild','CurrentBuildNumber')) {
        if ($os.PSObject.Properties[$buildProperty] -and $null -ne $os.$buildProperty) {
            $candidate = 0
            if ([int]::TryParse(([string]$os.$buildProperty), [ref]$candidate)) { $build = $candidate; break }
        }
    }
    $revision = 0
    if ($os.PSObject.Properties['UBR']) { [int]::TryParse(([string]$os.UBR), [ref]$revision) | Out-Null }
    $architecture = $null
    foreach ($architectureProperty in @('Architecture','OSArchitecture')) {
        if ($os.PSObject.Properties[$architectureProperty] -and $os.$architectureProperty) {
            $architecture = ConvertTo-RestoreArchitecture $os.$architectureProperty
            break
        }
    }
    $locale = if ($os.PSObject.Properties['Locale'] -and $os.Locale) { [string]$os.Locale } else {
        try { (Get-Culture).Name } catch { $null }
    }
    $operatingSystemIsWindows = if ($os.PSObject.Properties['IsWindows']) { [bool]$os.IsWindows } else { $true }
    $isOnline = if ($os.PSObject.Properties['IsOnline']) { [bool]$os.IsOnline } else { $true }
    $powershellMajor = if ($os.PSObject.Properties['PowerShellMajor']) { [int]$os.PowerShellMajor } else { [int]$PSVersionTable.PSVersion.Major }
    $isWindowsPowerShell = if ($os.PSObject.Properties['IsWindowsPowerShell']) { [bool]$os.IsWindowsPowerShell } else { $PSVersionTable.PSEdition -eq "Desktop" }
    $isAdministrator = if ($os.PSObject.Properties['IsAdministrator']) { [bool]$os.IsAdministrator } else {
        try {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal($identity)
            [bool]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch { $false }
    }

    if (-not $productFamily) { $validationIssues.Add("Windows product family is unknown") }
    if ($null -eq $build) { $validationIssues.Add("Windows build is unknown") }
    if ([string]::IsNullOrWhiteSpace($edition)) { $validationIssues.Add("Windows edition is unknown") }
    if ([string]::IsNullOrWhiteSpace($architecture)) { $validationIssues.Add("OS architecture is unknown") }
    if ([string]::IsNullOrWhiteSpace($locale)) { $validationIssues.Add("OS locale is unknown") }
    if (-not $operatingSystemIsWindows) { $validationIssues.Add("The current operating system is not Windows") }

    $management = if ($ManagementState) { $ManagementState } else { Get-PolicyManagementState }
    $managementKnown = if ($management.PSObject.Properties['IsKnown']) { [bool]$management.IsKnown } else {
        $null -ne $management.IsManaged
    }
    if (-not $managementKnown) { $validationIssues.Add("Management ownership could not be determined") }

    $status = "Ready"
    if (-not $operatingSystemIsWindows -or ($productFamily -and $productFamily -notin @("Windows 10", "Windows 11"))) { $status = "Unsupported" }
    elseif ($validationIssues.Count -gt 0) { $status = "Unknown" }

    return [pscustomobject][ordered]@{
        SchemaVersion=$script:CapabilitySchemaVersion
        CapturedAtUtc=(Get-Date).ToUniversalTime().ToString("o")
        Status=$status; ValidationIssues=@($validationIssues)
        ProductName=$productName; ProductFamily=$productFamily; Edition=$edition
        DisplayVersion=if ($os.PSObject.Properties['DisplayVersion']) { [string]$os.DisplayVersion } else { $null }
        ReleaseId=if ($os.PSObject.Properties['ReleaseId']) { [string]$os.ReleaseId } else { $null }
        Build=$build; BuildRevision=$revision
        Architecture=$architecture; Locale=$locale
        IsWindows=$operatingSystemIsWindows; IsOnline=$isOnline
        PowerShellMajor=$powershellMajor; IsWindowsPowerShell=$isWindowsPowerShell
        IsAdministrator=$isAdministrator; Management=$management
    }
}

function Get-RestoreCapabilityCatalog {
    [CmdletBinding()]
    param([hashtable]$FunctionMap)
    if (-not $FunctionMap) { $FunctionMap = Get-RestoreFunctionMap }
    $managedPolicyKeys = @(
        "chkDefender","chkFirewall","chkSmartScreen","chkWindowsUpdate","chkUAC","chkSecurityUI",
        "chkCrypto","chkNetwork","chkHostsFile","chkServices","chkTasks","chkFeatures",
        "chkPrivacy","chkCopilot","chkEdge","chkOneDrive","chkSync","chkGroupPolicy",
        "chkAppx","chkStoreChain","chkAccount"
    )
    $userScopedKeys = @("chkPrivacy","chkSync","chkNotifications","chkBgApps","chkEnvVars","chkDevicePrivacy","chkTaskbar","chkExplorer","chkStartMenu","chkTheme","chkClipboard","chkOneDrive","chkAccount")
    $highRiskKeys = @("chkDefender","chkFirewall","chkWindowsUpdate","chkUAC","chkSecurityUI","chkCrypto","chkFeatures","chkAppx","chkGroupPolicy","chkHostsFile")
    $catalog = [ordered]@{}
    foreach ($key in @($FunctionMap.Keys | Sort-Object)) {
        $managed = $key -in $managedPolicyKeys
        $catalog[$key] = [pscustomobject][ordered]@{
            CapabilityId=$key; CategoryKey=$key
            SupportedProductFamilies=@("Windows 10","Windows 11")
            SupportedEditions=@("All")
            SupportedArchitectures=@("x86","x64","arm64")
            MinimumBuildByFamily=@{"Windows 10"=10240; "Windows 11"=22000}
            RequiresPowerShellMajor=5; RequiresWindowsPowerShell=$true
            RequiresAdministrator=$true; RequiresOnline=$true
            ManagedPolicyAction=if ($managed) { "Skip" } else { "Allow" }
            PolicyOwnership=if ($managed) { "Organization" } else { "LocalDefault" }
            Scope=if ($key -in $userScopedKeys) { "CurrentUser" } else { "MachineAndUser" }
            Risk=if ($key -in $highRiskKeys) { "High" } else { "Medium" }
        }
    }
    return $catalog
}

function Get-RestoreCapabilityEvaluation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string[]]$SelectedKeys,
        [object]$MachineProfile,
        [switch]$AllowManagedPolicy
    )
    if (-not $MachineProfile) { $MachineProfile = Get-RestoreMachineProfile }
    $catalog = Get-RestoreCapabilityCatalog
    $evaluations = @()
    foreach ($key in @($SelectedKeys | Select-Object -Unique)) {
        $reasons = New-Object System.Collections.Generic.List[string]
        $definition = $catalog[$key]
        $status = "Supported"
        if (-not $definition) {
            $status = "Unsupported"
            $reasons.Add("Restore category is not declared in the capability catalog")
        } elseif ($MachineProfile.Status -eq "Unsupported") {
            $status = "Unsupported"
            foreach ($profileIssue in @($MachineProfile.ValidationIssues)) { $reasons.Add([string]$profileIssue) }
        } elseif ($MachineProfile.Status -ne "Ready") {
            $status = "Unknown"
            foreach ($profileIssue in @($MachineProfile.ValidationIssues)) { $reasons.Add([string]$profileIssue) }
        }
        if ($definition -and $status -eq "Supported") {
            if ($MachineProfile.ProductFamily -notin @($definition.SupportedProductFamilies)) {
                $status = "Unsupported"; $reasons.Add("OS product family '$($MachineProfile.ProductFamily)' is not supported")
            }
            $minimumBuild = $definition.MinimumBuildByFamily[$MachineProfile.ProductFamily]
            if ($null -eq $MachineProfile.Build -or $MachineProfile.Build -lt $minimumBuild) {
                $status = if ($null -eq $MachineProfile.Build) { "Unknown" } else { "Unsupported" }
                $buildReason = if ($null -eq $MachineProfile.Build) { "OS build is unknown" } else { "OS build $($MachineProfile.Build) is below the supported minimum $minimumBuild" }
                $reasons.Add($buildReason)
            }
            if ($MachineProfile.Edition -notin @($definition.SupportedEditions) -and "All" -notin @($definition.SupportedEditions)) {
                $status = "Unsupported"; $reasons.Add("OS edition '$($MachineProfile.Edition)' is not supported")
            }
            if ($MachineProfile.Architecture -notin @($definition.SupportedArchitectures)) {
                $status = if ($MachineProfile.Architecture) { "Unsupported" } else { "Unknown" }
                $architectureReason = if ($MachineProfile.Architecture) { "Architecture '$($MachineProfile.Architecture)' is not supported" } else { "OS architecture is unknown" }
                $reasons.Add($architectureReason)
            }
            if ($definition.RequiresPowerShellMajor -and $MachineProfile.PowerShellMajor -lt $definition.RequiresPowerShellMajor) {
                $status = "Unsupported"; $reasons.Add("PowerShell $($definition.RequiresPowerShellMajor)+ is required")
            }
            if ($definition.RequiresWindowsPowerShell -and -not $MachineProfile.IsWindowsPowerShell) {
                $status = "Unsupported"; $reasons.Add("Windows PowerShell 5.1 is required")
            }
            if ($definition.RequiresAdministrator -and -not $MachineProfile.IsAdministrator) {
                $status = "Unsupported"; $reasons.Add("Administrator privileges are required")
            }
            if ($definition.RequiresOnline -and -not $MachineProfile.IsOnline) {
                $status = "Unsupported"; $reasons.Add("Online Windows state is required")
            }
            if ($MachineProfile.Management -and $MachineProfile.Management.PSObject.Properties['IsKnown'] -and -not $MachineProfile.Management.IsKnown) {
                $status = "Unknown"; $reasons.Add("Management ownership could not be determined")
            } elseif ($MachineProfile.Management -and $MachineProfile.Management.IsManaged -and $definition.ManagedPolicyAction -eq "Skip") {
                if ($AllowManagedPolicy) { $reasons.Add("Managed policy override explicitly requested") }
                else { $status = "OrganizationOwned"; $reasons.Add("Organization-owned policy state is preserved by default") }
            }
        }
        $evaluations += [pscustomobject][ordered]@{
            Key=$key; CapabilityId=if($definition){$definition.CapabilityId}else{$key}
            Status=$status; CanMutate=($status -eq "Supported")
            Reason=($reasons -join "; "); Reasons=@($reasons)
            Scope=if($definition){$definition.Scope}else{"Unknown"}
            Risk=if($definition){$definition.Risk}else{"Unknown"}
            PolicyOwnership=if($definition){$definition.PolicyOwnership}else{"Unknown"}
            Definition=$definition; Profile=$MachineProfile
        }
    }
    return @($evaluations)
}

function Get-RestoreCapabilityReport {
    [CmdletBinding()]
    param(
        [string[]]$SelectedKeys,
        [object]$MachineProfile,
        [switch]$AllowManagedPolicy
    )
    if (-not $MachineProfile) { $MachineProfile = Get-RestoreMachineProfile }
    $keys = if ($SelectedKeys -and $SelectedKeys.Count -gt 0) { @($SelectedKeys | Select-Object -Unique) } else { @((Get-RestoreFunctionMap).Keys | Sort-Object) }
    $evaluations = @(Get-RestoreCapabilityEvaluation -SelectedKeys $keys -MachineProfile $MachineProfile -AllowManagedPolicy:$AllowManagedPolicy)
    return [pscustomobject][ordered]@{
        SchemaVersion=$script:CapabilitySchemaVersion; ToolVersion=$script:Version
        GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString("o")
        Profile=$MachineProfile; Categories=$evaluations
        SupportedCount=@($evaluations | Where-Object CanMutate).Count
        BlockedCount=@($evaluations | Where-Object { -not $_.CanMutate }).Count
        Status=if (@($evaluations | Where-Object { -not $_.CanMutate }).Count -eq 0) { "Ready" } else { "Blocked" }
    }
}

function Invoke-RestoreSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string[]]$SelectedKeys,
        [switch]$CreateRollbackSnapshot,
        [switch]$AllowManagedPolicy
    )
    $keys = @($SelectedKeys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $map = Get-RestoreFunctionMap
    $machineProfile = Get-RestoreMachineProfile
    $evaluations = @(Get-RestoreCapabilityEvaluation -SelectedKeys $keys -MachineProfile $machineProfile -AllowManagedPolicy:$AllowManagedPolicy)
    $actionPlan = Get-RestoreActionPlan -SelectedKeys $keys -MachineProfile $machineProfile -AllowManagedPolicy:$AllowManagedPolicy
    $script:CapabilityProfile = $machineProfile
    $script:CapabilityEvaluations = $evaluations
    $script:LastActionPlan = $actionPlan
    $results = [ordered]@{}
    foreach ($evaluation in $evaluations | Where-Object { -not $_.CanMutate }) {
        $results[$evaluation.Key] = [pscustomobject][ordered]@{
            Key=$evaluation.Key; Status="Skipped"; Changed=0; Errors=0
            CapabilityStatus=$evaluation.Status; ExecutionMode="CapabilityGate"; ActionPlanStatus="Blocked"; Reason=$evaluation.Reason
        }
        Write-Log "Skipped $($evaluation.Key): $($evaluation.Reason)" -Level Warning
    }
    $runnable = @($evaluations | Where-Object CanMutate)
    $rollbackJournal = $null
    if ($CreateRollbackSnapshot -and $runnable.Count -gt 0) {
        $journalPath = New-RestoreRollbackJournal -ActionPlan $actionPlan -SelectedKeys @($runnable.Key)
        if (-not $journalPath) { throw "Could not prepare the rollback journal; no restore operations were executed" }
        $rollbackJournal = $script:ActiveRollbackJournal
    }
    foreach ($evaluation in $runnable) {
        $key = $evaluation.Key
        $script:CurrentCategory = $key
        $script:CategoryResults[$key] = @{Status="Running"; Changed=0; Errors=0}
        $beforeChanges = $script:ChangesCount
        $categoryPlan = @($actionPlan.Categories | Where-Object { $_.Key -eq $key } | Select-Object -First 1)
        $useActionPlan = $categoryPlan.Count -eq 1 -and $categoryPlan[0].Status -eq "Ready"
        try {
            if ($useActionPlan) {
                $planResult = Invoke-RestoreActionPlan -ActionPlan $actionPlan -CategoryKey $key
                $changed = [int]$planResult.Changed
                $errors = [int]$planResult.Errors
                $executionMode = "ActionPlan"
            } else {
                & $map[$key]
                $changed = [int]$script:CategoryResults[$key].Changed
                $errors = [int]$script:CategoryResults[$key].Errors
                $executionMode = "LegacyReviewRequired"
            }
            $status = if ($errors -gt 0 -and $changed -gt 0) { "Partial" } elseif ($errors -gt 0) { "Error" } elseif ($changed -gt 0) { "Fixed" } else { "Already OK" }
            $script:CategoryResults[$key].Changed = $changed
            $script:CategoryResults[$key].Errors = $errors
            $script:CategoryResults[$key].Status = $status
            $results[$key] = [pscustomobject][ordered]@{Key=$key;Status=$status;Changed=$changed;Errors=$errors;CapabilityStatus=$evaluation.Status;ExecutionMode=$executionMode;ActionPlanStatus=$categoryPlan[0].Status;Reason=$null}
        } catch {
            $script:CategoryResults[$key].Status = "Error"
            $script:CategoryResults[$key].Errors++
            $results[$key] = [pscustomobject][ordered]@{Key=$key;Status="Error";Changed=([int]($script:ChangesCount - $beforeChanges));Errors=1;CapabilityStatus=$evaluation.Status;ExecutionMode=if($useActionPlan){"ActionPlan"}else{"LegacyReviewRequired"};ActionPlanStatus=if($categoryPlan.Count -eq 1){$categoryPlan[0].Status}else{"Unknown"};Reason=$_.Exception.Message}
            Write-Log "Error in $key : $($_.Exception.Message)" -Level Error
        }
    }
    $script:CurrentCategory = ""
    if ($rollbackJournal) {
        $journalState = if (@($results.Values | Where-Object { $_.Errors -gt 0 }).Count -gt 0) { "Failed" } else { "Committed" }
        Update-RestoreRollbackJournal -Journal $rollbackJournal -JournalPath $script:ActiveRollbackJournalPath -State $journalState | Out-Null
    }
    $resultValues = @($results.Values)
    $exitCode = if (@($resultValues | Where-Object Status -eq "Error").Count -gt 0) { 1 } elseif (@($resultValues | Where-Object { $_.Status -eq "Skipped" }).Count -gt 0) { 2 } else { 0 }
    $script:CapabilityExitCode = $exitCode
    return [pscustomobject][ordered]@{
        SchemaVersion=$script:CapabilitySchemaVersion; ToolVersion=$script:Version
        Profile=$machineProfile; ActionPlanHash=$actionPlan.PlanHash; ActionPlanStatus=$actionPlan.Status
        Categories=$resultValues; ExitCode=$exitCode
        RollbackPath=if($rollbackJournal){$script:ActiveRollbackJournalPath}else{$null}
        RollbackJournalState=if($rollbackJournal){$rollbackJournal.State}else{$null}
        Status=if ($exitCode -eq 0) { "Completed" } elseif ($exitCode -eq 2) { "CapabilityBlocked" } else { "Failed" }
    }
}

function Get-RestoreRegistryPlanState {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Name)
    $keyExists = Test-Path -LiteralPath $Path
    $missing = [pscustomobject][ordered]@{ Exists=$false; KeyExists=$keyExists; Path=$Path; Name=$Name; Type=$null; Value=$null }
    try {
        if (-not $keyExists) { return $missing }
        $properties = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        if (-not $properties.PSObject.Properties[$Name]) { return $missing }
        $value = $properties.$Name
        $valueType = if ($value -is [byte[]]) { "Binary" }
            elseif ($value -is [string[]]) { "MultiString" }
            elseif ($value -is [long] -or $value -is [int64]) { "QWord" }
            elseif ($value -is [int] -or $value -is [int32] -or $value -is [bool]) { "DWord" }
            else { "String" }
        return [pscustomobject][ordered]@{ Exists=$true; KeyExists=$true; Path=$Path; Name=$Name; Type=$valueType; Value=$value }
    } catch {
        return [pscustomobject][ordered]@{ Exists=$null; KeyExists=$keyExists; Path=$Path; Name=$Name; Type=$null; Value=$null; ReadError=$_.Exception.Message }
    }
}

function Export-RestoreActionPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object]$ActionPlan,[Parameter(Mandatory=$true)][string]$OutputPath)
    $fullPath = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $fullPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($fullPath, ($ActionPlan | ConvertTo-Json -Depth 30), [System.Text.Encoding]::UTF8)
    return $fullPath
}

function Test-RestoreActionPlanPrecondition {
    param([Parameter(Mandatory=$true)][object]$Operation)
    try {
        switch ($Operation.Kind) {
            "RegistryValue" {
                $current = Get-RestoreRegistryPlanState -Path $Operation.Before.Path -Name $Operation.Before.Name
                if (($current.Exists -eq $true) -ne ($Operation.Before.Exists -eq $true)) { return [pscustomobject]@{Matches=$false;Reason="Registry value existence changed"} }
                if ($current.Exists -eq $true) {
                    $currentValue = $current.Value | ConvertTo-Json -Depth 12 -Compress
                    $plannedValue = $Operation.Before.Value | ConvertTo-Json -Depth 12 -Compress
                    if ($current.Type -ne $Operation.Before.Type -or $currentValue -ne $plannedValue) { return [pscustomobject]@{Matches=$false;Reason="Registry value changed"} }
                }
            }
            "RegistryKey" {
                $currentExists = Test-Path -LiteralPath $Operation.Before.Path
                if ([bool]$currentExists -ne [bool]$Operation.Before.Exists) { return [pscustomobject]@{Matches=$false;Reason="Registry key existence changed"} }
            }
            "File" {
                $current = Get-RestoreFilePlanState -Path $Operation.Before.Path
                if ([bool]$current.Exists -ne [bool]$Operation.Before.Exists) { return [pscustomobject]@{Matches=$false;Reason="File source existence changed"} }
                if ($current.Exists -and $Operation.Before.Sha256 -and $current.Sha256 -ne $Operation.Before.Sha256) { return [pscustomobject]@{Matches=$false;Reason="File source hash changed"} }
            }
            "Service" {
                $serviceState = Get-RestoreServicePlanState -ServiceName ($Operation.Target -replace '^Service:', '')
                if ([bool]$serviceState.Exists -ne [bool]$Operation.Before.Exists) { return [pscustomobject]@{Matches=$false;Reason="Service existence changed"} }
                if ($serviceState.Exists -and $Operation.Before.StartType -and $serviceState.StartType -ne [string]$Operation.Before.StartType) { return [pscustomobject]@{Matches=$false;Reason="Service startup type changed"} }
                if ($serviceState.Exists -and $Operation.Before.PathName -and $serviceState.PathName -ne [string]$Operation.Before.PathName) { return [pscustomobject]@{Matches=$false;Reason="Service executable configuration changed"} }
            }
            "ServiceControl" {
                $serviceState = Get-RestoreServicePlanState -ServiceName ($Operation.Target -replace '^Service:', '')
                if ([bool]$serviceState.Exists -ne [bool]$Operation.Before.Exists) { return [pscustomobject]@{Matches=$false;Reason="Service existence changed"} }
                if ($serviceState.Exists -and $Operation.Before.Status -and $serviceState.Status -ne [string]$Operation.Before.Status) { return [pscustomobject]@{Matches=$false;Reason="Service running state changed"} }
            }
            "ScheduledTask" {
                $taskTarget = $Operation.Target -replace '^Task:', ''
                $separator = $taskTarget.LastIndexOf('\')
                if ($separator -ge 0) {
                    $taskState = Get-RestoreScheduledTaskPlanState -TaskPath $taskTarget.Substring(0, $separator + 1) -TaskName $taskTarget.Substring($separator + 1)
                    if ([bool]$taskState.Exists -ne [bool]$Operation.Before.Exists) { return [pscustomobject]@{Matches=$false;Reason="Scheduled task existence changed"} }
                    if ($taskState.Exists -and $Operation.Before.State -and $taskState.State -ne [string]$Operation.Before.State) { return [pscustomobject]@{Matches=$false;Reason="Scheduled task state changed"} }
                    if ($taskState.Exists -and $Operation.Before.XmlSha256 -and $taskState.XmlSha256 -ne [string]$Operation.Before.XmlSha256) { return [pscustomobject]@{Matches=$false;Reason="Scheduled task XML changed"} }
                }
            }
            "EnvironmentVariable" {
                $separator = $Operation.Target.IndexOf(':')
                if ($separator -gt 0) {
                    $scope = $Operation.Target.Substring(0, $separator); $name = $Operation.Target.Substring($separator + 1)
                    $currentValue = [System.Environment]::GetEnvironmentVariable($name, $scope)
                    if ($currentValue -ne $Operation.Before.Value) { return [pscustomobject]@{Matches=$false;Reason="Environment variable changed"} }
                }
            }
            "AppX" {
                if ($Operation.Before.PackageName) {
                    $scope = if($Operation.Before.Scope){[string]$Operation.Before.Scope}else{if($Operation.After.Scope){[string]$Operation.After.Scope}else{"CurrentUser"}}
                    $appxState = Get-RestoreAppxPlanState -PackageName $Operation.Before.PackageName -Scope $scope
                    if ($appxState.Installed -ne [bool]$Operation.Before.Installed) { return [pscustomobject]@{Matches=$false;Reason="AppX package presence changed"} }
                }
            }
            "OptionalFeature" {
                $feature = Get-WindowsOptionalFeature -FeatureName $Operation.Target -Online -ErrorAction SilentlyContinue
                $state = if($feature){[string]$feature.State}else{"Missing"}
                if ($state -ne [string]$Operation.Before.State) { return [pscustomobject]@{Matches=$false;Reason="Optional feature state changed"} }
            }
            "NativeCommand" {
                if (-not (Get-Command -Name $Operation.Metadata.FilePath -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $Operation.Metadata.FilePath)) { return [pscustomobject]@{Matches=$false;Reason="Native command is unavailable"} }
            }
        }
        return [pscustomobject]@{Matches=$true;Reason=$null}
    } catch {
        return [pscustomobject]@{Matches=$false;Reason="Could not verify precondition: $($_.Exception.Message)"}
    }
}

function Get-RestoreStaticActionOperation {
    param([Parameter(Mandatory=$true)][string]$CategoryKey,[Parameter(Mandatory=$true)][scriptblock]$FunctionScript)
    $functionMatch = [regex]::Match($FunctionScript.ToString(), 'Restore-[A-Za-z0-9]+')
    if (-not $functionMatch.Success) { return @() }
    $functionCommand = Get-Command -Name $functionMatch.Value -CommandType Function -ErrorAction SilentlyContinue
    if (-not $functionCommand) { return @() }
    $parseTokens = $null; $parseErrors = $null
    $functionAst = [System.Management.Automation.Language.Parser]::ParseInput($functionCommand.Definition, [ref]$parseTokens, [ref]$parseErrors)
    $commandAsts = @($functionAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    $operations = New-Object System.Collections.Generic.List[object]
    foreach ($commandAst in $commandAsts) {
        $commandName = [string]$commandAst.CommandElements[0].Value
        if ($commandName -notin @("Remove-RegistryValue","Set-RegistryValue","Remove-RegistryKey","Restore-ServiceStartup","Enable-ScheduledTaskSafe")) { continue }
        $arguments = @{}
        for ($elementIndex = 1; $elementIndex -lt $commandAst.CommandElements.Count; $elementIndex++) {
            $element = $commandAst.CommandElements[$elementIndex]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if ($elementIndex + 1 -ge $commandAst.CommandElements.Count) { continue }
            $valueAst = $commandAst.CommandElements[$elementIndex + 1]
            $value = $null; $hasValue = $false
            if ($valueAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $value = [string]$valueAst.Value; $hasValue = $true
            } elseif ($valueAst -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                $value = $valueAst.Value; $hasValue = $true
            } elseif ($valueAst -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $valueAst.NestedExpressions.Count -eq 0) {
                $value = [string]$valueAst.Value; $hasValue = $true
            }
            if ($hasValue) { $arguments[$element.ParameterName] = $value }
        }
        $target = $null; $scope = "MachineAndUser"; $action = $null; $before = $null; $after = $null; $rollback = "Restore captured before state"
        if ($commandName -eq "Remove-RegistryValue" -and $arguments.ContainsKey("Path") -and $arguments.ContainsKey("Name")) {
            $target = "{0}\{1}" -f $arguments.Path,$arguments.Name; $action = "Remove"; $before = Get-RestoreRegistryPlanState -Path $arguments.Path -Name $arguments.Name; $after = [pscustomobject]@{Exists=$false;Path=$arguments.Path;Name=$arguments.Name;Type=$null;Value=$null}; $scope = if ($arguments.Path -like "HKCU:*") { "CurrentUser" } else { "Machine" }
        } elseif ($commandName -eq "Set-RegistryValue" -and $arguments.ContainsKey("Path") -and $arguments.ContainsKey("Name") -and $arguments.ContainsKey("Value")) {
            $target = "{0}\{1}" -f $arguments.Path,$arguments.Name; $action = "Set"; $before = Get-RestoreRegistryPlanState -Path $arguments.Path -Name $arguments.Name; $after = [pscustomobject]@{Exists=$true;Path=$arguments.Path;Name=$arguments.Name;Type=$arguments.Type;Value=$arguments.Value}; $scope = if ($arguments.Path -like "HKCU:*") { "CurrentUser" } else { "Machine" }
        } elseif ($commandName -eq "Remove-RegistryKey" -and $arguments.ContainsKey("Path")) {
            $target = $arguments.Path; $action = "Remove"; $exists = Test-Path -LiteralPath $arguments.Path; $before = [pscustomobject]@{Exists=$exists;Path=$arguments.Path}; $after = [pscustomobject]@{Exists=$false;Path=$arguments.Path}; $scope = if ($arguments.Path -like "HKCU:*") { "CurrentUser" } else { "Machine" }; $rollback = "Restore captured key state"
        } elseif ($commandName -eq "Restore-ServiceStartup" -and $arguments.ContainsKey("ServiceName") -and $arguments.ContainsKey("StartupType")) {
            $target = "Service:$($arguments.ServiceName)"; $action = "SetStartupType"; $service = Get-Service -Name $arguments.ServiceName -ErrorAction SilentlyContinue; $before = [pscustomobject]@{Exists=($null -ne $service);StartType=if($service){$service.StartType.ToString()}else{$null}}; $after = [pscustomobject]@{Exists=$true;StartType=[string]$arguments.StartupType}; $scope = "Machine"; $rollback = "Restore captured service startup type"
        } elseif ($commandName -eq "Enable-ScheduledTaskSafe" -and $arguments.ContainsKey("TaskPath") -and $arguments.ContainsKey("TaskName")) {
            $target = "Task:{0}{1}" -f $arguments.TaskPath,$arguments.TaskName; $action = "Enable"; $task = Get-ScheduledTask -TaskPath $arguments.TaskPath -TaskName $arguments.TaskName -ErrorAction SilentlyContinue; $before = [pscustomobject]@{Exists=($null -ne $task);State=if($task){$task.State.ToString()}else{$null}}; $after = [pscustomobject]@{Exists=$true;State="Enabled"}; $scope = "Machine"; $rollback = "Restore captured task state"
        }
        if ($target) {
            $operations.Add([pscustomobject][ordered]@{
                CategoryKey=$CategoryKey; Kind=if($commandName -in @("Remove-RegistryValue","Set-RegistryValue")){"RegistryValue"}elseif($commandName -eq "Remove-RegistryKey"){"RegistryKey"}elseif($commandName -like "*Service*"){"Service"}else{"ScheduledTask"}
                Action=$action; Target=$target; Scope=$scope; Before=$before; After=$after
                RollbackAction=$rollback; Exact=$true; CanExecute=$true; Reason=$null; Source="Restore function AST"
            })
        }
    }
    return @($operations.ToArray())
}

function Invoke-RestoreCategoryPlanCapture {
    param([Parameter(Mandatory=$true)][string]$CategoryKey,[Parameter(Mandatory=$true)][scriptblock]$FunctionScript)
    $previousCapture = $script:ActionPlanCapture
    $previousWhatIf = $script:WhatIfRequested
    $previousCategory = $script:CurrentCategory
    $previousOperations = $script:CapturedActionOperations
    $previousChanges = $script:ChangesCount
    $script:ActionPlanCapture = $true
    $script:WhatIfRequested = $false
    $script:CurrentCategory = $CategoryKey
    $script:CapturedActionOperations = New-Object System.Collections.Generic.List[object]
    $captureError = $null
    try {
        $null = & $FunctionScript
    } catch {
        $captureError = $_.Exception.Message
    }
    $operations = @($script:CapturedActionOperations.ToArray())
    $unexpectedChanges = [int]($script:ChangesCount - $previousChanges)
    $script:ActionPlanCapture = $previousCapture
    $script:WhatIfRequested = $previousWhatIf
    $script:CurrentCategory = $previousCategory
    $script:CapturedActionOperations = $previousOperations
    $script:ChangesCount = $previousChanges
    return [pscustomobject][ordered]@{Operations=$operations;Error=$captureError;UnexpectedChanges=$unexpectedChanges}
}

function Get-RestoreActionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string[]]$SelectedKeys,
        [object]$HealthReport,
        [object]$MachineProfile,
        [switch]$AllowManagedPolicy,
        [switch]$CreateRestorePoint
    )
    $keys = @($SelectedKeys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if (-not $MachineProfile) { $MachineProfile = Get-RestoreMachineProfile }
    $evaluations = @(Get-RestoreCapabilityEvaluation -SelectedKeys $keys -MachineProfile $MachineProfile -AllowManagedPolicy:$AllowManagedPolicy)
    $operations = New-Object System.Collections.Generic.List[object]
    $categoryPlans = New-Object System.Collections.Generic.List[object]
    $functionMap = Get-RestoreFunctionMap
    $operationNumber = 0
    foreach ($evaluation in $evaluations) {
        $categoryExact = 0
        $categoryOpaque = 0
        if (-not $evaluation.CanMutate) {
            $operationNumber++
            $operations.Add([pscustomobject][ordered]@{
                OperationId=("op-{0:D4}" -f $operationNumber); CategoryKey=$evaluation.Key; Kind="CapabilityGate"
                Action="Skip"; Target=$evaluation.Key; Scope=$evaluation.Scope; Risk=$evaluation.Risk
                Before=$null; After=$null; RollbackAction="None"; Exact=$true; CanExecute=$false
                Reason=$evaluation.Reason; Source="Capability catalog"; Dependency="Capability:$($evaluation.Key)"
                Verification="Capability evaluation remains supported"; Metadata=$null
            })
            $categoryExact++
        } else {
            $capture = if ($functionMap.ContainsKey($evaluation.Key)) {
                Invoke-RestoreCategoryPlanCapture -CategoryKey $evaluation.Key -FunctionScript $functionMap[$evaluation.Key]
            } else {
                [pscustomobject]@{Operations=@();Error="Restore category has no executable function";UnexpectedChanges=0}
            }
            foreach ($capturedOperation in @($capture.Operations)) {
                $operationNumber++
                $operations.Add([pscustomobject][ordered]@{
                    OperationId=("op-{0:D4}" -f $operationNumber); CategoryKey=$evaluation.Key; Kind=$capturedOperation.Kind
                    Action=$capturedOperation.Action; Target=$capturedOperation.Target; Scope=$capturedOperation.Scope; Risk=if($capturedOperation.Risk){$capturedOperation.Risk}else{$evaluation.Risk}
                    Before=$capturedOperation.Before; After=$capturedOperation.After; RollbackAction=$capturedOperation.RollbackAction
                    Exact=$true; CanExecute=$capturedOperation.CanExecute; Reason=$capturedOperation.Reason
                    Source=if($capturedOperation.Source){$capturedOperation.Source}else{"Category mutation primitive"}
                    Dependency=if($capturedOperation.Dependency){$capturedOperation.Dependency}else{"Capability:$($evaluation.Key)"}
                    Verification=if($capturedOperation.Verification){$capturedOperation.Verification}else{"Fresh post-run verification required"}
                    Metadata=$capturedOperation.Metadata
                })
                $categoryExact++
            }
            if ($capture.Error -or $capture.UnexpectedChanges -gt 0) {
                $operationNumber++
                $opaqueReason = if($capture.Error){"Category plan capture failed: $($capture.Error)"}else{"Category performed an unwrapped state change during plan capture"}
                $operations.Add([pscustomobject][ordered]@{
                    OperationId=("op-{0:D4}" -f $operationNumber); CategoryKey=$evaluation.Key; Kind="PlanCaptureError"
                    Action="Review category executor"; Target=$evaluation.Key; Scope=$evaluation.Scope; Risk=$evaluation.Risk
                    Before=$null; After=$null; RollbackAction="Do not execute until the category is fully represented"
                    Exact=$false; CanExecute=$false; Reason=$opaqueReason; Source="Mutation primitive audit"
                    Dependency="Capability:$($evaluation.Key)"; Verification="Plan capture completes without unwrapped mutations"; Metadata=$null
                })
                $categoryOpaque++
            }
        }
        $categoryPlans.Add([pscustomobject][ordered]@{
            Key=$evaluation.Key; CapabilityStatus=$evaluation.Status; CanMutate=$evaluation.CanMutate
            ExactOperationCount=$categoryExact; OpaqueOperationCount=$categoryOpaque
            Status=if (-not $evaluation.CanMutate) { "Blocked" } elseif ($categoryOpaque -gt 0) { "ReviewRequired" } else { "Ready" }
        })
    }
    if ($CreateRestorePoint) {
        $operationNumber++
        $operations.Add([pscustomobject][ordered]@{
            OperationId=("op-{0:D4}" -f $operationNumber); CategoryKey="__run"; Kind="RestorePoint"
            Action="Create"; Target="SystemRestore:$env:SystemDrive\"; Scope="Machine"; Risk="High"
            Before=[pscustomobject]@{Drive="$env:SystemDrive\";LatestRestorePoint=$null}
            After=[pscustomobject]@{Drive="$env:SystemDrive\";Description="Before Restore-WindowsDefaults plan";Created=$true}
            RollbackAction="Use the created Windows System Restore point"; Exact=$true; CanExecute=$true; Reason=$null
            Source="System restore point adapter"; Dependency="Capability:SystemRestore"
            Verification="A restore point with the planned description exists"; Metadata=[pscustomobject]@{Description="Before Restore-WindowsDefaults plan";Drive="$env:SystemDrive\"}
        })
    }
    $operationArray = @($operations.ToArray())
    $opaqueCount = @($operationArray | Where-Object { -not $_.Exact }).Count
    $blockedCount = @($evaluations | Where-Object { -not $_.CanMutate }).Count
    $planStatus = if ($blockedCount -gt 0) { "Blocked" } elseif ($opaqueCount -gt 0) { "ReviewRequired" } else { "Ready" }
    $hashInput = $operationArray | ConvertTo-Json -Depth 30 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($hashInput))
        $planHash = ([BitConverter]::ToString($hashBytes) -replace "-", "").ToLowerInvariant()
    } finally { $sha.Dispose() }
    $plan = [pscustomobject][ordered]@{
        SchemaVersion=$script:ActionPlanSchemaVersion; ToolVersion=$script:Version
        GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString("o"); PlanHash=$planHash
        Status=$planStatus; ExecutionAllowed=($planStatus -eq "Ready")
        Profile=$MachineProfile; Categories=@($categoryPlans.ToArray()); Operations=$operationArray
        ExactOperationCount=@($operationArray | Where-Object Exact).Count; OpaqueOperationCount=$opaqueCount
        CapabilityBlockedCount=$blockedCount; HealthReportAvailable=($null -ne $HealthReport)
    }
    $script:LastActionPlan = $plan
    return $plan
}

function Invoke-RestoreActionPlanOperation {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][object]$Operation)
    if (-not $Operation.CanExecute -or $Operation.Action -eq "NoOp") { return $false }
    $precondition = Test-RestoreActionPlanPrecondition -Operation $Operation
    if (-not $precondition.Matches) { throw "Plan precondition failed for $($Operation.OperationId): $($precondition.Reason)" }
    if (-not $PSCmdlet.ShouldProcess($Operation.Target, $Operation.Action)) { return $false }
    switch ($Operation.Kind) {
        "RegistryValue" {
            if ($Operation.Action -eq "Remove") {
                return (Remove-RegistryValue -Path $Operation.Before.Path -Name $Operation.Before.Name -Silent)
            }
            if ($Operation.Action -eq "Set") {
                return (Set-RegistryValue -Path $Operation.After.Path -Name $Operation.After.Name -Value $Operation.After.Value -Type $Operation.After.Type -Silent)
            }
        }
        "RegistryKey" {
            if ($Operation.Action -eq "Remove") { return (Remove-RegistryKey -Path $Operation.Before.Path -Silent) }
            if ($Operation.Action -eq "Ensure") { return (New-RestoreRegistryKey -Path $Operation.After.Path -Silent) }
        }
        "Service" {
            if ($Operation.Action -eq "SetStartupType") {
                return (Restore-ServiceStartup -ServiceName ($Operation.Target -replace '^Service:', '') -StartupType $Operation.After.StartType -Silent)
            }
        }
        "ServiceControl" {
            if ($Operation.Action -in @("Start","Stop")) {
                return (Invoke-RestoreServiceControl -Action $Operation.Action -ServiceName ($Operation.Target -replace '^Service:', '') -Silent)
            }
        }
        "ScheduledTask" {
            if ($Operation.Action -in @("Enable","Disable")) {
                $taskTarget = $Operation.Target -replace '^Task:', ''
                $separator = $taskTarget.LastIndexOf('\')
                if ($separator -ge 0) {
                    return (Invoke-RestoreScheduledTaskState -Action $Operation.Action -TaskPath ($taskTarget.Substring(0, $separator + 1)) -TaskName $taskTarget.Substring($separator + 1) -Silent)
                }
            }
        }
        "File" {
            $metadata = $Operation.Metadata
            if ($Operation.Action -in @("Remove","Rename","Move","Copy")) {
                $destination = if ($Operation.Action -eq "Rename") { Split-Path -Leaf $Operation.After.Path } else { $Operation.After.Path }
                return (Invoke-RestoreFileMutation -Action $Operation.Action -Path $Operation.Before.Path -Destination $destination -Silent)
            }
            if ($Operation.Action -eq "Write" -and $metadata -and $metadata.Content) {
                return (Invoke-RestoreTextFileMutation -Path $Operation.After.Path -Content $metadata.Content -Scope $Operation.Scope -Silent)
            }
        }
        "NativeCommand" {
            if ($Operation.Metadata) {
                $nativeResult = Invoke-RestoreNativeCommand -FilePath $Operation.Metadata.FilePath -ArgumentList @($Operation.Metadata.ArgumentList) -ExpectedExitCodes @($Operation.Metadata.ExpectedExitCodes) -RequiresReboot:([bool]$Operation.Metadata.RequiresReboot) -Scope $Operation.Scope -Silent
                if ($nativeResult.PSObject.Properties["Success"]) { return [bool]$nativeResult.Success }
            }
        }
        "AppX" {
            if ($Operation.Metadata) {
                $appxResult = Invoke-RestoreAppxRegistration -PackageName $Operation.Metadata.PackageName -ManifestPath $Operation.Metadata.ManifestPath -PackageFamilyName $Operation.Metadata.PackageFamilyName -Scope $Operation.Metadata.Scope -Silent
                if ($appxResult.PSObject.Properties["Success"]) { return [bool]$appxResult.Success }
            }
        }
        "OptionalFeature" {
            return (Invoke-RestoreOptionalFeature -FeatureName $Operation.Target -Silent)
        }
        "EnvironmentVariable" {
            $separator = $Operation.Target.IndexOf(':')
            if ($separator -gt 0) {
                $scope = $Operation.Target.Substring(0, $separator)
                $name = $Operation.Target.Substring($separator + 1)
                $remove = $null -eq $Operation.After.Value
                return (Invoke-RestoreEnvironmentVariable -Name $name -Scope $scope -Value $Operation.After.Value -Remove:$remove -Silent)
            }
        }
        "RestorePoint" {
            if ($Operation.Metadata) {
                $restorePoint = Invoke-RestoreSystemRestorePoint -Description $Operation.Metadata.Description -Drive $Operation.Metadata.Drive -Silent
                if ($restorePoint.PSObject.Properties["Success"]) { return [bool]$restorePoint.Success }
            }
        }
    }
    return $false
}

function Invoke-RestoreActionPlan {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][object]$ActionPlan,[string]$CategoryKey)
    $allOperations = @($ActionPlan.Operations)
    $operations = @($allOperations | Where-Object {
        $_.CanExecute -and ([string]::IsNullOrWhiteSpace($CategoryKey) -or $_.CategoryKey -eq $CategoryKey) -and
        (-not $_.PSObject.Properties["JournalStatus"] -or $_.JournalStatus -notin @("Completed","VerifiedNoChange","RolledBack","RollbackUnsupported","RollbackConflict"))
    })
    $changed = 0
    $errors = 0
    $operationIndex = 0
    foreach ($operation in $operations) {
        $script:CurrentCategory = if ($CategoryKey) { $CategoryKey } else { $operation.CategoryKey }
        $beforeChanges = $script:ChangesCount
        $journalOperation = @()
        if ($script:ActiveRollbackJournal) { $journalOperation = @($script:ActiveRollbackJournal.Operations | Where-Object { [string]$_.OperationId -eq [string]$operation.OperationId } | Select-Object -First 1) }
        if ($journalOperation.Count -eq 1) {
            Update-RestoreRollbackJournal -Journal $script:ActiveRollbackJournal -JournalPath $script:ActiveRollbackJournalPath -State "Executing" -OperationId $operation.OperationId -OperationStatus "Running" -NextOperationIndex $operationIndex | Out-Null
        }
        try {
            $null = Invoke-RestoreActionPlanOperation -Operation $operation
            $operationChanged = [int]($script:ChangesCount - $beforeChanges) -gt 0
            if ($journalOperation.Count -eq 1) {
                $journalStatus = if ($operationChanged) { "Completed" } else { "VerifiedNoChange" }
                Update-RestoreRollbackJournal -Journal $script:ActiveRollbackJournal -JournalPath $script:ActiveRollbackJournalPath -OperationId $operation.OperationId -OperationStatus $journalStatus -Changed:$operationChanged -ErrorMessage $null -NextOperationIndex ($operationIndex + 1) | Out-Null
            }
        } catch {
            $errors++
            Write-Log "Plan operation $($operation.OperationId) failed: $($_.Exception.Message)" -Level Error
            if ($journalOperation.Count -eq 1) {
                Update-RestoreRollbackJournal -Journal $script:ActiveRollbackJournal -JournalPath $script:ActiveRollbackJournalPath -State "Failed" -OperationId $operation.OperationId -OperationStatus "Failed" -Changed:([int]($script:ChangesCount - $beforeChanges) -gt 0) -ErrorMessage $_.Exception.Message -NextOperationIndex ($operationIndex + 1) | Out-Null
            }
        }
        $changed += [int]($script:ChangesCount - $beforeChanges)
        $operationIndex++
    }
    if ($CategoryKey) { $script:CurrentCategory = "" }
    return [pscustomobject][ordered]@{CategoryKey=$CategoryKey; OperationCount=$operations.Count; Changed=$changed; Errors=$errors; Status=if($errors -gt 0 -and $changed -gt 0){"Partial"}elseif($errors -gt 0){"Error"}elseif($changed -gt 0){"Changed"}else{"Already OK"}}
}


# ============================================================================
# PRE-SCAN DIAGNOSTICS ENGINE (with detailed per-item findings)
# ============================================================================

function Get-SystemHealthReport {
    $report = [ordered]@{}
    $baselineContext = Get-RestoreBaselineContext
    $script:BaselineCatalogContext = $baselineContext
    $addCat = {
        param($name, $fn, $issues, $details, $sev, $keys)
        if (!$details -or $details.Count -eq 0) { $details = $issues }
        $report[$name] = @{
            FriendlyName=$fn; Issues=[array]$issues; Details=[array]$details
            Severity=$sev; IssueCount=([array]$issues).Count; FixKeys=$keys
        }
    }

    # --- Debloat tool fingerprints and source-attributed service/task evidence ---
    $detectedTools = @(Get-DebloatToolFingerprintReport -MachineProfile $baselineContext.MachineProfile)
    $toolDetails = @()
    $toolFixKeys = @()
    foreach ($tool in $detectedTools) {
        $toolDetails += "$($tool.Tool) detected ($($tool.Confidence) confidence)"
        if ($tool.CatalogVersion) { $toolDetails += "  Catalog $($tool.CatalogVersion); source $($tool.SourceUrl); scope $($tool.SupportedBuildRange); catalog confidence $($tool.CatalogConfidence)" }
        $toolDetails += @($tool.Evidence | ForEach-Object { "  $_" })
        if ($tool.CanAutoFix) { $toolFixKeys += @($tool.FixKeys) }
        elseif ($tool.Warning) { $toolDetails += "  Catalog warning: $($tool.Warning)" }
    }
    $fingerprintFindings = @()
    if ($detectedTools.Count -gt 0) {
        $fingerprintFindings = @(Get-ServiceTaskFingerprintReport -MachineProfile $baselineContext.MachineProfile)
        foreach ($finding in $fingerprintFindings) {
            $stateText = if ($finding.Kind -eq "Service") { "service $($finding.Name)" } else { "task $($finding.Path)$($finding.Name)" }
            $toolDetails += "$($finding.Tool): $stateText is $($finding.State)"
            if ($finding.CanAutoFix) {
                if ($finding.Kind -eq "Service") { $toolFixKeys += "chkServices" } else { $toolFixKeys += "chkTasks" }
            } elseif ($finding.Warning) { $toolDetails += "  Catalog warning: $($finding.Warning)" }
        }
    }
    $toolFixKeys = @($toolFixKeys | Select-Object -Unique)
    $toolIssues = @()
    if ($detectedTools.Count -gt 0) { $toolIssues += "$($detectedTools.Count) debloat tool footprint(s) detected" }
    if ($fingerprintFindings.Count -gt 0) { $toolIssues += "$($fingerprintFindings.Count) attributed service/task change(s)" }
    $toolSeverity = if ($fingerprintFindings.Count -gt 0) { "Medium" } elseif ($detectedTools.Count -gt 0) { "Low" } else { "OK" }
    & $addCat "DebloatTools" "Debloat Tool Footprints" $toolIssues $toolDetails $toolSeverity $toolFixKeys
    $script:ToolFingerprintReport = $detectedTools
    $script:TaskRestoreMatrixReport = @(Get-ScheduledTaskRestoreMatrix -MachineProfile $baselineContext.MachineProfile)

    # --- Windows Defender ---
    $issues = @(); $details = @()
    $defPol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
    if ((Get-ItemProperty $defPol -Name "DisableAntiSpyware" -EA 0).DisableAntiSpyware -eq 1) {
        $issues += "Antivirus disabled by policy"; $details += "Policy: DisableAntiSpyware = 1"
    }
    if ((Get-ItemProperty "$defPol\Real-Time Protection" -Name "DisableRealtimeMonitoring" -EA 0).DisableRealtimeMonitoring -eq 1) {
        $issues += "Real-time protection off"; $details += "Policy: DisableRealtimeMonitoring = 1"
    }
    $svc = Get-Service "WinDefend" -EA 0
    if ($svc -and $svc.StartType -eq 'Disabled') { $issues += "Defender service disabled"; $details += "Service: WinDefend (Windows Defender) = Disabled" }
    if ((Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\MsMpEng.exe" -Name "Debugger" -EA 0).Debugger) {
        $issues += "Defender blocked by IFEO debugger"; $details += "IFEO: MsMpEng.exe has Debugger redirect"
    }
    $renamedExes = @(Get-ChildItem "$env:ProgramFiles\Windows Defender" -Filter "*.exe.OLD" -EA 0)
    if ($renamedExes.Count) { $issues += "$($renamedExes.Count) Defender EXEs renamed"; $details += ($renamedExes | ForEach-Object { "Renamed: $($_.Name)" }) }
    & $addCat "Defender" "Windows Defender" $issues $details $(if($issues.Count){"Critical"}else{"OK"}) @("chkDefender")

    # --- Firewall ---
    $issues = @(); $details = @()
    $svc = Get-Service "MpsSvc" -EA 0
    if ($svc -and $svc.StartType -eq 'Disabled') { $issues += "Firewall service disabled"; $details += "Service: MpsSvc (Windows Firewall) = Disabled" }
    @("DomainProfile","PublicProfile","StandardProfile") | ForEach-Object {
        $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\$_" -Name "EnableFirewall" -EA 0).EnableFirewall
        if ($v -eq 0) { $issues += "$_ firewall off"; $details += "Firewall: $_ EnableFirewall = 0" }
    }
    & $addCat "Firewall" "Windows Firewall" $issues $details $(if($issues.Count){"Critical"}else{"OK"}) @("chkFirewall")

    # --- SmartScreen ---
    $issues = @(); $details = @()
    if ((Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableSmartScreen" -EA 0).EnableSmartScreen -eq 0) {
        $issues += "SmartScreen disabled by policy"; $details += "Policy: EnableSmartScreen = 0"
    }
    if ((Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\smartscreen.exe" -Name "Debugger" -EA 0).Debugger) {
        $issues += "SmartScreen executable blocked"; $details += "IFEO: smartscreen.exe has Debugger redirect"
    }
    & $addCat "SmartScreen" "SmartScreen" $issues $details $(if($issues.Count){"Critical"}else{"OK"}) @("chkSmartScreen")

    # --- Security UI ---
    $issues = @(); $details = @()
    $secUIPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center"
    @("Virus and threat protection","Firewall and network protection","App and browser control","Device security","Device performance and health","Family options","Account protection") | ForEach-Object {
        if ((Get-ItemProperty "$secUIPath\$_" -Name "UILockdown" -EA 0).UILockdown -eq 1) {
            $issues += "$_ hidden"; $details += "Section hidden: $_"
        }
    }
    if (!(Get-AppxPackageSafe -Name "Microsoft.SecHealthUI") -and !(Get-AppxPackageSafe -Name "Microsoft.Windows.SecHealthUI")) {
        $issues += "Windows Security app removed"; $details += "AppX: SecHealthUI package missing"
    }
    & $addCat "SecurityUI" "Windows Security App" $issues $details $(if($issues.Count){"High"}else{"OK"}) @("chkSecurityUI")

    # --- Windows Update ---
    $issues = @(); $details = @()
    $wuSvcs = [ordered]@{ "wuauserv"="Windows Update"; "DoSvc"="Delivery Optimization"; "WaaSMedicSvc"="Update Health"; "UsoSvc"="Update Orchestrator"; "BITS"="Background Transfer" }
    foreach ($s in $wuSvcs.GetEnumerator()) {
        $svc = Get-Service $s.Key -EA 0
        if ($svc -and $svc.StartType -eq 'Disabled') { $issues += "$($s.Value) disabled"; $details += "Service: $($s.Key) ($($s.Value)) = Disabled" }
    }
    if ((Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -EA 0).NoAutoUpdate -eq 1) {
        $issues += "Auto-update blocked by policy"; $details += "Policy: NoAutoUpdate = 1"
    }
    & $addCat "WindowsUpdate" "Windows Update" $issues $details $(if($issues.Count){"High"}else{"OK"}) @("chkWindowsUpdate")

    # --- UAC ---
    $issues = @(); $details = @()
    $lua = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -EA 0).EnableLUA
    if ($lua -eq 0) { $issues += "UAC completely disabled"; $details += "Policy: EnableLUA = 0 (no admin prompts)" }
    & $addCat "UAC" "User Account Control" $issues $details $(if($issues.Count){"High"}else{"OK"}) @("chkUAC")

    # --- Network ---
    $issues = @(); $details = @()
    $svc = Get-Service "NlaSvc" -EA 0
    if ($svc -and $svc.StartType -eq 'Disabled') { $issues += "Network detection disabled"; $details += "Service: NlaSvc (Network Location Awareness) = Disabled" }
    if ((Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator" -Name "NoActiveProbe" -EA 0).NoActiveProbe -eq 1) {
        $issues += "Internet connectivity test disabled"; $details += "Policy: NCSI NoActiveProbe = 1"
    }
    $dnsSvc = Get-Service "Dnscache" -EA 0
    if ($dnsSvc -and $dnsSvc.StartType -eq 'Disabled') { $issues += "DNS Client disabled"; $details += "Service: Dnscache (DNS Client) = Disabled" }
    & $addCat "Network" "Network Connectivity" $issues $details $(if($issues.Count){"High"}else{"OK"}) @("chkNetwork")

    # --- Hosts File ---
    $issues = @(); $details = @()
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    if (Test-Path $hostsPath) {
        $hContent = [System.IO.File]::ReadAllLines($hostsPath)
        $blocked = @($hContent | Where-Object { $_ -match "^0\.0\.0\.0\s" -or $_ -match "^::1?\s" })
        if ($blocked.Count -gt 5) {
            $issues += "$($blocked.Count) domains blocked in hosts file"
            $details += ($blocked | Select-Object -First 15 | ForEach-Object { "Blocked: $($_ -replace '^\S+\s+','')" })
            if ($blocked.Count -gt 15) { $details += "... and $($blocked.Count - 15) more" }
        }
    }
    & $addCat "HostsFile" "Hosts File" $issues $details $(if($issues.Count){"Medium"}else{"OK"}) @("chkHostsFile")

    # --- Services (comprehensive) ---
    $issues = @(); $details = @()
    $criticalSvcs = [ordered]@{
        "Spooler"="Print Spooler"; "Audiosrv"="Windows Audio"; "AudioEndpointBuilder"="Audio Endpoint Builder"
        "Themes"="Themes"; "EventLog"="Event Log"; "bthserv"="Bluetooth Support"
        "WSearch"="Windows Search"; "SysMain"="SysMain (Superfetch)"; "TabletInputService"="Touch Keyboard"
        "lfsvc"="Geolocation"; "WbioSrvc"="Windows Biometric"; "XblAuthManager"="Xbox Live Auth"
        "WpnService"="Push Notifications"; "TrkWks"="Distributed Link Tracking"
        "TokenBroker"="Web Account Manager"; "LanmanWorkstation"="Workstation"
        "Dnscache"="DNS Client"; "DPS"="Diagnostic Policy"; "PcaSvc"="Program Compatibility"
        "WerSvc"="Windows Error Reporting"; "seclogon"="Secondary Logon"; "Schedule"="Task Scheduler"
        "DiagTrack"="Connected User Experiences"; "dmwappushservice"="WAP Push Service"
    }
    foreach ($s in $criticalSvcs.GetEnumerator()) {
        $svc = Get-Service $s.Key -EA 0
        if ($svc -and $svc.StartType -eq 'Disabled') { $details += "$($s.Value) ($($s.Key))" }
    }
    if ($details.Count -gt 5) { $issues += "$($details.Count) system services disabled" }
    elseif ($details.Count -gt 0) { $issues += "$($details.Count) service(s) disabled" }
    & $addCat "Services" "System Services" $issues $details $(if($details.Count -gt 5){"High"}elseif($details.Count){"Medium"}else{"OK"}) @("chkServices","chk3rdParty")

    # --- Privacy/Telemetry ---
    $issues = @(); $details = @()
    $svc = Get-Service "DiagTrack" -EA 0
    if ($svc -and $svc.StartType -eq 'Disabled') { $details += "Service: DiagTrack (Diagnostics) = Disabled" }
    $tel = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -EA 0).AllowTelemetry
    if ($null -ne $tel -and $tel -eq 0) { $details += "Policy: AllowTelemetry = 0 (telemetry fully blocked)" }
    if (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy") {
        $privPols = @((Get-Item "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -EA 0).Property)
        if ($privPols.Count -gt 0) { $details += "AppPrivacy: $($privPols.Count) policies forcing app permissions" }
    }
    $bg = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" -Name "GlobalUserDisabled" -EA 0).GlobalUserDisabled
    if ($bg -eq 1) { $details += "Background apps globally disabled" }
    $camPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore"
    @("microphone","webcam","location","contacts","appointments","phoneCall","radios","bluetooth","broadFileSystemAccess") | ForEach-Object {
        $v = (Get-ItemProperty "$camPath\$_" -Name "Value" -EA 0).Value
        if ($v -eq "Deny") { $details += "Capability blocked: $_" }
    }
    if ($details.Count -gt 3) { $issues += "$($details.Count) privacy restrictions detected" }
    elseif ($details.Count -gt 0) { $issues += "$($details.Count) privacy change(s)" }
    & $addCat "Privacy" "Privacy and Diagnostics" $issues $details $(if($details.Count -gt 3){"Medium"}elseif($details.Count){"Low"}else{"OK"}) @("chkPrivacy","chkBgApps","chkEnvVars","chkDevicePrivacy")

    # --- Device privacy sliders ---
    $issues = @(); $details = @()
    $capBase = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore"
    foreach ($capability in @("webcam","microphone","bluetooth","location","radios")) {
        $value = (Get-ItemProperty "$capBase\$capability" -Name "Value" -EA 0).Value
        if ($value -eq "Deny") { $issues += "$capability blocked"; $details += "CapabilityAccessManager: $capability = Deny" }
        $policyName = "LetAppsAccess$capability"
        $policyObject = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name $policyName -EA 0
        $policy = $policyObject.$policyName
        if ($null -ne $policy) { $details += "Policy override: LetAppsAccess$capability = $policy" }
    }
    & $addCat "DevicePrivacy" "Device Privacy Sliders" $issues $details $(if($issues.Count){"Medium"}else{"OK"}) @("chkDevicePrivacy")

    # --- Store/Apps ---
    $issues = @(); $details = @()
    $appCatalog = @($script:CoreAppxPackageCatalog | Where-Object { $_.Role -eq "Core" })
    $appReport = Get-AppxPackageRemovalReport -ExpectedPackages $appCatalog -MachineProfile $baselineContext.MachineProfile
    $script:AppxRemovalReport = $appReport
    if ($appReport.Findings.Count) { $details += "Baseline catalog $($appReport.CatalogVersion); source $script:BaselineAppxSourceUrl; confidence $($appReport.Confidence)" }
    foreach ($missingName in @($appReport.Missing)) {
        $friendly = ($appCatalog | Where-Object { $_.Name -eq $missingName } | Select-Object -First 1).Name
        $issues += "$friendly removed"; $details += "Missing from current user and provisioned image: $missingName"
    }
    foreach ($provisionedName in @($appReport.ProvisionedOnly)) {
        $details += "Provisioned but not registered for current user: $provisionedName"
    }
    foreach ($catalogWarning in @($appReport.Warnings)) {
        $details += "Baseline catalog warning: $catalogWarning"
    }
    & $addCat "StoreApps" "Windows Apps" $issues $details $(if($issues.Count){"Medium"}else{"OK"}) @("chkAppx")

    # --- Crypto ---
    $issues = @(); $details = @()
    $schBase = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols"
    @("TLS 1.2","TLS 1.3") | ForEach-Object {
        if ((Get-ItemProperty "$schBase\$_\Client" -Name "Enabled" -EA 0).Enabled -eq 0) {
            $issues += "$_ client disabled"; $details += "Protocol: $_ Client Enabled = 0"
        }
    }
    @("SSL 2.0","SSL 3.0","TLS 1.0","TLS 1.1") | ForEach-Object {
        if (Test-Path "$schBase\$_\Client") { $details += "Protocol override exists: $_ Client" }
        if (Test-Path "$schBase\$_\Server") { $details += "Protocol override exists: $_ Server" }
    }
    if ($details.Count -gt 0 -and $issues.Count -eq 0) { $issues += "$($details.Count) protocol overrides detected" }
    & $addCat "Crypto" "Security Protocols" $issues $details $(if($issues | Where-Object {$_ -match "disabled"}){"High"}elseif($issues.Count){"Low"}else{"OK"}) @("chkCrypto")

    # --- Browsers ---
    $issues = @(); $details = @()
    $edgeState = Get-EdgePolicyState
    if ($edgeState.HasPolicies) {
        $issues += "Edge: $($edgeState.MachinePolicies.Count + $edgeState.UserPolicies.Count) policies"
        $details += "Edge policy source: $($edgeState.Source)"
        $details += @($edgeState.MachinePolicies | Select-Object -First 10 | ForEach-Object { "Machine Edge policy: $_" })
        $details += @($edgeState.UserPolicies | Select-Object -First 10 | ForEach-Object { "User Edge policy: $_" })
    }
    if (Test-Path "HKLM:\SOFTWARE\Policies\Google\Chrome") {
        $cp = @((Get-Item "HKLM:\SOFTWARE\Policies\Google\Chrome" -EA 0).Property)
        if ($cp.Count -gt 2) { $issues += "Chrome: $($cp.Count) policies"; $details += ($cp | Select-Object -First 10 | ForEach-Object { "Chrome policy: $_" }) }
    }
    if (Test-Path "HKLM:\SOFTWARE\Policies\Mozilla\Firefox") { $issues += "Firefox has policies"; $details += "Firefox group policies detected" }
    & $addCat "Browsers" "Browser Settings" $issues $details $(if($issues.Count){"Low"}else{"OK"}) @("chkEdge","chkChrome")

    # --- Search indexer ---
    $issues = @(); $details = @()
    $searchService = Get-Service -Name "WSearch" -EA 0
    if ($searchService -and $searchService.StartType -eq "Disabled") {
        $issues += "Windows Search service disabled"; $details += "Service: WSearch = Disabled"
    }
    & $addCat "Search" "Search Indexer" $issues $details $(if($issues.Count){"Medium"}else{"OK"}) @("chkSearchIndexer")

    # --- Account sign-in ---
    $issues = @(); $details = @()
    $accountState = Get-AccountSignInState
    foreach ($serviceName in @("wlidsvc","TokenBroker","NgcSvc","NgcCtnrSvc")) {
        $signInService = Get-Service -Name $serviceName -EA 0
        if ($signInService -and $signInService.StartType -eq "Disabled") {
            $issues += "$serviceName disabled"; $details += "Service: $serviceName = Disabled"
        }
    }
    $details += "Sign-in context: $($accountState.AccountKind)"
    & $addCat "AccountSignIn" "Account Sign-in" $issues $details $(if($issues.Count){"Medium"}else{"OK"}) @("chkAccount")

    # --- Taskbar/Explorer/UI ---
    $issues = @(); $details = @()
    $exp = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    if ((Get-ItemProperty $exp -Name "TaskbarDa" -EA 0).TaskbarDa -eq 0) { $details += "Taskbar: Widgets hidden" }
    if ((Get-ItemProperty $exp -Name "ShowTaskViewButton" -EA 0).ShowTaskViewButton -eq 0) { $details += "Taskbar: Task View hidden" }
    if ((Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "SearchboxTaskbarMode" -EA 0).SearchboxTaskbarMode -eq 0) { $details += "Taskbar: Search bar hidden" }
    $shellFolders = @(
        @{G="{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}";N="Desktop"},@{G="{d3162b92-9365-467a-956b-92703aca08af}";N="Documents"},
        @{G="{088e3905-0323-4b02-9826-5d99428e115f}";N="Downloads"},@{G="{3dfdf296-dbec-4fb4-81d1-6a3438bcf4de}";N="Music"}
    )
    foreach ($f in $shellFolders) {
        if (!(Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\$($f.G)")) { $details += "Explorer: $($f.N) folder removed from This PC" }
    }
    if ($details.Count -gt 0) { $issues += "$($details.Count) UI customizations detected" }
    & $addCat "UI" "Taskbar and Explorer" $issues $details $(if($details.Count -gt 3){"Medium"}elseif($details.Count){"Low"}else{"OK"}) @("chkTaskbar","chkExplorer","chkStartMenu","chkContextMenus")

    # --- OneDrive ---
    $issues = @(); $details = @()
    if ((Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" -Name "DisableFileSyncNGSC" -EA 0).DisableFileSyncNGSC -eq 1) {
        $issues += "OneDrive sync blocked"; $details += "Policy: DisableFileSyncNGSC = 1"
    }
    & $addCat "OneDrive" "OneDrive" $issues $details $(if($issues.Count){"Low"}else{"OK"}) @("chkOneDrive")

    # --- Scheduled Tasks ---
    $issues = @(); $details = @()
    $taskChecks = @(
        @{P="\Microsoft\Windows\WindowsUpdate\";N="Scheduled Start"},
        @{P="\Microsoft\Windows\Defrag\";N="ScheduledDefrag"},
        @{P="\Microsoft\Windows\DiskDiagnostic\";N="Microsoft-Windows-DiskDiagnosticDataCollector"},
        @{P="\Microsoft\Windows\Diagnosis\";N="Scheduled"},
        @{P="\Microsoft\Windows\Application Experience\";N="Microsoft Compatibility Appraiser"}
    )
    foreach ($tc in $taskChecks) {
        try { $t = Get-ScheduledTask -TaskPath $tc.P -TaskName $tc.N -EA Stop
            if ($t.State -eq 'Disabled') { $details += "Disabled: $($tc.N)" }
        } catch { Write-Verbose "Could not inspect scheduled task $($tc.P)$($tc.N)" }
    }
    if ($details.Count -gt 0) { $issues += "$($details.Count) maintenance tasks disabled" }
    & $addCat "Tasks" "Scheduled Tasks" $issues $details $(if($details.Count -gt 2){"Medium"}elseif($details.Count){"Low"}else{"OK"}) @("chkTasks")

    # --- Windows Features ---
    $issues = @(); $details = @()
    try {
        @("MicrosoftWindowsPowerShellV2Root","Printing-PrintToPDFServices-Features","SearchEngine-Client-Package","MediaPlayback","WindowsMediaPlayer") | ForEach-Object {
            $feat = Get-WindowsOptionalFeature -Online -FeatureName $_ -EA Stop
            if ($feat.State -eq 'Disabled') { $details += "Disabled: $_ ($($feat.DisplayName))" }
        }
    } catch { }
    if ($details.Count -gt 0) { $issues += "$($details.Count) Windows features disabled" }
    & $addCat "Features" "Windows Features" $issues $details $(if($details.Count){"Medium"}else{"OK"}) @("chkFeatures")

    return $report
}

# ============================================================================
# PRE-SCAN QUICK SUMMARY (counts for disabled services, tasks, missing AppX, modified registry)
# ============================================================================

function Get-QuickScanSummary {
    $summary = [ordered]@{
        DisabledServices = 0
        DisabledTasks = 0
        MissingAppx = 0
        ModifiedRegistry = 0
        ServiceNames = @()
        TaskNames = @()
        AppxNames = @()
        RegistryDetails = @()
    }

    # Count disabled services that should be running
    $defaultSvcs = @(
        "WinDefend","MpsSvc","BFE","wuauserv","UsoSvc","DoSvc","BITS","CryptSvc",
        "Spooler","Audiosrv","AudioEndpointBuilder","NlaSvc","Dnscache","Themes",
        "EventLog","Schedule","WpnService","DiagTrack","bthserv","WSearch","SysMain",
        "PcaSvc","wersvc","wscsvc","WlanSvc","Dhcp","TrkWks","Power","ProfSvc","Winmgmt"
    )
    foreach ($sn in $defaultSvcs) {
        $svc = Get-Service -Name $sn -EA 0
        if ($svc -and $svc.StartType -eq 'Disabled') {
            $summary.DisabledServices++
            $summary.ServiceNames += $sn
        }
    }

    # Count disabled scheduled tasks
    $taskChecks = @(
        @{P="\Microsoft\Windows\WindowsUpdate\";N="Scheduled Start"},
        @{P="\Microsoft\Windows\Windows Defender\";N="Windows Defender Scheduled Scan"},
        @{P="\Microsoft\Windows\Defrag\";N="ScheduledDefrag"},
        @{P="\Microsoft\Windows\DiskDiagnostic\";N="Microsoft-Windows-DiskDiagnosticDataCollector"},
        @{P="\Microsoft\Windows\Diagnosis\";N="Scheduled"},
        @{P="\Microsoft\Windows\Application Experience\";N="Microsoft Compatibility Appraiser"},
        @{P="\Microsoft\Windows\UpdateOrchestrator\";N="Schedule Scan"},
        @{P="\Microsoft\Windows\Servicing\";N="StartComponentCleanup"},
        @{P="\Microsoft\Windows\Customer Experience Improvement Program\";N="Consolidator"}
    )
    foreach ($tc in $taskChecks) {
        try {
            $t = Get-ScheduledTask -TaskPath $tc.P -TaskName $tc.N -EA Stop
            if ($t.State -eq 'Disabled') {
                $summary.DisabledTasks++
                $summary.TaskNames += $tc.N
            }
        } catch { }
    }

    # Count missing AppX packages
    $coreAppx = @(
        "Microsoft.WindowsStore","Microsoft.WindowsCalculator","Microsoft.Windows.Photos",
        "Microsoft.DesktopAppInstaller","Microsoft.WindowsCamera","Microsoft.WindowsAlarms",
        "Microsoft.MSPaint","Microsoft.GetHelp","Microsoft.People",
        "Microsoft.MicrosoftOfficeHub","Microsoft.WindowsFeedbackHub"
    )
    foreach ($pkg in $coreAppx) {
        if (!(Get-AppxPackageSafe -Name $pkg)) {
            $summary.MissingAppx++
            $summary.AppxNames += $pkg
        }
    }

    # Count modified registry keys (key policy paths that shouldn't exist on stock Windows)
    $regChecks = @(
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender";N="DisableAntiSpyware"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection";N="DisableRealtimeMonitoring"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU";N="NoAutoUpdate"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";N="EnableSmartScreen"},
        @{P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System";N="EnableLUA"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection";N="AllowTelemetry"},
        @{P="HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications";N="GlobalUserDisabled"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive";N="DisableFileSyncNGSC"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Edge";N="SmartScreenEnabled"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy";N="LetAppsRunInBackground"}
    )
    foreach ($rc in $regChecks) {
        $val = (Get-ItemProperty -Path $rc.P -Name $rc.N -EA 0)
        if ($null -ne $val -and $null -ne $val.$($rc.N)) {
            $summary.ModifiedRegistry++
            $summary.RegistryDetails += "$($rc.P)\$($rc.N)"
        }
    }

    return $summary
}

# ============================================================================
# MANIFEST IMPORT (reads Debloat-Win11 v1.1.0 JSON undo manifests)
# ============================================================================

function Get-RestoreImportProvenance {
    param([string]$SourceType,[string]$SourcePath,[string]$FormatVersion,[long]$SourceBytes,[string]$SourceHash)
    return [pscustomobject][ordered]@{
        SourceType=$SourceType; SourcePath=$SourcePath; FormatVersion=$FormatVersion
        ImportedAtUtc=(Get-Date).ToUniversalTime().ToString("o"); SourceBytes=$SourceBytes; SourceSha256=$SourceHash
        Trust="UntrustedEvidence"; ExecutableContent=$false; ParserSchemaVersion=$script:ExternalImportSchemaVersion
    }
}

function Get-RestoreBoundedTextFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int64]$MaxBytes=$script:ExternalImportMaxBytes,
        [int]$MaxLines=$script:ExternalImportMaxLines,
        [int]$MaxLineBytes=$script:ExternalImportMaxLineBytes
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{Success=$false;Status="Malformed";Reason="File not found";Text=$null;Bytes=0;Hash=$null;LineCount=0}
    }
    try {
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($file.Length -gt $MaxBytes) {
            return [pscustomobject]@{Success=$false;Status="Unsupported";Reason="Input exceeds the $MaxBytes-byte limit";Text=$null;Bytes=$file.Length;Hash=$null;LineCount=0}
        }
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        $text = [System.IO.File]::ReadAllText($file.FullName)
        $lines = @($text -split "`r?`n")
        if ($lines.Count -gt $MaxLines) {
            return [pscustomobject]@{Success=$false;Status="Unsupported";Reason="Input exceeds the $MaxLines-line limit";Text=$null;Bytes=$bytes.Length;Hash=(Get-RestoreSha256 -Bytes $bytes);LineCount=$lines.Count}
        }
        foreach ($line in $lines) {
            if ([Text.Encoding]::UTF8.GetByteCount([string]$line) -gt $MaxLineBytes) {
                return [pscustomobject]@{Success=$false;Status="Unsupported";Reason="A line exceeds the $MaxLineBytes-byte limit";Text=$null;Bytes=$bytes.Length;Hash=(Get-RestoreSha256 -Bytes $bytes);LineCount=$lines.Count}
            }
        }
        return [pscustomobject]@{Success=$true;Status="Verified";Reason=$null;Text=$text;Bytes=$bytes.Length;Hash=(Get-RestoreSha256 -Bytes $bytes);LineCount=$lines.Count}
    } catch {
        return [pscustomobject]@{Success=$false;Status="Malformed";Reason="Could not read input: $($_.Exception.Message)";Text=$null;Bytes=0;Hash=$null;LineCount=0}
    }
}

function Test-RestoreImportObjectLimit {
    param(
        [Parameter(Mandatory=$true)][object]$Value,
        [int]$MaxDepth=$script:ExternalImportMaxDepth,
        [int]$MaxItems=$script:ExternalImportMaxItems
    )
    $itemCount = 0
    $deepest = 0
    $limitReason = $null
    $stack = New-Object System.Collections.Generic.List[object]
    $stack.Add([pscustomobject]@{Value=$Value;Depth=0})
    while ($stack.Count -gt 0 -and -not $limitReason) {
        $lastIndex = $stack.Count - 1
        $node = $stack[$lastIndex]
        $stack.RemoveAt($lastIndex)
        $current = $node.Value
        $depth = [int]$node.Depth
        if ($null -eq $current) { continue }
        $itemCount++
        if ($itemCount -gt $MaxItems) { $limitReason = "Input exceeds the $MaxItems-item limit"; break }
        if ($depth -gt $deepest) { $deepest = $depth }
        if ($depth -gt $MaxDepth) { $limitReason = "Input exceeds the maximum nesting depth of $MaxDepth"; break }
        if ($current -is [string] -or $current.GetType().IsPrimitive -or $current -is [datetime] -or $current -is [decimal]) { continue }
        if ($current -is [System.Collections.IEnumerable] -and $current -isnot [System.Collections.IDictionary]) {
            foreach ($child in $current) { $stack.Add([pscustomobject]@{Value=$child;Depth=($depth + 1)}) }
            continue
        }
        foreach ($property in @($current.PSObject.Properties)) {
            $stack.Add([pscustomobject]@{Value=$property.Value;Depth=($depth + 1)})
        }
    }
    return [pscustomobject][ordered]@{Valid=($null -eq $limitReason);Status=if($limitReason){"Unsupported"}else{"Verified"};Reason=$limitReason;ItemCount=$itemCount;MaxDepth=$deepest}
}

function Get-RestoreImportedManifestVersion {
    param([Parameter(Mandatory=$true)][object]$Manifest)
    $property = @($Manifest.PSObject.Properties | Where-Object { $_.Name -in @("version","Version","schemaVersion","SchemaVersion") } | Select-Object -First 1)
    if ($property.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$property[0].Value)) {
        return [pscustomobject]@{Valid=$false;Status="Malformed";Reason="Manifest must declare version or schemaVersion";Raw=$null;Major=$null}
    }
    $raw = [string]$property[0].Value
    $match = [regex]::Match($raw, '^\s*(?<major>\d+)')
    if (-not $match.Success) { return [pscustomobject]@{Valid=$false;Status="Malformed";Reason="Manifest version is not numeric";Raw=$raw;Major=$null} }
    $major = [int]$match.Groups["major"].Value
    if ($major -notin @(1,2)) { return [pscustomobject]@{Valid=$false;Status="Unsupported";Reason="Manifest schema major version $major is not supported";Raw=$raw;Major=$major} }
    return [pscustomobject]@{Valid=$true;Status="Verified";Reason=$null;Raw=$raw;Major=$major}
}

function Test-RestoreImportedRegistryPath {
    param([string]$Path)
    $normalized = ConvertTo-RestoreImportedRegistryPath -Path $Path
    return $normalized -match '^(?i:HKLM|HKCU|HKCR|HKU):\\[^\x00]*$'
}

function ConvertTo-RestoreImportedRegistryPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 512 -or $Path -match '[\r\n*?\[\]]') { return $Path }
    $normalized = ConvertTo-SnapshotRegistryPath -Path $Path
    if ($normalized -match '^(?i:(HKLM|HKCU|HKCR|HKU))\\') {
        $normalized = "$($Matches[1]):$($normalized.Substring(4))"
    }
    return $normalized
}

function Test-RestoreImportedServiceName {
    param([string]$Name)
    return -not [string]::IsNullOrWhiteSpace($Name) -and $Name.Length -le 256 -and $Name -notmatch '[\\/:*?"<>|\r\n]'
}

function Test-RestoreImportedTaskPath {
    param([string]$Path)
    return -not [string]::IsNullOrWhiteSpace($Path) -and $Path.Length -le 512 -and $Path.StartsWith("\") -and $Path -notmatch '[*?\[\]\r\n]'
}

function Test-RestoreManifestEntry {
    param([Parameter(Mandatory=$true)][string]$Kind,[Parameter(Mandatory=$true)][object]$Entry)
    $normalized = $null; $reason = $null; $status = "Verified"
    if ($Entry -is [System.Collections.IEnumerable] -and $Entry -isnot [string]) {
        return [pscustomobject]@{Valid=$false;Status="Malformed";Reason="Entry must be a scalar or object";Normalized=$null}
    }
    switch ($Kind) {
        "AppX" {
            $name = if($Entry -is [string]){[string]$Entry}elseif($Entry.PSObject.Properties["Name"]){[string]$Entry.Name}elseif($Entry.PSObject.Properties["PackageName"]){[string]$Entry.PackageName}else{$null}
            if ([string]::IsNullOrWhiteSpace($name)) { $status="Malformed"; $reason="AppX entry has no package name" }
            elseif ($name.Length -gt 256 -or $name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { $status="Unsupported"; $reason="AppX package name is outside the allowlist" }
            else { $normalized=$name }
        }
        "Service" {
            $name = if($Entry -is [string]){[string]$Entry}elseif($Entry.PSObject.Properties["Name"]){[string]$Entry.Name}elseif($Entry.PSObject.Properties["ServiceName"]){[string]$Entry.ServiceName}else{$null}
            if ([string]::IsNullOrWhiteSpace($name)) { $status="Malformed"; $reason="Service entry has no service name" }
            elseif (-not (Test-RestoreImportedServiceName -Name $name)) { $status="Unsupported"; $reason="Service name contains unsupported characters" }
            else { $normalized=$name }
        }
        "Task" {
            $path = if($Entry -is [string]){[string]$Entry}elseif($Entry.PSObject.Properties["Path"]){[string]$Entry.Path}elseif($Entry.PSObject.Properties["TaskPath"]){[string]$Entry.TaskPath}else{$null}
            $name = if($Entry -is [string]){$null}elseif($Entry.PSObject.Properties["Name"]){[string]$Entry.Name}elseif($Entry.PSObject.Properties["TaskName"]){[string]$Entry.TaskName}else{$null}
            if ([string]::IsNullOrWhiteSpace($path)) { $status="Malformed"; $reason="Scheduled-task entry has no path" }
            elseif (-not (Test-RestoreImportedTaskPath -Path $path)) { $status="Unsupported"; $reason="Scheduled-task path is outside the allowlist" }
            elseif ($name -and ($name.Length -gt 256 -or $name -match '[\\/:*?"<>|\r\n]')) { $status="Unsupported"; $reason="Scheduled-task name contains unsupported characters" }
            else { $normalized=if($name){[pscustomobject][ordered]@{Path=$path;Name=$name}}else{$path} }
        }
        "Registry" {
            $path = if($Entry -is [string]){[string]$Entry}elseif($Entry.PSObject.Properties["Path"]){[string]$Entry.Path}elseif($Entry.PSObject.Properties["path"]){[string]$Entry.path}else{$null}
            $name = if($Entry -is [string]){$null}elseif($Entry.PSObject.Properties["Name"]){[string]$Entry.Name}elseif($Entry.PSObject.Properties["ValueName"]){[string]$Entry.ValueName}else{$null}
            if (-not (Test-RestoreImportedRegistryPath -Path $path)) { $status="Unsupported"; $reason="Registry path is outside the supported hive allowlist" }
            elseif ($name -and ($name.Length -gt 256 -or $name -match '[\r\n]')) { $status="Unsupported"; $reason="Registry value name is invalid" }
            else { $normalized=[pscustomobject][ordered]@{Path=(ConvertTo-RestoreImportedRegistryPath $path);Name=$name} }
        }
        default { $status="Unsupported"; $reason="Imported operation kind '$Kind' is not allowlisted" }
    }
    return [pscustomobject][ordered]@{Valid=($status -eq "Verified");Status=$status;Reason=$reason;Normalized=$normalized}
}

function Add-RestoreManifestCollection {
    param([Parameter(Mandatory=$true)][object]$Result,[Parameter(Mandatory=$true)][string]$Kind,[object[]]$Entries)
    foreach ($entry in @($Entries)) {
        if (@($Result.ImportedEntries).Count -ge $script:ExternalImportMaxItems) {
            $Result.UnsupportedEntries += [pscustomobject]@{Status="Unsupported";Reason="Manifest item limit reached";Kind=$Kind;Index=@($Result.ImportedEntries).Count}
            break
        }
        $validation = Test-RestoreManifestEntry -Kind $Kind -Entry $entry
        $record = [pscustomobject][ordered]@{Status=$validation.Status;Trust="UntrustedEvidence";Kind=$Kind;Index=@($Result.ImportedEntries).Count;Value=$validation.Normalized;Reason=$validation.Reason}
        $Result.ImportedEntries += $record
        if ($validation.Valid) {
            $Result.VerifiedEntries += $record
            $Result.UntrustedEntries += $record
            switch ($Kind) {
                "AppX" { $Result.AppxPackages += $validation.Normalized; $category="chkAppx" }
                "Service" { $Result.Services += $validation.Normalized; $category=Get-RestoreCategoryForImportedChange -Operation ([pscustomobject]@{Kind="Service";Name=$validation.Normalized}) }
                "Task" { $Result.Tasks += $validation.Normalized; $category=Get-RestoreCategoryForImportedChange -Operation ([pscustomobject]@{Kind="Task";Name=if($validation.Normalized -is [string]){$validation.Normalized}else{$validation.Normalized.Name}}) }
                "Registry" { $Result.RegistryKeys += $validation.Normalized; $category=Get-RestoreCategoryForImportedChange -Operation ([pscustomobject]@{Kind="Registry";Path=$validation.Normalized.Path;Name=$validation.Normalized.Name}) }
            }
            if ($category -and $category -notin $Result.RelevantCategories) { $Result.RelevantCategories += $category }
        } elseif ($validation.Status -eq "Malformed") { $Result.MalformedEntries += $record }
        else { $Result.UnsupportedEntries += $record }
    }
}

function Import-UndoManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ManifestPath)
    $fullPath = if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) { [System.IO.Path]::GetFullPath($ManifestPath) } else { $ManifestPath }
    $result = [pscustomobject][ordered]@{
        Success=$false; Status="Rejected"; SchemaVersion=$script:ExternalImportSchemaVersion; SourcePath=$fullPath; SourceBytes=0; SourceHash=$null
        Provenance=$null; AppxPackages=@(); Services=@(); Tasks=@(); RegistryKeys=@(); RelevantCategories=@(); Summary=""
        ManifestData=$null; FormatVersion=$null; ImportedEntries=@(); VerifiedEntries=@(); UnsupportedEntries=@(); MalformedEntries=@(); UntrustedEntries=@()
    }
    $read = Get-RestoreBoundedTextFile -Path $ManifestPath
    $result.SourceBytes = $read.Bytes; $result.SourceHash = $read.Hash
    $result.Provenance = Get-RestoreImportProvenance -SourceType "Debloat-Win11 undo manifest" -SourcePath $fullPath -FormatVersion $null -SourceBytes $read.Bytes -SourceHash $read.Hash
    if (-not $read.Success) {
        $diagnostic = [pscustomobject]@{Status=$read.Status;Reason=$read.Reason}
        if ($read.Status -eq "Unsupported") { $result.UnsupportedEntries += $diagnostic } else { $result.MalformedEntries += $diagnostic }
        $result.Summary = "Manifest rejected: $($read.Reason)"
        return $result
    }
    try { $json = $read.Text | ConvertFrom-Json -ErrorAction Stop } catch { $result.Summary="Manifest rejected: invalid JSON"; $result.MalformedEntries += [pscustomobject]@{Status="Malformed";Reason="Invalid JSON: $($_.Exception.Message)"}; return $result }
    $limits = Test-RestoreImportObjectLimit -Value $json
    if (-not $limits.Valid) {
        $result.Summary="Manifest rejected: $($limits.Reason)"
        $result.UnsupportedEntries += [pscustomobject]@{Status=$limits.Status;Reason=$limits.Reason}
        return $result
    }
    $version = Get-RestoreImportedManifestVersion -Manifest $json
    $result.FormatVersion = $version.Raw
    $result.Provenance = Get-RestoreImportProvenance -SourceType "Debloat-Win11 undo manifest" -SourcePath $fullPath -FormatVersion $version.Raw -SourceBytes $read.Bytes -SourceHash $read.Hash
    if (-not $version.Valid) {
        $result.Summary="Manifest rejected: $($version.Reason)"
        if ($version.Status -eq "Unsupported") { $result.UnsupportedEntries += [pscustomobject]@{Status=$version.Status;Reason=$version.Reason} } else { $result.MalformedEntries += [pscustomobject]@{Status=$version.Status;Reason=$version.Reason} }
        return $result
    }

    $collectionMap = [ordered]@{AppX=New-Object System.Collections.Generic.List[object];Service=New-Object System.Collections.Generic.List[object];Task=New-Object System.Collections.Generic.List[object];Registry=New-Object System.Collections.Generic.List[object]}
    foreach ($property in @($json.PSObject.Properties)) {
        $propertyName = $property.Name.ToLowerInvariant()
        $kind = if($propertyName -in @("appxpackages","appx_packages","removedapps","packages")){"AppX"}elseif($propertyName -in @("services","disabledservices")){"Service"}elseif($propertyName -in @("scheduledtasks","scheduled_tasks","disabledtasks","tasks")){"Task"}elseif($propertyName -in @("registrykeys","registry_keys","registrychanges")){"Registry"}else{$null}
        if ($kind) { foreach ($entry in @($property.Value)) { $collectionMap[$kind].Add($entry) } }
        elseif ($propertyName -notin @("version","schemaversion","formatversion","categories","undo","changes","actions","operations","restoration","description","name","metadata","createdat","source","tool","generator")) {
            $result.UnsupportedEntries += [pscustomobject]@{Status="Unsupported";Reason="Manifest property '$($property.Name)' is not in the import vocabulary";Property=$property.Name}
        }
    }
    foreach ($containerName in @("undo","changes","actions","operations","restoration")) {
        $containerProperty = $json.PSObject.Properties | Where-Object { $_.Name.ToLowerInvariant() -eq $containerName } | Select-Object -First 1
        if (-not $containerProperty) { continue }
        foreach ($item in @($containerProperty.Value)) {
            if ($item -is [string] -or $item -is [ValueType]) { $result.UnsupportedEntries += [pscustomobject]@{Status="Unsupported";Reason="Container item is not an object";Property=$containerName}; continue }
            foreach ($property in @($item.PSObject.Properties)) {
                $propertyName = $property.Name.ToLowerInvariant()
                $kind = if($propertyName -match "appx|removedapps|packages"){"AppX"}elseif($propertyName -match "service"){"Service"}elseif($propertyName -match "task|scheduled"){"Task"}elseif($propertyName -match "registry|reg"){"Registry"}else{$null}
                if ($kind) { foreach ($entry in @($property.Value)) { $collectionMap[$kind].Add($entry) } }
                elseif ($propertyName -notin @("category","categories","description","name")) { $result.UnsupportedEntries += [pscustomobject]@{Status="Unsupported";Reason="Property '$($property.Name)' is not in the import vocabulary";Property=$property.Name} }
            }
        }
    }
    Add-RestoreManifestCollection -Result $result -Kind "AppX" -Entries @($collectionMap.AppX.ToArray())
    Add-RestoreManifestCollection -Result $result -Kind "Service" -Entries @($collectionMap.Service.ToArray())
    Add-RestoreManifestCollection -Result $result -Kind "Task" -Entries @($collectionMap.Task.ToArray())
    Add-RestoreManifestCollection -Result $result -Kind "Registry" -Entries @($collectionMap.Registry.ToArray())

    $catKeyMap = @{"defender"="chkDefender";"firewall"="chkFirewall";"smartscreen"="chkSmartScreen";"update"="chkWindowsUpdate";"privacy"="chkPrivacy";"telemetry"="chkPrivacy";"edge"="chkEdge";"chrome"="chkChrome";"onedrive"="chkOneDrive";"cortana"="chkCopilot";"copilot"="chkCopilot";"network"="chkNetwork";"hosts"="chkHostsFile";"gaming"="chkGaming";"xbox"="chkGaming"}
    $categoryProperty = @($json.PSObject.Properties | Where-Object { $_.Name -ieq "categories" } | Select-Object -First 1)
    $categoryValues = if($categoryProperty.Count -eq 1){@($categoryProperty[0].Value)}else{@()}
    foreach ($category in $categoryValues) {
        $categoryText = if($category -is [string]){[string]$category}elseif($category.PSObject.Properties["name"]){[string]$category.name}else{$null}
        $mapped = @($catKeyMap.Keys | Where-Object { $categoryText -and $categoryText -match $_ } | Select-Object -First 1)
        if ($mapped.Count -eq 1) { $key=$catKeyMap[$mapped[0]]; if($key -notin $result.RelevantCategories){$result.RelevantCategories += $key} }
        elseif ($categoryText) { $result.UnsupportedEntries += [pscustomobject]@{Status="Unsupported";Reason="Category '$categoryText' is not in the supported vocabulary"} }
        else { $result.MalformedEntries += [pscustomobject]@{Status="Malformed";Reason="Category entry has no name"} }
    }
    $result.RelevantCategories = @($result.RelevantCategories | Select-Object -Unique)
    $validCount = @($result.VerifiedEntries).Count
    $diagnosticCount = @($result.UnsupportedEntries).Count + @($result.MalformedEntries).Count
    $parts=@(); if($result.AppxPackages.Count){$parts += "$($result.AppxPackages.Count) AppX"};if($result.Services.Count){$parts += "$($result.Services.Count) services"};if($result.Tasks.Count){$parts += "$($result.Tasks.Count) tasks"};if($result.RegistryKeys.Count){$parts += "$($result.RegistryKeys.Count) registry entries"}
    $result.Success = $validCount -gt 0
    $result.Status = if($validCount -eq 0){"Rejected"}elseif($diagnosticCount -gt 0){"ImportedWithWarnings"}else{"Imported"}
    $warningSuffix = if($diagnosticCount){"; $diagnosticCount unsupported or malformed item(s)"}else{""}
    $result.Summary = if($result.Success){"Manifest imported as untrusted evidence: $($parts -join ', ')$warningSuffix"}else{"Manifest contained no supported entries"}
    return $result
}

function Get-RestoreCategoryForImportedChange {
    param([object]$Operation)
    $text = "$($Operation.Kind) $($Operation.Path) $($Operation.Name)"
    if ($Operation.Kind -eq "Task") { return "chkTasks" }
    if ($Operation.Kind -eq "Service") {
        if ($text -match '(?i)wuauserv|usosvc|bits|dosvc') { return "chkWindowsUpdate" }
        return "chkServices"
    }
    if ($Operation.Kind -eq "AppX") { return "chkAppx" }
    if ($text -match '(?i)edge') { return "chkEdge" }
    if ($text -match '(?i)smartscreen') { return "chkSmartScreen" }
    if ($text -match '(?i)defender|securityhealth|msmpeng') { return "chkDefender" }
    if ($text -match '(?i)firewall|mpssvc|sharedaccess') { return "chkFirewall" }
    if ($text -match '(?i)windows.?update|wuauserv|usosvc|wuas') { return "chkWindowsUpdate" }
    if ($text -match '(?i)chrome|google') { return "chkChrome" }
    if ($text -match '(?i)appx|store|winget|clipsvc|appsvc') { return "chkAppx" }
    if ($text -match '(?i)scheduled.?task|schtasks|task') { return "chkTasks" }
    if ($text -match '(?i)service|sc\.exe|diagtrack|dmwappush') { return "chkServices" }
    if ($text -match '(?i)webcam|camera|microphone|bluetooth|location|appprivacy') { return "chkDevicePrivacy" }
    if ($text -match '(?i)host[s]? file|drivers\\etc\\hosts') { return "chkHostsFile" }
    if ($text -match '(?i)search|wsearch|index') { return "chkSearchIndexer" }
    if ($text -match '(?i)account|tokenbroker|wlidsvc|hello|ngcsvc') { return "chkAccount" }
    if ($text -match '(?i)privacy|telemetry|datacollection|cortana|copilot') { return "chkPrivacy" }
    return "chkMisc"
}

function Test-RestoreExternalChangeOperation {
    param([Parameter(Mandatory=$true)][object]$Operation)
    $allowedKinds = @("Registry","Service","Task","AppX")
    if ($Operation.Kind -notin $allowedKinds) { return [pscustomobject]@{Valid=$false;Status="Unsupported";Reason="Operation kind is not allowlisted"} }
    if ([string]$Operation.Action -notin @("add","delete","config","enable","disable","change","remove","unknown")) { return [pscustomobject]@{Valid=$false;Status="Unsupported";Reason="Operation action is not allowlisted"} }
    switch ($Operation.Kind) {
        "Registry" {
            if (-not (Test-RestoreImportedRegistryPath -Path $Operation.Path)) { return [pscustomobject]@{Valid=$false;Status="Unsupported";Reason="Registry path is outside the supported hive allowlist"} }
            if ($Operation.Name -and ([string]$Operation.Name).Length -gt 256) { return [pscustomobject]@{Valid=$false;Status="Unsupported";Reason="Registry value name is too long"} }
        }
        "Service" {
            if (-not (Test-RestoreImportedServiceName -Name $Operation.Name)) { return [pscustomobject]@{Valid=$false;Status="Unsupported";Reason="Service name is invalid"} }
        }
        "Task" {
            $taskPath = [string]$Operation.Path; $taskName = [string]$Operation.Name
            if (-not $taskPath -and $taskName.StartsWith("\")) { $taskPath=$taskName; $taskName=$null }
            if (-not (Test-RestoreImportedTaskPath -Path $taskPath)) { return [pscustomobject]@{Valid=$false;Status="Unsupported";Reason="Scheduled-task path is invalid"} }
            if ($taskName -and $taskName -match '[\\/:*?"<>|\r\n]') { return [pscustomobject]@{Valid=$false;Status="Unsupported";Reason="Scheduled-task name contains unsupported characters"} }
        }
        "AppX" {
            if ([string]::IsNullOrWhiteSpace([string]$Operation.Name) -or [string]$Operation.Name.Length -gt 256) { return [pscustomobject]@{Valid=$false;Status="Malformed";Reason="AppX package identity is missing or too long"} }
            if ([string]$Operation.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return [pscustomobject]@{Valid=$false;Status="Unsupported";Reason="AppX package identity is outside the allowlist"} }
        }
    }
    return [pscustomobject]@{Valid=$true;Status="Verified";Reason=$null}
}

function ConvertTo-ExternalChangeImportResult {
    param(
        [string]$Source,[object[]]$Operations,[object[]]$UnsupportedEntries=@(),[object[]]$MalformedEntries=@(),
        [string]$SourcePath,[long]$SourceBytes,[string]$SourceHash,[string]$FormatVersion="text"
    )
    $verified = @($Operations | Where-Object { $_.Status -eq "Verified" })
    $categories = @($verified | ForEach-Object {
        Get-RestoreCategoryForImportedChange -Operation $_
        $operationText = "$($_.Path) $($_.Name)"
        if ($_.Kind -eq "Task" -and $operationText -match '(?i)windows.?update|updateorchestrator|wuauserv') { "chkWindowsUpdate" }
    } | Select-Object -Unique)
    $result = [pscustomobject][ordered]@{
        Success=($verified.Count -gt 0); Status=if($verified.Count -eq 0){"Rejected"}elseif(@($UnsupportedEntries).Count -gt 0 -or @($MalformedEntries).Count -gt 0){"ImportedWithWarnings"}else{"Imported"}
        SchemaVersion=$script:ExternalImportSchemaVersion; Source=$Source; SourcePath=$SourcePath; SourceBytes=$SourceBytes; SourceHash=$SourceHash; FormatVersion=$FormatVersion
        Provenance=(Get-RestoreImportProvenance -SourceType $Source -SourcePath $SourcePath -FormatVersion $FormatVersion -SourceBytes $SourceBytes -SourceHash $SourceHash)
        Operations=$verified; VerifiedEntries=$verified; UntrustedEntries=$verified
        UnsupportedEntries=@($UnsupportedEntries); MalformedEntries=@($MalformedEntries); RelevantCategories=@($categories); Summary=""
    }
    if ($verified.Count -gt 0) {
        $suffix = if(@($UnsupportedEntries).Count -or @($MalformedEntries).Count){"; $(@($UnsupportedEntries).Count + @($MalformedEntries).Count) unsupported or malformed line(s)"}else{""}
        $result.Summary = "$Source imported as untrusted evidence: $($verified.Count) change(s) mapped to $($categories.Count) restoration categor$(if($categories.Count -eq 1){'y'}else{'ies'})$suffix"
    } else { $result.Summary = "$Source contained no verified restoration changes" }
    return $result
}

function ConvertTo-ExternalChangeOperation {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string[]]$Lines,[switch]$Detailed)
    $operations = New-Object System.Collections.Generic.List[object]
    $unsupported = New-Object System.Collections.Generic.List[object]
    $malformed = New-Object System.Collections.Generic.List[object]
    $lineNumber=0
    foreach ($line in @($Lines)) {
        $lineNumber++
        if ($lineNumber -gt $script:ExternalImportMaxLines) { $unsupported.Add([pscustomobject]@{Status="Unsupported";SourceLine=$lineNumber;Reason="Input exceeds the line limit"}); break }
        $raw = [string]$line; $trimmed=$raw.Trim()
        if ([Text.Encoding]::UTF8.GetByteCount($raw) -gt $script:ExternalImportMaxLineBytes) { $unsupported.Add([pscustomobject]@{Status="Unsupported";SourceLine=$lineNumber;Reason="Line exceeds the byte limit"}); continue }
        if (-not $trimmed -or $trimmed.StartsWith("#") -or $trimmed.StartsWith(";") -or $trimmed.StartsWith("//")) { continue }
        $operation=$null
        if ($trimmed -match '(?i)^\s*reg(?:\.exe)?\s+(?<action>add|delete)\s+(?<path>"[^"]+"|\S+)(?:\s+/v\s+(?<name>"[^"]+"|\S+))?(?:\s+/d\s+(?<data>"[^"]+"|\S+))?') {
            $operation=[pscustomobject]@{Kind="Registry";Action=$Matches.action.ToLowerInvariant();Path=(ConvertTo-RestoreImportedRegistryPath $Matches.path.Trim('"'));Name=if($Matches.name){$Matches.name.Trim('"')}else{$null};Value=if($Matches.data){$Matches.data.Trim('"')}else{$null}}
        } elseif ($trimmed -match '(?i)(Set-ItemProperty|Remove-ItemProperty)') {
            $pathMatch=[regex]::Match($trimmed,'(?i)-(?:LiteralPath|Path)\s+(?:"([^"]+)"|''([^'']+)''|(\S+))');$nameMatch=[regex]::Match($trimmed,'(?i)-Name\s+(?:"([^"]+)"|''([^'']+)''|(\S+))')
            if ($pathMatch.Success) {$pathValue=if($pathMatch.Groups[1].Success){$pathMatch.Groups[1].Value}elseif($pathMatch.Groups[2].Success){$pathMatch.Groups[2].Value}else{$pathMatch.Groups[3].Value};$nameValue=if($nameMatch.Groups[1].Success){$nameMatch.Groups[1].Value}elseif($nameMatch.Groups[2].Success){$nameMatch.Groups[2].Value}else{$nameMatch.Groups[3].Value};$operation=[pscustomobject]@{Kind="Registry";Action=if($trimmed -match '(?i)Remove-ItemProperty'){"delete"}else{"add"};Path=$pathValue;Name=$nameValue;Value=$null}}
        } elseif ($trimmed -match '(?i)\bsc(?:\.exe)?\s+config\s+(?<name>\S+).*?start\s*=\s*(?<value>\S+)') {$operation=[pscustomobject]@{Kind="Service";Action="config";Path="";Name=$Matches.name;Value=$Matches.value}}
        elseif ($trimmed -match '(?i)Set-Service\s+.*?-Name\s+(?:"(?<name>[^"]+)"|(?<name2>\S+)).*?-StartupType\s+(?<value>\S+)') {$serviceName=if($Matches.name){$Matches.name}else{$Matches.name2};$operation=[pscustomobject]@{Kind="Service";Action="config";Path="";Name=$serviceName;Value=$Matches.value}}
        elseif ($trimmed -match '(?i)(?:schtasks(?:\.exe)?\s+/change.*?/tn\s+"?(?<name>[^"/]+)"?|(?:Enable|Disable)-ScheduledTask)') {$taskName=if($Matches.name){$Matches.name.Trim()}else{$null};$operation=[pscustomobject]@{Kind="Task";Action=if($trimmed -match '(?i)disable'){"disable"}else{"enable"};Path="";Name=$taskName;Value=$null}}
        elseif ($trimmed -match '(?i)(Add|Remove)-AppxPackage') {$appxMatch=[regex]::Match($trimmed,'(?i)-(?:Name|Package)\s+(?:"([^"]+)"|(\S+))');$appxName=if($appxMatch.Success){if($appxMatch.Groups[1].Success){$appxMatch.Groups[1].Value}else{$appxMatch.Groups[2].Value}}else{$null};$operation=[pscustomobject]@{Kind="AppX";Action=$Matches[1].ToLowerInvariant();Path="";Name=$appxName;Value=$null}}
        elseif ($trimmed -match '(?i)(HKLM:|HKCU:|HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER)' -and $trimmed -notmatch '(?i)^(Registry|Service|Task|AppX)\s*[:\-]') {$operation=[pscustomobject]@{Kind="Registry";Action="unknown";Path=$trimmed;Name="";Value=$null}}
        elseif ($trimmed -match '(?i)^(Registry|Service|Task|AppX)\s*[:\-]\s*(.+)$') {
            $generic=$Matches[2].Trim();$kind=$Matches[1]
            if($kind -eq "Registry"){$genericParts=@($generic -split '\s+',2);$operation=[pscustomobject]@{Kind="Registry";Action="unknown";Path=(ConvertTo-RestoreImportedRegistryPath $genericParts[0]);Name=if($genericParts.Count -gt 1){$genericParts[1]}else{$null};Value=$null}}
            elseif($kind -eq "Service"){$operation=[pscustomobject]@{Kind="Service";Action="unknown";Path="";Name=($generic -split '\s+')[0];Value=$null}}
            elseif($kind -eq "Task"){$operation=[pscustomobject]@{Kind="Task";Action="unknown";Path=$generic;Name=$null;Value=$null}}
            else{$operation=[pscustomobject]@{Kind="AppX";Action="unknown";Path="";Name=($generic -split '\s+')[0];Value=$null}}
        }
        if ($operation) {
            $validation=Test-RestoreExternalChangeOperation -Operation $operation
            $operation | Add-Member -NotePropertyName SourceLine -NotePropertyValue $lineNumber
            $operation | Add-Member -NotePropertyName RawHash -NotePropertyValue (Get-RestoreSha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($raw)))
            $operation | Add-Member -NotePropertyName Trust -NotePropertyValue "UntrustedEvidence"
            $operation | Add-Member -NotePropertyName ExecutableContent -NotePropertyValue $false
            $operation | Add-Member -NotePropertyName Status -NotePropertyValue $validation.Status
            $operation | Add-Member -NotePropertyName Reason -NotePropertyValue $validation.Reason
            if ($validation.Valid) {$operations.Add($operation)}elseif($validation.Status -eq "Malformed"){$malformed.Add($operation)}else{$unsupported.Add($operation)}
        } else { $unsupported.Add([pscustomobject]@{Status="Unsupported";SourceLine=$lineNumber;RawHash=(Get-RestoreSha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($raw)));Reason="Line did not match the allowlisted evidence grammar"}) }
    }
    $document=[pscustomobject][ordered]@{Operations=@($operations.ToArray());UnsupportedEntries=@($unsupported.ToArray());MalformedEntries=@($malformed.ToArray());LineCount=$lineNumber;SchemaVersion=$script:ExternalImportSchemaVersion;ExecutableContent=$false}
    if ($Detailed) { return $document }
    return @($document.Operations)
}

function Import-PrivacySexyCompensationLog {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$LogPath)
    $read=Get-RestoreBoundedTextFile -Path $LogPath
    if (-not $read.Success) { return (ConvertTo-ExternalChangeImportResult -Source "privacy.sexy compensation log" -SourcePath $LogPath -SourceBytes $read.Bytes -SourceHash $read.Hash -UnsupportedEntries @([pscustomobject]@{Status=$read.Status;Reason=$read.Reason})) }
    $parsed=ConvertTo-ExternalChangeOperation -Lines @($read.Text -split "`r?`n") -Detailed
    return (ConvertTo-ExternalChangeImportResult -Source "privacy.sexy compensation log" -SourcePath $LogPath -SourceBytes $read.Bytes -SourceHash $read.Hash -Operations $parsed.Operations -UnsupportedEntries $parsed.UnsupportedEntries -MalformedEntries $parsed.MalformedEntries)
}

function Import-ChrisTitusWinUtilDiff {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$DiffPath)
    $read=Get-RestoreBoundedTextFile -Path $DiffPath
    if (-not $read.Success) { return (ConvertTo-ExternalChangeImportResult -Source "Chris Titus WinUtil diff" -SourcePath $DiffPath -SourceBytes $read.Bytes -SourceHash $read.Hash -UnsupportedEntries @([pscustomobject]@{Status=$read.Status;Reason=$read.Reason})) }
    $parsed=ConvertTo-ExternalChangeOperation -Lines @($read.Text -split "`r?`n") -Detailed
    return (ConvertTo-ExternalChangeImportResult -Source "Chris Titus WinUtil diff" -SourcePath $DiffPath -SourceBytes $read.Bytes -SourceHash $read.Hash -Operations $parsed.Operations -UnsupportedEntries $parsed.UnsupportedEntries -MalformedEntries $parsed.MalformedEntries)
}

function Import-RegExportSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$RegPath)
    if (-not (Test-Path -LiteralPath $RegPath)) { throw "Registry export not found: $RegPath" }
    $fullPath = [System.IO.Path]::GetFullPath($RegPath)
    $read = Get-RestoreBoundedTextFile -Path $fullPath
    $entries = New-Object System.Collections.Generic.List[object]
    $unsupported = New-Object System.Collections.Generic.List[object]
    $malformed = New-Object System.Collections.Generic.List[object]
    $currentPath = $null
    $result = [pscustomobject][ordered]@{
        SchemaVersion=$script:RegistrySnapshotSchemaVersion; ImportSchemaVersion=$script:ExternalImportSchemaVersion
        CreatedAt=(Get-Date).ToUniversalTime().ToString("o"); ComputerName=$env:COMPUTERNAME
        SourcePath=$fullPath; SourceBytes=$read.Bytes; SourceSha256=$read.Hash; FormatVersion="reg-v5"
        Provenance=(Get-RestoreImportProvenance -SourceType ".reg export" -SourcePath $fullPath -FormatVersion "reg-v5" -SourceBytes $read.Bytes -SourceHash $read.Hash)
        Success=$false; Status="Rejected"; Entries=@(); VerifiedEntries=@(); UntrustedEntries=@()
        UnsupportedEntries=@(); MalformedEntries=@(); Summary=""
    }
    if (-not $read.Success) {
        $diagnostic = [pscustomobject]@{Status=$read.Status;SourceLine=0;RawHash=$null;Reason=$read.Reason}
        if ($read.Status -eq "Malformed") { $malformed.Add($diagnostic) } else { $unsupported.Add($diagnostic) }
        $result.UnsupportedEntries = @($unsupported.ToArray()); $result.MalformedEntries = @($malformed.ToArray())
        $result.Summary = "Registry export rejected: $($read.Reason)"
        return $result
    }
    $lineNumber = 0
    foreach ($line in @([regex]::Split($read.Text, "\r?\n"))) {
        $lineNumber++
        $raw = [string]$line
        $trimmed = $raw.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("Windows Registry Editor") -or $trimmed.StartsWith(";")) { continue }
        $rawHash = Get-RestoreSha256 -Bytes ([System.Text.Encoding]::UTF8.GetBytes($raw))
        if ($trimmed -match '^\[(.+)\]$') {
            $candidatePath = ConvertTo-SnapshotRegistryPath -Path $Matches[1]
            if (-not (Test-RestoreImportedRegistryPath -Path $candidatePath)) {
                $unsupported.Add([pscustomobject]@{Status="Unsupported";SourceLine=$lineNumber;RawHash=$rawHash;Reason="Registry section is outside the supported hive allowlist"})
                $currentPath = $null
            } else { $currentPath = $candidatePath }
            continue
        }
        if ($trimmed.StartsWith("-")) {
            $unsupported.Add([pscustomobject]@{Status="Unsupported";SourceLine=$lineNumber;RawHash=$rawHash;Reason="Registry key deletion entries are evidence-only and are not imported"})
            continue
        }
        if (-not $currentPath) {
            $malformed.Add([pscustomobject]@{Status="Malformed";SourceLine=$lineNumber;RawHash=$rawHash;Reason="Registry value appears before a valid section"})
            continue
        }
        if ($trimmed -notmatch '^(?:"([^"]*)"|@)=(.*)$') {
            $malformed.Add([pscustomobject]@{Status="Malformed";SourceLine=$lineNumber;RawHash=$rawHash;Reason="Registry value does not match the supported .reg grammar"})
            continue
        }
        $name = if ($null -ne $Matches[1]) { $Matches[1] } else { "(Default)" }
        if ($name.Length -gt 256 -or $name -match '[\r\n]') {
            $unsupported.Add([pscustomobject]@{Status="Unsupported";SourceLine=$lineNumber;RawHash=$rawHash;Reason="Registry value name is invalid"})
            continue
        }
        if ($entries.Count -ge $script:ExternalImportMaxItems) {
            $unsupported.Add([pscustomobject]@{Status="Unsupported";SourceLine=$lineNumber;RawHash=$rawHash;Reason="Registry export item limit reached"})
            break
        }
        $encoded = $Matches[2]
        $type = "String"
        $value = $encoded
        if ($encoded -match '(?i)^dword:([0-9a-f]{1,8})$') {
            $type = "DWord"; $value = [Convert]::ToInt32($Matches[1],16)
        } elseif ($encoded -match '(?i)^qword:([0-9a-f]{1,16})$') {
            $type = "QWord"; $value = [Convert]::ToInt64($Matches[1],16)
        } elseif ($encoded -match '(?i)^dword:|^qword:') {
            $malformed.Add([pscustomobject]@{Status="Malformed";SourceLine=$lineNumber;RawHash=$rawHash;Reason="Registry integer value is not valid hexadecimal"})
            continue
        } elseif ($encoded -match '(?i)^hex(?:\(\d+\))?:') {
            if ($encoded -notmatch '(?i)^hex(?:\(\d+\))?:[0-9a-f,\s\\]*$') {
                $malformed.Add([pscustomobject]@{Status="Malformed";SourceLine=$lineNumber;RawHash=$rawHash;Reason="Registry binary value is not valid hexadecimal"})
                continue
            }
            $type = "Binary"; $value = $encoded
        } elseif ($encoded -match '^"(.*)"$') {
            $value = $Matches[1] -replace '\\\"','"' -replace '\\\\','\'
        }
        $entry = [pscustomobject][ordered]@{
            Path=$currentPath; Name=$name; Type=$type; Value=$value; SourceLine=$lineNumber; RawHash=$rawHash
            Status="Verified"; Trust="UntrustedEvidence"; ExecutableContent=$false
        }
        $entries.Add($entry)
    }
    $result.Entries = @($entries.ToArray())
    $result.VerifiedEntries = @($entries.ToArray())
    $result.UntrustedEntries = @($entries.ToArray())
    $result.UnsupportedEntries = @($unsupported.ToArray())
    $result.MalformedEntries = @($malformed.ToArray())
    $result.Success = $entries.Count -gt 0
    $result.Status = if ($entries.Count -eq 0) { "Rejected" } elseif ($unsupported.Count -or $malformed.Count) { "ImportedWithWarnings" } else { "Imported" }
    $diagnostics = $unsupported.Count + $malformed.Count
    $result.Summary = if ($entries.Count -gt 0) {
        $suffix = if ($diagnostics) { "; $diagnostics unsupported or malformed line(s)" } else { "" }
        ".reg export imported as untrusted evidence: $($entries.Count) verified value(s)$suffix"
    } else { ".reg export contained no verified registry values" }
    return $result
}

function Compare-RegExportSnapshot {
    param([Parameter(Mandatory=$true)][string]$BeforePath,[Parameter(Mandatory=$true)][string]$AfterPath)
    return (Compare-RegistrySnapshot -Before (Import-RegExportSnapshot $BeforePath) -After (Import-RegExportSnapshot $AfterPath))
}

function Get-RestoreImpactPreview {
    param([string[]]$SelectedKeys,[object]$HealthReport=$script:HealthReport)
    $preview = @()
    $capabilityEvaluations = @(Get-RestoreCapabilityEvaluation -SelectedKeys $SelectedKeys -MachineProfile $script:CapabilityProfile -AllowManagedPolicy:$script:ManagedPolicyOverrideRequested)
    $capabilityMap = @{}
    foreach ($evaluation in $capabilityEvaluations) { $capabilityMap[$evaluation.Key] = $evaluation }
    foreach ($key in @($SelectedKeys)) {
        $matching = if ($HealthReport) { @($HealthReport.GetEnumerator() | Where-Object { $key -in @($_.Value.FixKeys) }) } else { @() }
        $issueCount = 0; $detailCount = 0; $severity = "OK"
        foreach ($item in $matching) {
            $issueCount += [int]$item.Value.IssueCount
            $detailCount += @($item.Value.Details).Count
            if ($item.Value.Severity -eq "Critical") { $severity="Critical" }
            elseif ($item.Value.Severity -eq "High" -and $severity -notin @("Critical")) { $severity="High" }
            elseif ($item.Value.Severity -eq "Medium" -and $severity -eq "OK") { $severity="Medium" }
            elseif ($item.Value.Severity -eq "Low" -and $severity -eq "OK") { $severity="Low" }
        }
        $preview += [pscustomobject][ordered]@{
            FixKey=$key; DetectedIssueCount=$issueCount; DetailCount=$detailCount
            Severity=$severity; HasDetectedIssue=($issueCount -gt 0)
            CapabilityStatus=if ($capabilityMap[$key]) { $capabilityMap[$key].Status } else { "Unknown" }
            CanMutate=if ($capabilityMap[$key]) { [bool]$capabilityMap[$key].CanMutate } else { $false }
            CapabilityReason=if ($capabilityMap[$key]) { $capabilityMap[$key].Reason } else { "Category is not declared in the capability catalog" }
            Scope=if ($capabilityMap[$key]) { $capabilityMap[$key].Scope } else { "Unknown" }
            Risk=if ($capabilityMap[$key]) { $capabilityMap[$key].Risk } else { "Unknown" }
        }
    }
    return @($preview)
}

function Get-RestoreRollbackDirectory {
    [CmdletBinding()]
    param([switch]$Create)
    $directory = Join-Path $env:ProgramData "Restore-WindowsDefaults\rollback"
    if ($Create -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    return $directory
}

function Get-RestoreRollbackOperationHash {
    param([Parameter(Mandatory=$true)][object]$Operation)
    $content = [ordered]@{
        OperationId=$Operation.OperationId; CategoryKey=$Operation.CategoryKey; Kind=$Operation.Kind
        Action=$Operation.Action; Target=$Operation.Target; Scope=$Operation.Scope; Before=$Operation.Before
        After=$Operation.After; RollbackAction=$Operation.RollbackAction; Exact=$Operation.Exact
        CanExecute=$Operation.CanExecute; Reason=$Operation.Reason; Source=$Operation.Source
        Risk=$Operation.Risk; Dependency=$Operation.Dependency; Verification=$Operation.Verification
        Metadata=$Operation.Metadata
    }
    return (Get-RestoreJsonSha256 -Value ([pscustomobject]$content))
}

function ConvertTo-RestoreRollbackJournalOperation {
    param([Parameter(Mandatory=$true)][object]$Operation)
    $journalOperation = [pscustomobject][ordered]@{
        OperationId=$Operation.OperationId; CategoryKey=$Operation.CategoryKey; Kind=$Operation.Kind
        Action=$Operation.Action; Target=$Operation.Target; Scope=$Operation.Scope; Before=$Operation.Before
        After=$Operation.After; RollbackAction=$Operation.RollbackAction; Exact=[bool]$Operation.Exact
        CanExecute=[bool]$Operation.CanExecute; Reason=$Operation.Reason; Source=$Operation.Source
        Risk=$Operation.Risk; Dependency=$Operation.Dependency; Verification=$Operation.Verification
        Metadata=$Operation.Metadata; OperationHash=$null
        JournalStatus="Pending"; Attempt=0; StartedAtUtc=$null; CompletedAtUtc=$null
        Changed=$false; Error=$null; RollbackStatus="Pending"; RollbackError=$null
    }
    $journalOperation.OperationHash = Get-RestoreRollbackOperationHash -Operation $journalOperation
    return $journalOperation
}

function Get-RestoreRollbackIntegrityPayload {
    param([Parameter(Mandatory=$true)][object]$Journal)
    $payload = [ordered]@{}
    foreach ($property in @($Journal.PSObject.Properties)) {
        if ($property.Name -ne "Integrity") { $payload[$property.Name] = $property.Value }
    }
    return [pscustomobject]$payload
}

function Set-RestoreRollbackJournalIntegrity {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][object]$Journal)
    if (-not $PSCmdlet.ShouldProcess("rollback journal", "refresh integrity hash")) { return $Journal }
    $Journal.Integrity = [pscustomobject][ordered]@{
        Algorithm="SHA256"; JournalHash=(Get-RestoreJsonSha256 -Value (Get-RestoreRollbackIntegrityPayload -Journal $Journal))
    }
    return $Journal
}

function Write-RestoreAtomicJson {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][object]$Value,
        [int]$Depth=50
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($script:WhatIfRequested) { return $null }
    if (-not $PSCmdlet.ShouldProcess($fullPath, "atomically write JSON state")) { return $null }
    $parent = Split-Path -Parent $fullPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $tempPath = "$fullPath.tmp-$([guid]::NewGuid().ToString('N'))"
    $backupPath = "$fullPath.bak-$([guid]::NewGuid().ToString('N'))"
    try {
        $json = $Value | ConvertTo-Json -Depth $Depth
        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            [System.IO.File]::Replace($tempPath, $fullPath, $backupPath, $true)
        } else {
            [System.IO.File]::Move($tempPath, $fullPath)
        }
        return $fullPath
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-RestoreRollbackJournalCleanup {
    param([string]$ActivePath)
    $directory = Get-RestoreRollbackDirectory
    if (-not (Test-Path -LiteralPath $directory)) { return }
    $journals = @(Get-ChildItem -LiteralPath $directory -Filter "journal-*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($journals.Count -le $script:RollbackJournalMaxEntries) { return }
    foreach ($candidate in @($journals | Select-Object -Skip $script:RollbackJournalMaxEntries)) {
        if ($ActivePath -and ([System.IO.Path]::GetFullPath($candidate.FullName) -ieq [System.IO.Path]::GetFullPath($ActivePath))) { continue }
        try {
            $raw = [System.IO.File]::ReadAllText($candidate.FullName)
            $journal = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($journal.State -in @("Committed","RolledBack")) { Remove-Item -LiteralPath $candidate.FullName -Force -ErrorAction Stop }
        } catch { Write-Verbose "Could not inspect old rollback journal $($candidate.FullName)" }
    }
}

function New-RestoreRollbackJournal {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][object]$ActionPlan,
        [string[]]$SelectedKeys,
        [string]$OutputPath,
        [object]$BeforeRegistry
    )
    if (-not $ActionPlan.Operations) { throw "An action plan with operations is required to create a rollback journal" }
    $directory = Get-RestoreRollbackDirectory
    $planHash = [string]$ActionPlan.PlanHash
    $hashPrefix = if ($planHash.Length -ge 12) { $planHash.Substring(0, 12) } else { "unhashed" }
    $path = if ($OutputPath) { [System.IO.Path]::GetFullPath($OutputPath) } else {
        Join-Path $directory ("journal-{0}-{1}-{2}.json" -f (Get-Date -Format "yyyyMMdd_HHmmss"), $hashPrefix, ([guid]::NewGuid().ToString("N").Substring(0, 8)))
    }
    if ($script:WhatIfRequested) { return $null }
    if (-not $PSCmdlet.ShouldProcess($path, "prepare an integrity-checked rollback journal")) { return $null }
    $capturedRegistry = if ($PSBoundParameters.ContainsKey("BeforeRegistry")) { $BeforeRegistry } else { Get-RegistrySnapshot }
    $journalOperations = New-Object System.Collections.Generic.List[object]
    foreach ($operation in @($ActionPlan.Operations)) { $journalOperations.Add((ConvertTo-RestoreRollbackJournalOperation -Operation $operation)) }
    $now = (Get-Date).ToUniversalTime().ToString("o")
    $journal = [pscustomobject][ordered]@{
        SchemaVersion=$script:RollbackJournalSchemaVersion; ToolVersion=$script:Version; JournalId=([guid]::NewGuid().ToString())
        State="Prepared"; CreatedAtUtc=$now; UpdatedAtUtc=$now; PlanHash=$planHash
        SelectedKeys=@($SelectedKeys); Profile=$ActionPlan.Profile; BeforeRegistry=$capturedRegistry
        Operations=@($journalOperations.ToArray()); NextOperationIndex=0
        CleanupPolicy=[pscustomobject][ordered]@{KeepLast=$script:RollbackJournalMaxEntries;NeverDeleteActive=$true;DeleteStates=@("Committed","RolledBack")}
        Integrity=$null
    }
    Set-RestoreRollbackJournalIntegrity -Journal $journal | Out-Null
    $written = Write-RestoreAtomicJson -Path $path -Value $journal -Depth 50
    if (-not $written) { return $null }
    $script:LastRollbackPath = $written
    $script:ActiveRollbackJournalPath = $written
    $script:ActiveRollbackJournal = $journal
    Invoke-RestoreRollbackJournalCleanup -ActivePath $written
    Write-Log "Rollback journal prepared: $(Split-Path $written -Leaf)" -Level Info
    return $written
}

function New-RestoreRollbackSnapshot {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string[]]$SelectedKeys)
    $plan = Get-RestoreActionPlan -SelectedKeys $SelectedKeys -MachineProfile $script:CapabilityProfile -AllowManagedPolicy:$script:ManagedPolicyOverrideRequested
    return (New-RestoreRollbackJournal -ActionPlan $plan -SelectedKeys $SelectedKeys)
}

function Set-RegistrySnapshotValue {
    [CmdletBinding(SupportsShouldProcess=$true)]
    [OutputType([bool])]
    param([object]$Entry)
    if ($Entry.Name -eq "(Default)") { return $false }
    if (-not $PSCmdlet.ShouldProcess("$($Entry.Path)\$($Entry.Name)", "restore registry value")) { return $false }
    $value = $Entry.Value
    if ($Entry.Type -eq "MultiString") { $value = @($value | ForEach-Object { [string]$_ }) }
    elseif ($Entry.Type -eq "DWord") { $value = [int]$value }
    elseif ($Entry.Type -eq "QWord") { $value = [long]$value }
    elseif ($Entry.Type -eq "Binary") { $value = [byte[]]@($value | ForEach-Object { [byte]$_ }) }
    return (Set-RegistryValue -Path $Entry.Path -Name $Entry.Name -Value $value -Type $Entry.Type -Silent)
}

function ConvertTo-RestoreLegacyRollbackJournal {
    param([Parameter(Mandatory=$true)][object]$LegacyState)
    $now = (Get-Date).ToUniversalTime().ToString("o")
    $journal = [pscustomobject][ordered]@{
        SchemaVersion=$script:RollbackJournalSchemaVersion; ToolVersion=$script:Version; JournalId=([guid]::NewGuid().ToString())
        State="Committed"; CreatedAtUtc=if($LegacyState.CreatedAt){[string]$LegacyState.CreatedAt}else{$now}; UpdatedAtUtc=$now
        PlanHash="legacy-snapshot"; SelectedKeys=@($LegacyState.SelectedKeys); Profile=$null
        BeforeRegistry=$LegacyState.BeforeRegistry; Operations=@(); NextOperationIndex=0
        CleanupPolicy=[pscustomobject][ordered]@{KeepLast=$script:RollbackJournalMaxEntries;NeverDeleteActive=$true;DeleteStates=@("Committed","RolledBack")}
        Integrity=$null; LegacySnapshot=$true; Services=@($LegacyState.Services); Tasks=@($LegacyState.Tasks)
    }
    Set-RestoreRollbackJournalIntegrity -Journal $journal | Out-Null
    return $journal
}

function Read-RestoreRollbackJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Rollback journal not found: $fullPath" }
    $file = Get-Item -LiteralPath $fullPath -ErrorAction Stop
    if ($file.Length -gt $script:RollbackJournalMaxBytes) { throw "Rollback journal exceeds the maximum supported size" }
    try { $journal = [System.IO.File]::ReadAllText($fullPath) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Rollback journal is not valid JSON: $($_.Exception.Message)" }
    if ($journal.SchemaVersion -eq 1 -and $journal.PSObject.Properties["BeforeRegistry"]) {
        $converted = ConvertTo-RestoreLegacyRollbackJournal -LegacyState $journal
        $script:LastRollbackPath = $fullPath
        return $converted
    }
    if ([int]$journal.SchemaVersion -ne $script:RollbackJournalSchemaVersion) { throw "Unsupported rollback journal schema: $($journal.SchemaVersion)" }
    foreach ($required in @("JournalId","State","PlanHash","BeforeRegistry","Operations","Integrity")) {
        if (-not $journal.PSObject.Properties[$required]) { throw "Rollback journal is missing $required" }
    }
    if ([string]$journal.Integrity.Algorithm -ne "SHA256" -or [string]::IsNullOrWhiteSpace([string]$journal.Integrity.JournalHash)) {
        throw "Rollback journal integrity metadata is missing or unsupported"
    }
    $calculatedJournalHash = Get-RestoreJsonSha256 -Value (Get-RestoreRollbackIntegrityPayload -Journal $journal)
    if ($calculatedJournalHash -ne [string]$journal.Integrity.JournalHash) { throw "Rollback journal integrity verification failed" }
    $validStates = @("Prepared","Executing","Committed","Failed","RollingBack","RolledBack","RollbackPartial","RollbackFailed")
    if ([string]$journal.State -notin $validStates) { throw "Rollback journal has an invalid state: $($journal.State)" }
    $seenOperationIds = @{}
    foreach ($operation in @($journal.Operations)) {
        if ([string]::IsNullOrWhiteSpace([string]$operation.OperationId) -or $seenOperationIds.ContainsKey([string]$operation.OperationId)) { throw "Rollback journal contains a duplicate or missing operation ID" }
        $seenOperationIds[[string]$operation.OperationId] = $true
        if ([string]$operation.OperationHash -ne (Get-RestoreRollbackOperationHash -Operation $operation)) { throw "Rollback journal operation integrity verification failed for $($operation.OperationId)" }
    }
    $script:LastRollbackPath = $fullPath
    return $journal
}

function Update-RestoreRollbackJournal {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [object]$Journal=$script:ActiveRollbackJournal,
        [string]$JournalPath=$script:ActiveRollbackJournalPath,
        [string]$State,
        [string]$OperationId,
        [string]$OperationStatus,
        [bool]$Changed,
        [string]$ErrorMessage,
        [int]$NextOperationIndex=-1
    )
    if (-not $Journal) { return $null }
    if (-not $JournalPath) { $JournalPath = $script:ActiveRollbackJournalPath }
    if (-not $JournalPath) { throw "Rollback journal path is not available" }
    if (-not $PSCmdlet.ShouldProcess($JournalPath, "update rollback journal state")) { return $Journal }
    if ($State) { $Journal.State = $State }
    if ($OperationId) {
        $operation = @($Journal.Operations | Where-Object { [string]$_.OperationId -eq $OperationId } | Select-Object -First 1)
        if ($operation.Count -ne 1) { throw "Rollback journal operation not found: $OperationId" }
        $operation = $operation[0]
        if ($OperationStatus) {
            $operation.JournalStatus = $OperationStatus
            if ($OperationStatus -in @("RollbackRunning","RolledBack","RollbackUnsupported","RollbackFailed","RollbackConflict")) { $operation.RollbackStatus = $OperationStatus }
            if ($OperationStatus -eq "Running") {
                $operation.Attempt = [int]$operation.Attempt + 1
                $operation.StartedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            }
            if ($OperationStatus -in @("Completed","VerifiedNoChange","Failed","RollbackRunning","RolledBack","RollbackUnsupported","RollbackFailed","RollbackConflict")) {
                $operation.CompletedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            }
        }
        if ($PSBoundParameters.ContainsKey("Changed")) { $operation.Changed = [bool]$Changed }
        if ($PSBoundParameters.ContainsKey("ErrorMessage")) { $operation.Error = $ErrorMessage }
        if ($OperationStatus -in @("RollbackRunning","RolledBack","RollbackUnsupported","RollbackFailed","RollbackConflict") -and $PSBoundParameters.ContainsKey("ErrorMessage")) { $operation.RollbackError = $ErrorMessage }
    }
    if ($NextOperationIndex -ge 0) { $Journal.NextOperationIndex = $NextOperationIndex }
    $Journal.UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    Set-RestoreRollbackJournalIntegrity -Journal $Journal | Out-Null
    $written = Write-RestoreAtomicJson -Path $JournalPath -Value $Journal -Depth 50
    if (-not $written) { return $null }
    $script:ActiveRollbackJournalPath = $written
    $script:ActiveRollbackJournal = $Journal
    $script:LastRollbackPath = $written
    return $Journal
}

function Test-RestoreRollbackPostcondition {
    param([Parameter(Mandatory=$true)][object]$Operation)
    if (-not $Operation.After) { return [pscustomobject]@{Matches=$true;Reason=$null} }
    $properties = [ordered]@{}
    foreach ($property in @($Operation.PSObject.Properties)) { $properties[$property.Name] = $property.Value }
    $properties.Before = $Operation.After
    try { return (Test-RestoreActionPlanPrecondition -Operation ([pscustomobject]$properties)) }
    catch { return [pscustomobject]@{Matches=$false;Reason="Could not verify postcondition: $($_.Exception.Message)"} }
}

function Invoke-RestoreFileState {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][object]$State)
    if (-not $State.Exists) {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        return (Invoke-RestoreFileMutation -Action Remove -Path $Path -Silent)
    }
    if ($State.IsDirectory) {
        if (Test-Path -LiteralPath $Path -PathType Container) { return $false }
        if (Test-Path -LiteralPath $Path) { Invoke-RestoreFileMutation -Action Remove -Path $Path -Silent | Out-Null }
        if (-not $PSCmdlet.ShouldProcess($Path, "restore directory state")) { return $false }
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        $script:ChangesCount++
        return $true
    }
    if (-not $State.ContentBase64) { throw "Rollback does not have inline bytes for file state: $Path" }
    $bytes = [Convert]::FromBase64String([string]$State.ContentBase64)
    if (-not $PSCmdlet.ShouldProcess($Path, "restore file bytes")) { return $false }
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, $bytes)
    $script:ChangesCount++
    return $true
}

function Invoke-RestoreScheduledTaskRegistration {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][string]$TaskPath,[Parameter(Mandatory=$true)][string]$TaskName,[Parameter(Mandatory=$true)][string]$Xml)
    if (-not $PSCmdlet.ShouldProcess("Task:$TaskPath$TaskName", "restore scheduled task XML")) { return $false }
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Xml $Xml -Force -ErrorAction Stop | Out-Null
    $script:ChangesCount++
    return $true
}

function Invoke-RestoreAppxRemoval {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][string]$PackageName,[string]$Scope="CurrentUser")
    $allUsers = $Scope -in @("AllUsers","Provisioned")
    $packages = @(Get-AppxPackageSafe -Name $PackageName -AllUsers:$allUsers | Where-Object { $_ })
    if ($packages.Count -eq 0) { return $false }
    if (-not $PSCmdlet.ShouldProcess("$PackageName ($Scope)", "remove AppX package")) { return $false }
    foreach ($package in $packages) {
        if ($allUsers) { Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop }
        else { Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop }
    }
    $script:ChangesCount++
    return $true
}

function Invoke-RestoreOptionalFeatureState {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][string]$FeatureName,[string]$State)
    if ([string]::IsNullOrWhiteSpace($State) -or $State -eq "Missing") { throw "Optional feature state cannot be restored: $FeatureName" }
    $feature = Get-WindowsOptionalFeature -FeatureName $FeatureName -Online -ErrorAction SilentlyContinue
    if (-not $feature) { throw "Optional feature is unavailable: $FeatureName" }
    $currentState = [string]$feature.State
    if ($State -eq "Enabled") {
        if ($currentState -eq "Enabled") { return $false }
        if (-not $PSCmdlet.ShouldProcess($FeatureName, "enable optional Windows feature")) { return $false }
        Enable-WindowsOptionalFeature -FeatureName $FeatureName -Online -NoRestart -LogLevel Errors -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
    } else {
        if ($currentState -ne "Enabled") { return $false }
        if (-not $PSCmdlet.ShouldProcess($FeatureName, "disable optional Windows feature")) { return $false }
        Disable-WindowsOptionalFeature -FeatureName $FeatureName -Online -NoRestart -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
    }
    $script:ChangesCount++
    return $true
}

function Invoke-RestoreLegacyRollback {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][object]$Journal)
    $before = $Journal.BeforeRegistry
    if ($before -and $before.Entries) {
        $after = Get-RegistrySnapshot
        $beforeMap = @{}; $afterMap = @{}
        foreach ($entry in @($before.Entries)) { $beforeMap["$($entry.Path)|$($entry.Name)"] = $entry }
        foreach ($entry in @($after.Entries)) { $afterMap["$($entry.Path)|$($entry.Name)"] = $entry }
        foreach ($key in $afterMap.Keys) {
            if (-not $beforeMap.ContainsKey($key) -and $afterMap[$key].Name -ne "(Default)") {
                Remove-RegistryValue -Path $afterMap[$key].Path -Name $afterMap[$key].Name -Silent | Out-Null
            }
        }
        foreach ($entry in @($before.Entries)) { Set-RegistrySnapshotValue -Entry $entry | Out-Null }
    }
    foreach ($service in @($Journal.Services)) {
        if ($service.StartType) { Restore-ServiceStartup -ServiceName $service.Name -StartupType $service.StartType -Silent | Out-Null }
    }
    foreach ($task in @($Journal.Tasks)) {
        $taskPath = if($task.Path){[string]$task.Path}else{[string]$task.TaskPath}
        $taskName = if($task.Name){[string]$task.Name}else{[string]$task.TaskName}
        if ($task.State -eq "Disabled") { Invoke-RestoreScheduledTaskState -Action Disable -TaskPath $taskPath -TaskName $taskName -Silent | Out-Null }
        elseif ($task.State -eq "Enabled") { Invoke-RestoreScheduledTaskState -Action Enable -TaskPath $taskPath -TaskName $taskName -Silent | Out-Null }
    }
    return $true
}

function Invoke-RestoreRegistrySnapshotReconciliation {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][object]$BeforeRegistry)
    $errors = 0
    $after = Get-RegistrySnapshot
    $beforeMap = @{}; $afterMap = @{}
    foreach ($entry in @($BeforeRegistry.Entries)) { $beforeMap["$($entry.Path)|$($entry.Name)"] = $entry }
    foreach ($entry in @($after.Entries)) { $afterMap["$($entry.Path)|$($entry.Name)"] = $entry }
    foreach ($key in $afterMap.Keys) {
        if (-not $beforeMap.ContainsKey($key) -and $afterMap[$key].Name -ne "(Default)") {
            try { Remove-RegistryValue -Path $afterMap[$key].Path -Name $afterMap[$key].Name -Silent | Out-Null } catch { $errors++ }
        }
    }
    foreach ($entry in @($BeforeRegistry.Entries)) {
        try { Set-RegistrySnapshotValue -Entry $entry | Out-Null } catch { $errors++ }
    }
    return $errors
}

function Invoke-RestoreJournalInverseOperation {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][object]$Operation)
    $postcondition = Test-RestoreRollbackPostcondition -Operation $Operation
    if (-not $postcondition.Matches) { return [pscustomobject]@{Status="RollbackConflict";Changed=$false;Reason=$postcondition.Reason} }
    try {
        switch ($Operation.Kind) {
            "RegistryValue" {
                if ($Operation.Before.Exists) {
                    return [pscustomobject]@{Status="RolledBack";Changed=(Set-RegistrySnapshotValue -Entry $Operation.Before);Reason=$null}
                }
                $changed = Remove-RegistryValue -Path $Operation.Before.Path -Name $Operation.Before.Name -Silent
                if ($Operation.Before.PSObject.Properties["KeyExists"] -and -not $Operation.Before.KeyExists -and (Test-Path -LiteralPath $Operation.Before.Path)) {
                    $changed = (Remove-RegistryKey -Path $Operation.Before.Path -Silent) -or $changed
                }
                return [pscustomobject]@{Status="RolledBack";Changed=$changed;Reason=$null}
            }
            "RegistryKey" {
                if ($Operation.Before.Exists) {
                    return [pscustomobject]@{Status="RolledBack";Changed=(New-RestoreRegistryKey -Path $Operation.Before.Path -Silent);Reason=$null}
                }
                return [pscustomobject]@{Status="RolledBack";Changed=(Remove-RegistryKey -Path $Operation.Before.Path -Silent);Reason=$null}
            }
            "Service" {
                if (-not $Operation.Before.Exists) { return [pscustomobject]@{Status="RollbackUnsupported";Changed=$false;Reason="The service did not exist before the run"} }
                $changed = Restore-ServiceStartup -ServiceName ($Operation.Target -replace '^Service:', '') -StartupType $Operation.Before.StartType -Silent
                if ($Operation.Before.Status -and $Operation.Before.Status -notin @("Unknown","Stopped","Running")) { return [pscustomobject]@{Status="RollbackUnsupported";Changed=$changed;Reason="Unknown service state"} }
                if ($Operation.Before.Status -and $Operation.Before.Status -in @("Stopped","Running")) {
                    $desiredAction = if ($Operation.Before.Status -eq "Stopped") { "Stop" } else { "Start" }
                    $changed = (Invoke-RestoreServiceControl -Action $desiredAction -ServiceName ($Operation.Target -replace '^Service:', '') -Silent) -or $changed
                }
                return [pscustomobject]@{Status="RolledBack";Changed=$changed;Reason=$null}
            }
            "ServiceControl" {
                if (-not $Operation.Before.Exists) { return [pscustomobject]@{Status="RollbackUnsupported";Changed=$false;Reason="The service did not exist before the run"} }
                if (-not $Operation.Before.Status -or $Operation.Before.Status -notin @("Stopped","Running")) { return [pscustomobject]@{Status="RollbackUnsupported";Changed=$false;Reason="The original service state is unavailable"} }
                $desiredAction = if ($Operation.Before.Status -eq "Stopped") { "Stop" } else { "Start" }
                return [pscustomobject]@{Status="RolledBack";Changed=(Invoke-RestoreServiceControl -Action $desiredAction -ServiceName ($Operation.Target -replace '^Service:', '') -Silent);Reason=$null}
            }
            "ScheduledTask" {
                $taskPath = if($Operation.Before.Path){[string]$Operation.Before.Path}else{(($Operation.Target -replace '^Task:', '') -replace '\\[^\\]+$','\\')}
                $taskName = if($Operation.Before.Name){[string]$Operation.Before.Name}else{($Operation.Target -replace '^Task:', '') -replace '^.*\\',''}
                if (-not $Operation.Before.Exists) { return [pscustomobject]@{Status="RollbackUnsupported";Changed=$false;Reason="The scheduled task did not exist before the run"} }
                $current = Get-RestoreScheduledTaskPlanState -TaskPath $taskPath -TaskName $taskName
                $changed = $false
                if (-not $current.Exists -and $Operation.Before.Xml) {
                    $changed = Invoke-RestoreScheduledTaskRegistration -TaskPath $taskPath -TaskName $taskName -Xml $Operation.Before.Xml
                }
                if ($Operation.Before.Xml -and $current.Exists -and $current.XmlSha256 -ne $Operation.Before.XmlSha256) {
                    $changed = (Invoke-RestoreScheduledTaskRegistration -TaskPath $taskPath -TaskName $taskName -Xml $Operation.Before.Xml) -or $changed
                }
                if ($Operation.Before.State -eq "Disabled") {
                    $changed = (Invoke-RestoreScheduledTaskState -Action Disable -TaskPath $taskPath -TaskName $taskName -Silent) -or $changed
                } elseif ($Operation.Before.State) {
                    $changed = (Invoke-RestoreScheduledTaskState -Action Enable -TaskPath $taskPath -TaskName $taskName -Silent) -or $changed
                }
                return [pscustomobject]@{Status="RolledBack";Changed=$changed;Reason=$null}
            }
            "File" {
                if ($Operation.Action -in @("Rename","Move")) {
                    $source = [string]$Operation.After.Path
                    $destination = [string]$Operation.Before.Path
                    return [pscustomobject]@{Status="RolledBack";Changed=(Invoke-RestoreFileMutation -Action Move -Path $source -Destination $destination -Silent);Reason=$null}
                }
                if ($Operation.Action -eq "Copy") {
                    return [pscustomobject]@{Status="RolledBack";Changed=(Invoke-RestoreFileMutation -Action Remove -Path $Operation.After.Path -Silent);Reason=$null}
                }
                return [pscustomobject]@{Status="RolledBack";Changed=(Invoke-RestoreFileState -Path $Operation.Before.Path -State $Operation.Before);Reason=$null}
            }
            "AppX" {
                if ($Operation.Before.Installed) { return [pscustomobject]@{Status="RolledBack";Changed=$false;Reason=$null} }
                $scope = if($Operation.Before.Scope){[string]$Operation.Before.Scope}else{[string]$Operation.After.Scope}
                return [pscustomobject]@{Status="RolledBack";Changed=(Invoke-RestoreAppxRemoval -PackageName $Operation.Before.PackageName -Scope $scope);Reason=$null}
            }
            "OptionalFeature" {
                return [pscustomobject]@{Status="RolledBack";Changed=(Invoke-RestoreOptionalFeatureState -FeatureName $Operation.Target -State $Operation.Before.State);Reason=$null}
            }
            "EnvironmentVariable" {
                $separator = $Operation.Target.IndexOf(':')
                if ($separator -le 0) { return [pscustomobject]@{Status="RollbackUnsupported";Changed=$false;Reason="Environment-variable scope is invalid"} }
                $scope = $Operation.Target.Substring(0, $separator); $name = $Operation.Target.Substring($separator + 1)
                $remove = $null -eq $Operation.Before.Value
                return [pscustomobject]@{Status="RolledBack";Changed=(Invoke-RestoreEnvironmentVariable -Name $name -Scope $scope -Value $Operation.Before.Value -Remove:$remove -Silent);Reason=$null}
            }
            "NativeCommand" { return [pscustomobject]@{Status="RollbackUnsupported";Changed=$false;Reason="Native command has no safe automatic inverse"} }
            "RestorePoint" { return [pscustomobject]@{Status="RollbackUnsupported";Changed=$false;Reason="Windows restore points are rolled back by System Restore"} }
            default { return [pscustomobject]@{Status="RollbackUnsupported";Changed=$false;Reason="No inverse adapter exists for $($Operation.Kind)"} }
        }
    } catch {
        return [pscustomobject]@{Status="RollbackFailed";Changed=$false;Reason=$_.Exception.Message}
    }
}

function Invoke-RestoreRollback {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$RollbackPath)
    if (-not $RollbackPath) {
        $directory = Get-RestoreRollbackDirectory
        $RollbackPath = @(
            @(Get-ChildItem -LiteralPath $directory -Filter "journal-*.json" -File -ErrorAction SilentlyContinue) +
            @(Get-ChildItem -LiteralPath $directory -Filter "rollback-*.json" -File -ErrorAction SilentlyContinue)
        ) | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $RollbackPath) { throw "No rollback journal is available" }
    $journal = Read-RestoreRollbackJournal -Path $RollbackPath
    $script:ActiveRollbackJournalPath = [System.IO.Path]::GetFullPath($RollbackPath)
    $script:ActiveRollbackJournal = $journal
    if ($journal.LegacySnapshot) {
        if (-not $PSCmdlet.ShouldProcess($RollbackPath, "restore the legacy rollback snapshot")) { return $false }
        $legacyResult = Invoke-RestoreLegacyRollback -Journal $journal
        Write-Log "Legacy rollback snapshot restored from $(Split-Path $RollbackPath -Leaf)" -Level Success
        return $legacyResult
    }
    if ($journal.State -eq "RolledBack") { return [pscustomobject]@{Success=$true;State="RolledBack";JournalPath=$RollbackPath;Errors=0;Unsupported=0} }
    if (-not $PSCmdlet.ShouldProcess($RollbackPath, "rollback the verified journal")) { return $false }
    Update-RestoreRollbackJournal -Journal $journal -JournalPath $RollbackPath -State "RollingBack" | Out-Null
    $errors = 0; $unsupported = @($journal.Operations | Where-Object { $_.JournalStatus -eq "RollbackUnsupported" }).Count
    $operations = @($journal.Operations | Where-Object {
        $_.JournalStatus -in @("Running","Completed","Failed","RollbackFailed","RollbackConflict") -and
        ($_.Changed -or $_.JournalStatus -in @("Running","Failed","RollbackFailed","RollbackConflict"))
    } | Sort-Object { [int]([regex]::Match([string]$_.OperationId, '\d+$').Value) } -Descending)
    foreach ($operation in $operations) {
        Update-RestoreRollbackJournal -Journal $journal -JournalPath $RollbackPath -OperationId $operation.OperationId -OperationStatus "RollbackRunning" | Out-Null
        $inverse = Invoke-RestoreJournalInverseOperation -Operation $operation
        if ($inverse.Status -eq "RolledBack") {
            Update-RestoreRollbackJournal -Journal $journal -JournalPath $RollbackPath -OperationId $operation.OperationId -OperationStatus "RolledBack" -Changed:$inverse.Changed -ErrorMessage $inverse.Reason | Out-Null
        } elseif ($inverse.Status -eq "RollbackUnsupported" -or $inverse.Status -eq "RollbackConflict") {
            $unsupported++
            Update-RestoreRollbackJournal -Journal $journal -JournalPath $RollbackPath -OperationId $operation.OperationId -OperationStatus $inverse.Status -Changed:$inverse.Changed -ErrorMessage $inverse.Reason | Out-Null
        } else {
            $errors++
            Update-RestoreRollbackJournal -Journal $journal -JournalPath $RollbackPath -OperationId $operation.OperationId -OperationStatus "RollbackFailed" -Changed:$inverse.Changed -ErrorMessage $inverse.Reason | Out-Null
        }
    }
    if ($journal.BeforeRegistry) {
        $errors += [int](Invoke-RestoreRegistrySnapshotReconciliation -BeforeRegistry $journal.BeforeRegistry)
        try {
            $registryDiff = Compare-RegistrySnapshot -Before $journal.BeforeRegistry -After (Get-RegistrySnapshot)
            if ([int]$registryDiff.TotalChanges -gt 0) { $errors++ }
        } catch { $errors++ }
    }
    $finalState = if ($errors -gt 0) { "RollbackFailed" } elseif ($unsupported -gt 0) { "RollbackPartial" } else { "RolledBack" }
    Update-RestoreRollbackJournal -Journal $journal -JournalPath $RollbackPath -State $finalState | Out-Null
    Write-Log "Rollback journal ${finalState}: $(Split-Path $RollbackPath -Leaf)" -Level $(if($finalState -eq "RolledBack"){"Success"}else{"Warning"})
    return [pscustomobject]@{Success=($finalState -eq "RolledBack");State=$finalState;JournalPath=$RollbackPath;Errors=$errors;Unsupported=$unsupported}
}

function Resume-RestoreRollbackJournal {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$JournalPath)
    if (-not $JournalPath) {
        $JournalPath = @(Get-ChildItem -LiteralPath (Get-RestoreRollbackDirectory) -Filter "journal-*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    }
    if (-not $JournalPath) { throw "No rollback journal is available to resume" }
    $journal = Read-RestoreRollbackJournal -Path $JournalPath
    if ($journal.LegacySnapshot) { throw "Legacy rollback snapshots cannot be resumed; use -RollbackLastRun" }
    if ($journal.State -eq "Committed") { return [pscustomobject]@{Success=$true;State="Committed";JournalPath=$JournalPath;Errors=0} }
    if ($journal.State -in @("RolledBack","RollbackPartial","RollbackFailed")) { throw "Rollback journal cannot be resumed from state $($journal.State)" }
    if (-not $PSCmdlet.ShouldProcess($JournalPath, "resume the verified rollback journal")) { return $false }
    $script:ActiveRollbackJournalPath = [System.IO.Path]::GetFullPath($JournalPath)
    $script:ActiveRollbackJournal = $journal
    Update-RestoreRollbackJournal -Journal $journal -JournalPath $JournalPath -State "Executing" | Out-Null
    $result = Invoke-RestoreActionPlan -ActionPlan $journal
    $finalState = if ($result.Errors -gt 0) { "Failed" } else { "Committed" }
    Update-RestoreRollbackJournal -Journal $journal -JournalPath $JournalPath -State $finalState | Out-Null
    return [pscustomobject]@{Success=($result.Errors -eq 0);State=$finalState;JournalPath=$JournalPath;Errors=[int]$result.Errors;Changed=[int]$result.Changed}
}

function Register-RestoreAtNextBoot {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][string[]]$SelectedKeys,[switch]$CreateRestorePoint)
    if ($SelectedKeys.Count -eq 0) { throw "At least one restore category is required" }
    $capabilityEvaluations = @(Get-RestoreCapabilityEvaluation -SelectedKeys $SelectedKeys -MachineProfile $script:CapabilityProfile -AllowManagedPolicy:$script:ManagedPolicyOverrideRequested)
    $blockedCapabilities = @($capabilityEvaluations | Where-Object { -not $_.CanMutate })
    if ($blockedCapabilities.Count -gt 0) {
        throw ("Capability gate blocked scheduling: " + (($blockedCapabilities | ForEach-Object { "$($_.Key): $($_.Reason)" }) -join "; "))
    }
    if (-not $PSCmdlet.ShouldProcess("next-boot restore job", "register the selected restore plan")) { return $null }
    $directory = Join-Path $env:ProgramData "Restore-WindowsDefaults\scheduled"
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $statePath = Join-Path $directory ("restore-{0}.json" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $state = [pscustomobject][ordered]@{
        SchemaVersion=1; CreatedAt=(Get-Date).ToUniversalTime().ToString("o")
        SelectedKeys=@($SelectedKeys); CreateRestorePoint=[bool]$CreateRestorePoint
    }
    [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)
    $runOncePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
    if (-not (Test-Path -LiteralPath $runOncePath)) { New-Item -Path $runOncePath -Force | Out-Null }
    $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -NoGui -ResumeScheduledRestore"
    Set-ItemProperty -Path $runOncePath -Name "RestoreWindowsDefaults" -Value $command -Type String -Force
    Write-Log "Restore scheduled for next boot: $(Split-Path $statePath -Leaf)" -Level Success
    return $statePath
}

function Invoke-ScheduledRestore {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param()
    $statePath = @(Get-ChildItem -LiteralPath (Join-Path $env:ProgramData "Restore-WindowsDefaults\scheduled") -Filter "restore-*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    if (-not $statePath) { throw "No scheduled restore state is available" }
    $state = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $capabilityEvaluations = @(Get-RestoreCapabilityEvaluation -SelectedKeys @($state.SelectedKeys) -MachineProfile $script:CapabilityProfile -AllowManagedPolicy:$script:ManagedPolicyOverrideRequested)
    $blockedCapabilities = @($capabilityEvaluations | Where-Object { -not $_.CanMutate })
    if ($blockedCapabilities.Count -gt 0) {
        throw ("Capability gate blocked scheduled restore: " + (($blockedCapabilities | ForEach-Object { "$($_.Key): $($_.Reason)" }) -join "; "))
    }
    if (-not $PSCmdlet.ShouldProcess("scheduled restore job", "consume and execute the selected restore plan")) { return $false }
    $runOncePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
    Remove-RegistryValue -Path $runOncePath -Name "RestoreWindowsDefaults" -Silent
    $result = Invoke-RestoreSelection -SelectedKeys @($state.SelectedKeys) -CreateRollbackSnapshot -AllowManagedPolicy:$script:ManagedPolicyOverrideRequested
    if ($result.ExitCode -ne 0) { throw "Scheduled restore did not complete successfully (exit code $($result.ExitCode))" }
    Invoke-RestoreFileMutation -Action Remove -Path $statePath -Silent
    Write-Log "Scheduled restore completed" -Level Success
    return $true
}

function Get-PostUpdateSecurityRecheck {
    $health = Get-SystemHealthReport
    $securityKeys = @("Defender","Firewall","SmartScreen","WindowsUpdate","SecurityUI","Crypto")
    $security = @()
    foreach ($key in $securityKeys) {
        if ($health.Contains($key)) {
            $security += [pscustomobject]@{
                Category=$key; Severity=$health[$key].Severity; IssueCount=$health[$key].IssueCount
                Issues=@($health[$key].Issues); Details=@($health[$key].Details)
            }
        }
    }
    return [pscustomobject][ordered]@{
        CheckedAt=(Get-Date).ToUniversalTime().ToString("o")
        Passed=(@($security | Where-Object { $_.Severity -in @("Critical","High") }).Count -eq 0)
        Categories=@($security)
    }
}

function Export-RestoreSupportBundle {
    param([Parameter(Mandatory=$true)][string]$OutputPath)
    $fullPath = [System.IO.Path]::GetFullPath($OutputPath)
    if ([System.IO.Path]::GetExtension($fullPath) -ine ".zip") { $fullPath += ".zip" }
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("RestoreSupport-{0}" -f ([guid]::NewGuid().ToString("N")))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        $health = Get-SystemHealthReport
        $quick = Get-QuickScanSummary
        [System.IO.File]::WriteAllText((Join-Path $staging "health.json"), ($health | ConvertTo-Json -Depth 12), [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText((Join-Path $staging "quick-scan.json"), ($quick | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)
        $logFiles = @(Get-ChildItem -LiteralPath (Split-Path $script:LogPath) -Filter "WindowsRestore_*.log" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10)
        foreach ($log in $logFiles) {
            $safe = Get-Content -LiteralPath $log.FullName -Raw -ErrorAction SilentlyContinue
            if ($env:USERNAME) { $safe = $safe -replace [regex]::Escape($env:USERNAME), "REDACTED_USER" }
            if ($env:COMPUTERNAME) { $safe = $safe -replace [regex]::Escape($env:COMPUTERNAME), "REDACTED_COMPUTER" }
            [System.IO.File]::WriteAllText((Join-Path $staging $log.Name), $safe, [System.Text.Encoding]::UTF8)
        }
        $rollbackDirectory = Join-Path $env:ProgramData "Restore-WindowsDefaults\rollback"
        if (Test-Path -LiteralPath $rollbackDirectory) {
            Copy-Item -Path (Join-Path $rollbackDirectory "rollback-*.json") -Destination $staging -Force -ErrorAction SilentlyContinue
        }
        $parent = Split-Path -Parent $fullPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        if (Test-Path -LiteralPath $fullPath) { Remove-Item -LiteralPath $fullPath -Force }
        Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $fullPath -CompressionLevel Optimal -Force
        Write-Log "Telemetry-free support bundle exported: $fullPath" -Level Success
        return $fullPath
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Restore-LocalGroupPolicyDefault {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([switch]$ForceManaged)
    $management = Get-PolicyManagementState
    if ($management.IsManaged -and -not $ForceManaged) {
        Write-Log "Domain or MDM management detected; local Group Policy reset skipped" -Level Warning
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess("local Group Policy stores", "reset and request gpupdate")) { return $false }
    Write-Log "=== LOCAL GROUP POLICY RESET ===" -Level Section
    foreach ($path in @(
        (Join-Path $env:WINDIR "System32\GroupPolicy"),
        (Join-Path $env:WINDIR "System32\GroupPolicyUsers")
    )) {
        if (Test-Path -LiteralPath $path) {
            $backupPath = "$path.RestoreBackup"
            try {
                if (Invoke-RestoreFileMutation -Action Move -Path $path -Destination $backupPath -Silent) { Write-Log "Moved local policy store to $(Split-Path $backupPath -Leaf)" -Level Success }
            } catch { Write-Log "Could not move local policy store $path" -Level Warning }
        }
    }
    $gpUpdate = Invoke-RestoreNativeCommand -FilePath "gpupdate.exe" -ArgumentList @("/force") -ExpectedExitCodes @(0) -Scope "Machine" -Silent
    if ($gpUpdate.Success -or $gpUpdate.Planned) { Write-Log "Local Group Policy reset requested; gpupdate completed" -Level Success }
    return $true
}

function Invoke-RestoreTier {
    param([ValidateSet("Quick","Full","Nuclear")][string]$Tier)
    $tierKeys = switch ($Tier) {
        "Quick" { @("chkDefender","chkFirewall","chkWindowsUpdate","chkServices","chkTasks") }
        "Full" { @("chkDefender","chkFirewall","chkSmartScreen","chkWindowsUpdate","chkUAC","chkSecurityUI","chkCrypto","chkNetwork","chkHostsFile","chkServices","chkTasks","chkFeatures","chkErrorReport","chkPrinting","chkMisc","chkPrivacy","chkCopilot","chkBing","chkCDM","chkBgApps","chkSync","chkNotifications","chkEnvVars","chkDevicePrivacy","chkTaskbar","chkExplorer","chkStartMenu","chkContextMenus","chkOOBE","chkEdge","chkChrome","chkOffice","chkOneDrive","chkNvidia","chk3rdParty","chkStoreChain","chkAccount","chkBluetooth","chkBiometrics","chkGaming","chkRemoteDesktop","chkAccessibility","chkInput","chkPower","chkMemory","chkStorage","chkInsider") }
        "Nuclear" { @("chkDefender","chkFirewall","chkSmartScreen","chkWindowsUpdate","chkUAC","chkSecurityUI","chkCrypto","chkNetwork","chkHostsFile","chkServices","chkTasks","chkFeatures","chkErrorReport","chkPrinting","chkMisc","chkPrivacy","chkCopilot","chkBing","chkCDM","chkBgApps","chkSync","chkNotifications","chkEnvVars","chkDevicePrivacy","chkTaskbar","chkExplorer","chkStartMenu","chkContextMenus","chkOOBE","chkEdge","chkChrome","chkOffice","chkOneDrive","chkNvidia","chk3rdParty","chkStoreChain","chkAccount","chkBluetooth","chkBiometrics","chkGaming","chkRemoteDesktop","chkAccessibility","chkInput","chkPower","chkMemory","chkStorage","chkInsider","chkAppx") }
    }
    return (Invoke-RestoreSelection -SelectedKeys $tierKeys -CreateRollbackSnapshot -AllowManagedPolicy:$script:ManagedPolicyOverrideRequested)
}

function Invoke-RemoteRestoreBatch {
    param(
        [Parameter(Mandatory=$true)][string[]]$ComputerName,
        [Parameter(Mandatory=$true)][string[]]$SelectedKeys,
        [Parameter(Mandatory=$true)][string]$ScriptPath,
        [pscredential]$Credential
    )
    $remoteBlock = {
        param($remoteScript,$keys)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $remoteScript -NoGui -RestoreCategories ($keys -join ',')
    }
    $invokeParams = @{ComputerName=$ComputerName;ScriptBlock=$remoteBlock;ArgumentList=$ScriptPath,@($SelectedKeys)}
    if ($Credential) { $invokeParams.Credential = $Credential }
    return @(Invoke-Command @invokeParams)
}

# ============================================================================
# HTML REPORT EXPORT
# ============================================================================

function Export-HtmlReport {
    param([string]$OutputPath)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $fixed   = @($script:CategoryResults.Values | Where-Object { $_.Status -eq "Fixed" }).Count
    $already = @($script:CategoryResults.Values | Where-Object { $_.Status -eq "Already OK" }).Count
    $errored = @($script:CategoryResults.Values | Where-Object { $_.Status -eq "Error" }).Count

    $rows = ""
    foreach ($cat in $script:CategoryResults.GetEnumerator()) {
        $statusColor = switch ($cat.Value.Status) {
            "Fixed" { "#3fb950" }
            "Already OK" { "#8b949e" }
            "Error" { "#f85149" }
            default { "#484f58" }
        }
        $statusLabel = switch ($cat.Value.Status) {
            "Fixed" { "FIXED" }
            "Already OK" { "OK" }
            "Error" { "FAILED" }
            default { "SKIPPED" }
        }
        $rows += "<tr>"
        $rows += "<td style='padding:8px 12px;border-bottom:1px solid #21262d;color:#c9d1d9;'>$($cat.Key)</td>"
        $rows += "<td style='padding:8px 12px;border-bottom:1px solid #21262d;color:$statusColor;font-weight:bold;'>$statusLabel</td>"
        $rows += "<td style='padding:8px 12px;border-bottom:1px solid #21262d;color:#8b949e;'>$($cat.Value.Changed) changes</td>"
        $rows += "<td style='padding:8px 12px;border-bottom:1px solid #21262d;color:$(if($cat.Value.Errors -gt 0){'#f85149'}else{'#8b949e'});'>$($cat.Value.Errors) errors</td>"
        $rows += "</tr>`n"
    }

    # Read the log file for detailed output
    $logContent = ""
    if (Test-Path $script:LogPath) {
        $logLines = Get-Content -Path $script:LogPath -EA 0
        foreach ($line in $logLines) {
            $escaped = [System.Net.WebUtility]::HtmlEncode($line)
            $color = "#8b949e"
            if ($escaped -match "\[Success\]") { $color = "#3fb950" }
            elseif ($escaped -match "\[Error\]") { $color = "#f85149" }
            elseif ($escaped -match "\[Warning\]") { $color = "#d29922" }
            elseif ($escaped -match "\[Section\]") { $color = "#bb86fc" }
            $logContent += "<div style='color:$color;margin:1px 0;'>$escaped</div>`n"
        }
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Windows Restore Tool - Report</title>
<style>
body { background:#0d1117; color:#c9d1d9; font-family:'Segoe UI',system-ui,sans-serif; margin:0; padding:20px; }
.header { background:#161b22; border:1px solid #30363d; border-radius:8px; padding:20px; margin-bottom:20px; }
.header h1 { color:#e6edf3; margin:0 0 4px 0; font-size:22px; }
.header p { color:#8b949e; margin:4px 0; font-size:13px; }
.badge { display:inline-block; background:#238636; color:white; padding:2px 8px; border-radius:10px; font-size:11px; font-weight:bold; margin-left:8px; }
.summary { display:flex; gap:16px; margin-bottom:20px; }
.summary-card { background:#161b22; border:1px solid #30363d; border-radius:8px; padding:16px; flex:1; text-align:center; }
.summary-card .number { font-size:28px; font-weight:bold; }
.summary-card .label { color:#8b949e; font-size:12px; margin-top:4px; }
.green { color:#3fb950; }
.gray { color:#8b949e; }
.red { color:#f85149; }
table { width:100%; border-collapse:collapse; background:#161b22; border:1px solid #30363d; border-radius:8px; overflow:hidden; margin-bottom:20px; }
th { background:#21262d; color:#8b949e; padding:10px 12px; text-align:left; font-size:12px; text-transform:uppercase; letter-spacing:0.5px; }
.log-section { background:#161b22; border:1px solid #30363d; border-radius:8px; padding:16px; }
.log-section h2 { color:#e6edf3; font-size:16px; margin:0 0 12px 0; }
.log-content { font-family:'Cascadia Mono','Consolas',monospace; font-size:11px; max-height:600px; overflow-y:auto; line-height:1.5; }
.footer { text-align:center; color:#484f58; font-size:11px; margin-top:20px; padding-top:16px; border-top:1px solid #21262d; }
</style>
</head>
<body>
<div class="header">
    <h1>Windows Restore Tool<span class="badge">v$($script:Version)</span></h1>
    <p>Report generated: $timestamp</p>
    <p>Computer: $env:COMPUTERNAME | User: $env:USERNAME | OS: $([System.Environment]::OSVersion.VersionString)</p>
</div>
<div class="summary">
    <div class="summary-card"><div class="number green">$fixed</div><div class="label">Categories Fixed</div></div>
    <div class="summary-card"><div class="number gray">$already</div><div class="label">Already OK</div></div>
    <div class="summary-card"><div class="number red">$errored</div><div class="label">Errors</div></div>
    <div class="summary-card"><div class="number" style="color:#58a6ff;">$($script:ChangesCount)</div><div class="label">Total Changes</div></div>
</div>
<table>
<thead><tr><th>Category</th><th>Status</th><th>Changes</th><th>Errors</th></tr></thead>
<tbody>
$rows
</tbody>
</table>
<div class="log-section">
    <h2>Detailed Log</h2>
    <div class="log-content">
$logContent
    </div>
</div>
<div class="footer">
    Windows Restore Tool v$($script:Version) - Generated by Restore-WindowsDefaults.ps1
</div>
</body>
</html>
"@

    try {
        [System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.Encoding]::UTF8)
        return $true
    } catch {
        return $false
    }
}

# ============================================================================
# GUI (100% static XAML - all dynamic content populated programmatically)
# ============================================================================

function Show-MainWindow {

    # ---- Run pre-scan ----
    $script:HealthReport = Get-SystemHealthReport
    $critCount  = @($script:HealthReport.Values | Where-Object { $_.Severity -eq "Critical" }).Count
    $highCount  = @($script:HealthReport.Values | Where-Object { $_.Severity -eq "High" }).Count
    $totalIssues = ($script:HealthReport.Values | ForEach-Object { $_.IssueCount } | Measure-Object -Sum).Sum

    if ($critCount -gt 0) { $hColor = "#f85149"; $hText = "CRITICAL - $totalIssues issues found ($critCount critical)" }
    elseif ($highCount -gt 0) { $hColor = "#d29922"; $hText = "WARNING - $totalIssues issues found" }
    elseif ($totalIssues -gt 0) { $hColor = "#58a6ff"; $hText = "$totalIssues minor issues found" }
    else { $hColor = "#3fb950"; $hText = "System looks healthy. No major issues detected." }

    # ---- Checkbox definitions ----
    $categories = @(
        @{K="chkDefender";L="Windows Defender";D="Re-enables antivirus, real-time scanning, updates, unblocks executables";On=$true;G="Security"}
        @{K="chkDefenderCpuCap";L="Defender CPU Cap";D="Removes an explicit scan CPU limit and returns scheduling to Windows defaults";On=$false;G="Security"}
        @{K="chkFirewall";L="Windows Firewall";D="Re-enables firewall on all network profiles, restores BFE service";On=$true;G="Security"}
        @{K="chkSmartScreen";L="SmartScreen Protection";D="Re-enables download/website safety checks in Windows and browsers";On=$true;G="Security"}
        @{K="chkWindowsUpdate";L="Windows Update";D="Restores update services, delivery optimization, re-registers components";On=$true;G="Security"}
        @{K="chkUAC";L="User Account Control";D="Restores admin elevation prompts (prevents silent installs)";On=$true;G="Security"}
        @{K="chkCrypto";L="TLS/SSL Security Protocols";D="Restores SCHANNEL, cipher suites, .NET crypto, and WinRM defaults";On=$true;G="Security"}
        @{K="chkSecurityUI";L="Windows Security App";D="Restores Security Center sections, tray icon, and VBS/Device Guard";On=$true;G="Security"}
        @{K="chkNetwork";L="Network and Internet";D="Fixes connectivity detection, DNS, NCSI, Wi-Fi, and proxy settings";On=$true;G="System"}
        @{K="chkHostsFile";L="Clean Hosts File Blocks";D="Removes domain blocks that break Windows Update, Store, and activation";On=$true;G="System"}
        @{K="chkServices";L="System Services (100+)";D="Re-enables critical services disabled by debloat scripts";On=$true;G="System"}
        @{K="chkTasks";L="Scheduled Tasks (80+)";D="Re-enables Windows maintenance, defrag, health, and update tasks";On=$true;G="System"}
        @{K="chkFeatures";L="Windows Features";D="Re-enables Print to PDF, PowerShell, Media Playback, and more";On=$true;G="System"}
        @{K="chkErrorReport";L="Error Reporting";D="Restores crash reporting and Windows Error Reporting service";On=$true;G="System"}
        @{K="chkPrinting";L="Printing";D="Restores Print Spooler service and print notification service";On=$true;G="System"}
        @{K="chkMisc";L="Misc System Policies";D="Snipping Tool, Copilot autolaunch, location, Maps, DEP";On=$true;G="System"}
        @{K="chkSearchIndexer";L="Rebuild Search Index";D="Restarts Windows Search and rebuilds its local index database";On=$false;G="System"}
        @{K="chkGroupPolicy";L="Reset Local Group Policy";D="Moves local policy stores to a backup and reapplies Windows defaults";On=$false;G="System"}
        @{K="chkClipboard";L="Clipboard History and Sync";D="Restores clipboard history and cross-device sync features";On=$true;G="System"}
        @{K="chkPrivacy";L="Privacy and Telemetry";D="Restores app permissions, diagnostics data collection, and tracking defaults";On=$true;G="Privacy"}
        @{K="chkCopilot";L="Copilot, Cortana and AI";D="Removes policy blocks on Windows AI and voice assistant features";On=$true;G="Privacy"}
        @{K="chkBing";L="Search and Web Results";D="Restores Bing search integration, web suggestions, and widgets";On=$true;G="Privacy"}
        @{K="chkCDM";L="App Suggestions and Ads";D="Restores Windows Spotlight, Start suggestions, and feature tips";On=$true;G="Privacy"}
        @{K="chkBgApps";L="Background Apps";D="Allows apps to refresh data, send notifications in the background";On=$true;G="Privacy"}
        @{K="chkSync";L="Settings Sync";D="Restores theme, password, language sync across your devices";On=$true;G="Privacy"}
        @{K="chkNotifications";L="Notifications";D="Restores toast notifications, lock screen alerts, and badge counts";On=$true;G="Privacy"}
        @{K="chkEnvVars";L="Developer Telemetry";D="Removes .NET CLI and PowerShell telemetry opt-out variables";On=$true;G="Privacy"}
        @{K="chkDevicePrivacy";L="Camera, Microphone and Bluetooth Privacy";D="Removes debloat policy locks from device privacy sliders";On=$true;G="Privacy"}
        @{K="chkTaskbar";L="Taskbar Layout";D="Restores Task View, Widgets, Chat, and People icons on taskbar";On=$true;G="LookFeel"}
        @{K="chkExplorer";L="File Explorer";D="Restores This PC folders, recent files, OneDrive icon, ribbon";On=$true;G="LookFeel"}
        @{K="chkStartMenu";L="Start Menu";D="Restores app tracking, recommendations, and layout suggestions";On=$true;G="LookFeel"}
        @{K="chkContextMenus";L="Right-Click Menus";D="Restores full context menus (undoes Win11 compact menu tweak)";On=$true;G="LookFeel"}
        @{K="chkOOBE";L="Setup Experience";D="Restores first-run experience and privacy consent prompts";On=$true;G="LookFeel"}
        @{K="chkTheme";L="Reset to Default Light Theme";D="Switches back to stock Windows light theme (cosmetic only)";On=$false;G="LookFeel"}
        @{K="chkEdge";L="Microsoft Edge";D="Removes group policies, restores updates, extensions, features";On=$true;G="Apps"}
        @{K="chkChrome";L="Chrome, Firefox and Google";D="Removes browser policies, restores updates and Software Reporter";On=$true;G="Apps"}
        @{K="chkOffice";L="Microsoft Office";D="Restores telemetry, feedback, and macro security defaults";On=$true;G="Apps"}
        @{K="chkOneDrive";L="OneDrive";D="Restores OneDrive integration, sidebar icon, and sync service";On=$true;G="Apps"}
        @{K="chkNvidia";L="NVIDIA Telemetry";D="Restores NVIDIA telemetry tasks and scheduled services";On=$true;G="Apps"}
        @{K="chk3rdParty";L="Third-Party App Services";D="Restores Adobe, Dropbox, Razer, Logitech, CCleaner, WMP services";On=$true;G="Apps"}
        @{K="chkAppx";L="Reinstall Removed Windows Apps";D="Tries to restore Calculator, Photos, Store, etc. May take 5+ min";On=$false;G="Apps"}
        @{K="chkStoreChain";L="Store and WinGet Services";D="Repairs Store licensing, AppX deployment, BITS, and WinGet dependencies";On=$true;G="Apps"}
        @{K="chkAccount";L="Account Sign-in Components";D="Repairs Microsoft account, Windows Hello, and token broker services without changing account type";On=$true;G="Apps"}
        @{K="chkBluetooth";L="Bluetooth";D="Restores Bluetooth services and audio gateway";On=$true;G="Hardware"}
        @{K="chkBiometrics";L="Biometrics (Windows Hello)";D="Restores fingerprint and face recognition service";On=$true;G="Hardware"}
        @{K="chkGaming";L="Gaming and Xbox";D="Restores Xbox services, Game Bar, and Game DVR";On=$true;G="Hardware"}
        @{K="chkRemoteDesktop";L="Remote Desktop";D="Restores RDP services for remote connections";On=$true;G="Hardware"}
        @{K="chkAccessibility";L="Accessibility";D="Restores tablet input, Ctrl+Alt+Del behavior";On=$true;G="Hardware"}
        @{K="chkInput";L="Input and Typing";D="Restores handwriting recognition, inking, and typing suggestions";On=$true;G="Hardware"}
        @{K="chkPower";L="Power and Hibernate";D="Re-enables hibernation and restores power settings";On=$true;G="Hardware"}
        @{K="chkMemory";L="Memory and Performance";D="Restores Prefetch, Superfetch, and pagefile settings";On=$true;G="Hardware"}
        @{K="chkStorage";L="Storage Sense";D="Restores automatic disk cleanup and Reserved Storage";On=$true;G="Hardware"}
        @{K="chkInsider";L="Windows Insider";D="Restores Insider service and preview build settings";On=$true;G="Hardware"}
    )
    $allChkNames = $categories | ForEach-Object { $_.K }

    $funcMap = Get-RestoreFunctionMap
    $script:RestoreFunctionMap = $funcMap
    $friendlyMap = @{}; $categories | ForEach-Object { $friendlyMap[$_.K] = $_.L }

    # ================================================================
    # STATIC XAML - single-quoted here-string prevents variable expansion
    # ================================================================
    $xamlString = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Restore Tool" Width="920" Height="740"
        WindowStartupLocation="CenterScreen" Background="#0d1117" ResizeMode="CanMinimize">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#21262d"/>
            <Setter Property="Foreground" Value="#e6edf3"/>
            <Setter Property="BorderBrush" Value="#30363d"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#30363d"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#c9d1d9"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Margin" Value="0,2"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid x:Name="pageHome">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="#161b22" Padding="20,14" BorderBrush="#30363d" BorderThickness="0,0,0,1">
                <StackPanel>
                    <StackPanel Orientation="Horizontal">
                        <TextBlock Text="Windows Restore Tool" FontSize="20" FontWeight="Bold" Foreground="#e6edf3"/>
                        <Border Background="#238636" CornerRadius="10" Padding="8,2" Margin="10,0" VerticalAlignment="Center">
                            <TextBlock Text="v4.4" FontSize="10" Foreground="White" FontWeight="SemiBold"/>
                        </Border>
                    </StackPanel>
                    <TextBlock Text="Fixes PCs broken by debloat scripts, privacy.sexy, and registry tweaks" Foreground="#8b949e" FontSize="12" Margin="0,3,0,0"/>
                </StackPanel>
            </Border>
            <Border Grid.Row="1" Background="#0d1117" Padding="20,10,20,6">
                <StackPanel>
                    <DockPanel Margin="0,0,0,6">
                        <TextBlock Text="System Scan" FontSize="13" FontWeight="SemiBold" Foreground="#c9d1d9" VerticalAlignment="Center"/>
                        <Button x:Name="btnImportManifest" Content="Import Manifest" DockPanel.Dock="Right" HorizontalAlignment="Right" Padding="10,4" FontSize="11"/>
                    </DockPanel>
                    <Border x:Name="quickScanPanel" Background="#161b22" CornerRadius="6" Padding="12,8" Margin="0,0,0,6" BorderBrush="#30363d" BorderThickness="1">
                        <WrapPanel x:Name="quickScanStats"/>
                    </Border>
                    <Border x:Name="manifestBanner" Background="#1a3070" CornerRadius="6" Padding="12,8" Margin="0,0,0,6" BorderBrush="#1f6feb" BorderThickness="1" Visibility="Collapsed">
                        <TextBlock x:Name="txtManifestSummary" Foreground="#58a6ff" FontSize="12" TextWrapping="Wrap"/>
                    </Border>
                    <Border Background="#161b22" CornerRadius="6" Padding="12,8" BorderBrush="#30363d" BorderThickness="1">
                        <StackPanel>
                            <TextBlock x:Name="txtHealthSummary" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,4"/>
                            <ScrollViewer MaxHeight="200" VerticalScrollBarVisibility="Auto">
                                <StackPanel x:Name="scanResults"/>
                            </ScrollViewer>
                            <TextBlock x:Name="txtScanHint" Foreground="#484f58" FontSize="10" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>
                </StackPanel>
            </Border>
            <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" Padding="20,10">
                <StackPanel>
                    <TextBlock Text="Choose how to fix your PC:" FontSize="13" FontWeight="SemiBold" Foreground="#c9d1d9" Margin="0,0,0,8"/>
                    <Border x:Name="btnFixAll" Background="#161b22" CornerRadius="8" Padding="16,12" Margin="0,0,0,6" BorderBrush="#238636" BorderThickness="2" Cursor="Hand">
                        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <StackPanel>
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="Recommended Fix" FontSize="15" FontWeight="Bold" Foreground="#3fb950"/>
                                    <Border Background="#238636" CornerRadius="3" Padding="6,1" Margin="8,0" VerticalAlignment="Center">
                                        <TextBlock Text="SAFE" FontSize="9" Foreground="White" FontWeight="Bold"/></Border>
                                </StackPanel>
                                <TextBlock TextWrapping="Wrap" Foreground="#8b949e" FontSize="11" Margin="0,3,0,0" Text="Restores all security, services, and system defaults. Keeps your dark theme. Does NOT reinstall removed apps."/>
                            </StackPanel>
                            <TextBlock Grid.Column="1" Text="&#xBB;" FontSize="24" Foreground="#3fb950" VerticalAlignment="Center" Margin="12,0,0,0"/>
                        </Grid>
                    </Border>
                    <Border x:Name="btnFixDetected" Background="#161b22" CornerRadius="8" Padding="16,12" Margin="0,0,0,6" BorderBrush="#d29922" BorderThickness="1" Cursor="Hand">
                        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <StackPanel>
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="Fix Detected Issues Only" FontSize="15" FontWeight="Bold" Foreground="#d29922"/>
                                    <Border Background="#4a3000" CornerRadius="3" Padding="6,1" Margin="8,0" VerticalAlignment="Center">
                                        <TextBlock x:Name="txtDetectedCount" FontSize="9" Foreground="#d29922" FontWeight="Bold"/></Border>
                                </StackPanel>
                                <TextBlock TextWrapping="Wrap" Foreground="#8b949e" FontSize="11" Margin="0,3,0,0" Text="Only fixes the specific problems found by the scanner. Click any scan item above for details."/>
                            </StackPanel>
                            <TextBlock Grid.Column="1" Text="&#xBB;" FontSize="24" Foreground="#d29922" VerticalAlignment="Center" Margin="12,0,0,0"/>
                        </Grid>
                    </Border>
                    <Border x:Name="btnFixSecurity" Background="#161b22" CornerRadius="8" Padding="16,12" Margin="0,0,0,6" BorderBrush="#30363d" BorderThickness="1" Cursor="Hand">
                        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <StackPanel>
                                <TextBlock Text="Security Only" FontSize="15" FontWeight="Bold" Foreground="#58a6ff"/>
                                <TextBlock TextWrapping="Wrap" Foreground="#8b949e" FontSize="11" Margin="0,3,0,0" Text="Only fixes Defender, Firewall, SmartScreen, Windows Update, UAC, and security protocols."/>
                            </StackPanel>
                            <TextBlock Grid.Column="1" Text="&#xBB;" FontSize="24" Foreground="#58a6ff" VerticalAlignment="Center" Margin="12,0,0,0"/>
                        </Grid>
                    </Border>
                    <Border x:Name="btnCustom" Background="#161b22" CornerRadius="8" Padding="16,12" Margin="0,0,0,6" BorderBrush="#30363d" BorderThickness="1" Cursor="Hand">
                        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <StackPanel>
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="Custom" FontSize="15" FontWeight="Bold" Foreground="#8b949e"/>
                                    <Border Background="#1a3070" CornerRadius="3" Padding="6,1" Margin="8,0" VerticalAlignment="Center">
                                        <TextBlock Text="ADVANCED" FontSize="9" Foreground="#58a6ff" FontWeight="Bold"/></Border>
                                </StackPanel>
                                <TextBlock TextWrapping="Wrap" Foreground="#8b949e" FontSize="11" Margin="0,3,0,0" Text="Pick exactly what to restore from 47 categories. Full control over every setting."/>
                            </StackPanel>
                            <TextBlock Grid.Column="1" Text="&#xBB;" FontSize="24" Foreground="#8b949e" VerticalAlignment="Center" Margin="12,0,0,0"/>
                        </Grid>
                    </Border>
                    <Border x:Name="btnScanOnly" Background="#0d1117" CornerRadius="8" Padding="16,8" Margin="0,4,0,0" BorderBrush="#21262d" BorderThickness="1" Cursor="Hand">
                        <TextBlock HorizontalAlignment="Center" Foreground="#8b949e" FontSize="12" Text="Preview Only - Show what would change without changing anything"/>
                    </Border>
                </StackPanel>
            </ScrollViewer>
            <Border Grid.Row="3" Background="#161b22" Padding="14,8" BorderBrush="#30363d" BorderThickness="0,1,0,0">
                <DockPanel>
                    <CheckBox x:Name="chkAutoRestore" Content="Create a restore point first (strongly recommended)" IsChecked="True" DockPanel.Dock="Left" VerticalAlignment="Center"/>
                    <Button x:Name="btnClose" Content="Exit" DockPanel.Dock="Right" HorizontalAlignment="Right" Padding="16,6"/>
                </DockPanel>
            </Border>
        </Grid>
        <Grid x:Name="pageCustom" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border Grid.Row="0" Background="#161b22" Padding="14,10" BorderBrush="#30363d" BorderThickness="0,0,0,1">
                <DockPanel>
                    <Button x:Name="btnBack" Content="&#x2190; Back" DockPanel.Dock="Left" Padding="10,5" FontSize="12"/>
                    <TextBlock Text="  Custom Restoration" FontSize="15" FontWeight="SemiBold" Foreground="#e6edf3" VerticalAlignment="Center"/>
                    <StackPanel Orientation="Horizontal" DockPanel.Dock="Right" HorizontalAlignment="Right">
                        <Button x:Name="btnSelectAll" Content="All" Padding="8,4" FontSize="11" Margin="0,0,4,0"/>
                        <Button x:Name="btnSelectNone" Content="None" Padding="8,4" FontSize="11" Margin="0,0,4,0"/>
                        <Button x:Name="btnSelectSafe" Content="Safe Defaults" Padding="8,4" FontSize="11"/>
                    </StackPanel>
                </DockPanel>
            </Border>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="16,0,16,8">
                <StackPanel x:Name="chkContainer"/>
            </ScrollViewer>
            <Border Grid.Row="2" Background="#161b22" Padding="14,8" BorderBrush="#30363d" BorderThickness="0,1,0,0">
                <DockPanel>
                    <CheckBox x:Name="chkAutoRestoreC" Content="Create restore point first" IsChecked="True" DockPanel.Dock="Left" VerticalAlignment="Center"/>
                    <Button x:Name="btnScheduleCustom" Content="Schedule Next Reboot" DockPanel.Dock="Right" HorizontalAlignment="Right" Padding="12,8" Margin="0,0,6,0"/>
                    <Button x:Name="btnRunCustom" DockPanel.Dock="Right" HorizontalAlignment="Right" Padding="16,8" Background="#238636" Foreground="White" BorderBrush="#238636">
                        <TextBlock Text="Run Selected Fixes" FontWeight="SemiBold"/></Button>
                </DockPanel>
            </Border>
        </Grid>
        <Grid x:Name="pageProgress" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border Grid.Row="0" Background="#161b22" Padding="20,14" BorderBrush="#30363d" BorderThickness="0,0,0,1">
                <StackPanel>
                    <TextBlock x:Name="txtProgressTitle" Text="Restoring Windows defaults..." FontSize="18" FontWeight="Bold" Foreground="#e6edf3"/>
                    <TextBlock x:Name="txtProgressSub" Text="Do not close this window" Foreground="#8b949e" FontSize="12" Margin="0,3,0,0"/>
                </StackPanel>
            </Border>
            <Border Grid.Row="1" Background="#0d1117" Padding="20,8">
                <StackPanel>
                    <ProgressBar x:Name="progressBar" Height="6" Minimum="0" Maximum="100" Value="0" Background="#21262d" Foreground="#238636" BorderThickness="0"/>
                    <Slider x:Name="timelineScrubber" Minimum="1" Maximum="1" Value="1" TickFrequency="1" IsSnapToTickEnabled="True" Visibility="Collapsed" IsEnabled="False" Margin="0,6,0,0"/>
                    <DockPanel Margin="0,4,0,0">
                        <TextBlock x:Name="txtProgressPercent" Text="0%" Foreground="#8b949e" FontSize="11"/>
                        <TextBlock x:Name="txtProgressStep" Text="" Foreground="#484f58" FontSize="11" DockPanel.Dock="Right" HorizontalAlignment="Right"/>
                    </DockPanel>
                </StackPanel>
            </Border>
            <Border Grid.Row="2" Background="#0d1117" Padding="20,4,20,8">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Border Grid.Row="0" x:Name="categoryResultsPanel" Visibility="Collapsed" Background="#161b22" CornerRadius="6" Padding="8,6" Margin="0,0,0,6" BorderBrush="#30363d" BorderThickness="1">
                        <ScrollViewer MaxHeight="120" VerticalScrollBarVisibility="Auto">
                            <WrapPanel x:Name="categoryResultsList"/>
                        </ScrollViewer>
                    </Border>
                <Border Grid.Row="1" Background="#161b22" CornerRadius="6" Padding="2" BorderBrush="#30363d" BorderThickness="1">
                    <RichTextBox x:Name="txtConsole" IsReadOnly="True" Background="Transparent" BorderThickness="0"
                                 FontFamily="Cascadia Mono,Consolas,Courier New" FontSize="11"
                                 VerticalScrollBarVisibility="Auto" Padding="6">
                        <RichTextBox.Resources><Style TargetType="Paragraph"><Setter Property="Margin" Value="0"/></Style></RichTextBox.Resources>
                        <FlowDocument/>
                    </RichTextBox>
                </Border>
                </Grid>
            </Border>
            <Border Grid.Row="3" Background="#161b22" Padding="14,8" BorderBrush="#30363d" BorderThickness="0,1,0,0">
                <DockPanel>
                    <TextBlock x:Name="txtStatus" Text="" Foreground="#8b949e" FontSize="11" VerticalAlignment="Center"/>
                    <StackPanel Orientation="Horizontal" DockPanel.Dock="Right" HorizontalAlignment="Right">
                        <Button x:Name="btnReboot" Visibility="Collapsed" Padding="14,8" Background="#238636" Foreground="White" BorderBrush="#238636">
                            <TextBlock Text="Reboot Now" FontWeight="SemiBold"/></Button>
                        <Button x:Name="btnLater" Content="Close (Reboot Later)" Visibility="Collapsed" Padding="14,8" Margin="6,0,0,0"/>
                        <Button x:Name="btnRollback" Content="Rollback This Run" Visibility="Collapsed" Padding="14,8" Margin="6,0,0,0"/>
                        <Button x:Name="btnExportReport" Content="Export Report" Visibility="Collapsed" Padding="14,8" Margin="6,0,0,0"/>
                        <Button x:Name="btnViewLog" Content="Open Log File" Visibility="Collapsed" Padding="14,8" Margin="6,0,0,0"/>
                    </StackPanel>
                </DockPanel>
            </Border>
        </Grid>
    </Grid>
</Window>
'@

    # ---- Load window using Parse() which properly registers NameScope ----
    try {
        $window = [System.Windows.Markup.XamlReader]::Parse($xamlString)
# codex-branding:start
                try {
                    $brandingIconPath = Join-Path $PSScriptRoot 'icon.ico'
                    if (Test-Path $brandingIconPath) {
                        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri($brandingIconPath)))
                    }
                } catch {
                }
                # codex-branding:end
    } catch {
        [System.Windows.MessageBox]::Show("UI failed to load: $($_.Exception.Message)", "Error", "OK", "Error")
        return
    }

    # ---- Find named controls ----
    # With XamlReader.Parse(), FindName works correctly
    $ui = @{}
    $controlNames = @(
        'pageHome', 'pageCustom', 'pageProgress',
        'txtHealthSummary', 'scanResults', 'txtScanHint', 'txtDetectedCount',
        'btnFixAll', 'btnFixDetected', 'btnFixSecurity', 'btnCustom', 'btnScanOnly',
        'chkAutoRestore', 'btnClose',
        'btnBack', 'btnSelectAll', 'btnSelectNone', 'btnSelectSafe',
        'chkContainer', 'chkAutoRestoreC', 'btnRunCustom', 'btnScheduleCustom',
        'txtProgressTitle', 'txtProgressSub', 'progressBar', 'timelineScrubber', 'txtProgressPercent', 'txtProgressStep',
        'txtConsole', 'txtStatus', 'btnReboot', 'btnLater', 'btnRollback', 'btnViewLog',
        'btnImportManifest', 'quickScanPanel', 'quickScanStats',
        'manifestBanner', 'txtManifestSummary',
        'categoryResultsPanel', 'categoryResultsList',
        'btnExportReport'
    )
    foreach ($name in $controlNames) {
        $ctrl = $window.FindName($name)
        if ($ctrl) { $ui[$name] = $ctrl }
    }
    $script:ConsoleBox = $ui.txtConsole
    $script:ConsoleWindow = $window
    $ui.timelineScrubber.Add_ValueChanged({
        if ($script:RestoreTimelineLabels -and $script:RestoreTimelineLabels.Count -gt 0) {
            $timelineIndex = [Math]::Max(0, [Math]::Min($script:RestoreTimelineLabels.Count - 1, [Math]::Round($ui.timelineScrubber.Value) - 1))
            $timelineKey = $script:RestoreTimelineKeys[$timelineIndex]
            $timelineLabel = $script:RestoreTimelineLabels[$timelineIndex]
            $timelineStatus = $script:RestoreTimelineResults[$timelineKey]
            if (-not $timelineStatus) { $timelineStatus = "Pending" }
            $ui.txtProgressStep.Text = "Timeline: $timelineLabel - $timelineStatus"
        }
    })

    # ================================================================
    # POPULATE ALL DYNAMIC CONTENT PROGRAMMATICALLY (safe from XML)
    # ================================================================
    $bc = [System.Windows.Media.BrushConverter]::new()

    # Health summary
    $ui.txtHealthSummary.Text = $hText
    $ui.txtHealthSummary.Foreground = $bc.ConvertFromString($hColor)

    # ---- Quick scan summary panel ----
    $quickScan = Get-QuickScanSummary
    $quickStats = @(
        @{Count=$quickScan.DisabledServices; Label="services disabled"; Color=if($quickScan.DisabledServices){"#d29922"}else{"#3fb950"}},
        @{Count=$quickScan.DisabledTasks; Label="tasks disabled"; Color=if($quickScan.DisabledTasks){"#d29922"}else{"#3fb950"}},
        @{Count=$quickScan.MissingAppx; Label="apps missing"; Color=if($quickScan.MissingAppx){"#58a6ff"}else{"#3fb950"}},
        @{Count=$quickScan.ModifiedRegistry; Label="registry modified"; Color=if($quickScan.ModifiedRegistry){"#d29922"}else{"#3fb950"}}
    )
    foreach ($qs in $quickStats) {
        $statBorder = New-Object System.Windows.Controls.Border
        $statBorder.Margin = [System.Windows.Thickness]::new(0,0,12,0)
        $statBorder.Padding = [System.Windows.Thickness]::new(0)
        $statSP = New-Object System.Windows.Controls.StackPanel
        $statSP.Orientation = "Horizontal"
        $countTB = New-Object System.Windows.Controls.TextBlock
        $countTB.Text = "$($qs.Count)"
        $countTB.FontSize = 14; $countTB.FontWeight = "Bold"
        $countTB.Foreground = $bc.ConvertFromString($qs.Color)
        $countTB.VerticalAlignment = "Center"
        $statSP.Children.Add($countTB) | Out-Null
        $labelTB = New-Object System.Windows.Controls.TextBlock
        $labelTB.Text = " $($qs.Label)"
        $labelTB.FontSize = 11
        $labelTB.Foreground = $bc.ConvertFromString("#8b949e")
        $labelTB.VerticalAlignment = "Center"
        $statSP.Children.Add($labelTB) | Out-Null
        $statBorder.Child = $statSP
        $ui.quickScanStats.Children.Add($statBorder) | Out-Null
    }

    # ---- Manifest import state ----
    $script:ImportedManifest = $null

    # Scan results
    $sevOrder = @{Critical=0;High=1;Medium=2;Low=3;OK=4}
    $sevColors = @{Critical="#f85149";High="#d29922";Medium="#58a6ff";Low="#8b949e";OK="#3fb950"}
    $sevLabels = @{Critical="CRITICAL";High="WARNING";Medium="CHANGED";Low="NOTICE";OK="OK"}

    $issueCategories = @()
    $script:HealthReport.GetEnumerator() | Sort-Object { $sevOrder[$_.Value.Severity] } | ForEach-Object {
        $cat = $_.Value; $sev = $cat.Severity
        if ($cat.IssueCount -gt 0) { $issueCategories += $_ }

        $row = New-Object System.Windows.Controls.Border
        $row.Margin = [System.Windows.Thickness]::new(0,2,0,0)
        $row.Padding = [System.Windows.Thickness]::new(10,5,10,5)
        $row.CornerRadius = [System.Windows.CornerRadius]::new(4)
        if ($sev -ne "OK") {
            $row.Background = $bc.ConvertFromString("#161b22")
            $row.Cursor = [System.Windows.Input.Cursors]::Hand
        }

        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = "Horizontal"

        # Severity badge
        $badge = New-Object System.Windows.Controls.Border
        $badge.Background = $bc.ConvertFromString($sevColors[$sev])
        $badge.CornerRadius = [System.Windows.CornerRadius]::new(3)
        $badge.Padding = [System.Windows.Thickness]::new(6,1,6,1)
        $badge.Margin = [System.Windows.Thickness]::new(0,0,8,0)
        $badge.VerticalAlignment = "Center"; $badge.MinWidth = 58
        $bt = New-Object System.Windows.Controls.TextBlock
        $bt.Text = $sevLabels[$sev]; $bt.Foreground = $bc.ConvertFromString("White")
        $bt.FontSize = 10; $bt.FontWeight = "Bold"; $bt.HorizontalAlignment = "Center"
        $badge.Child = $bt
        $sp.Children.Add($badge) | Out-Null

        # Category name + summary
        $txt = New-Object System.Windows.Controls.TextBlock
        $txt.FontSize = 12; $txt.VerticalAlignment = "Center"
        $nameRun = New-Object System.Windows.Documents.Run($cat.FriendlyName)
        $nameRun.FontWeight = "SemiBold"
        $nameRun.Foreground = $bc.ConvertFromString($(if($sev -ne "OK"){"#c9d1d9"}else{"#484f58"}))
        $txt.Inlines.Add($nameRun) | Out-Null

        if ($cat.IssueCount -gt 0) {
            $sumText = " - $($cat.Issues[0])"
            if ($cat.IssueCount -gt 1) { $sumText += " (+$($cat.IssueCount-1) more)" }
            $sumRun = New-Object System.Windows.Documents.Run($sumText)
            $sumRun.Foreground = $bc.ConvertFromString("#8b949e")
            $txt.Inlines.Add($sumRun) | Out-Null
            # Click hint
            $hintRun = New-Object System.Windows.Documents.Run("  [details]")
            $hintRun.Foreground = $bc.ConvertFromString("#58a6ff"); $hintRun.FontSize = 10
            $txt.Inlines.Add($hintRun) | Out-Null
        }
        $sp.Children.Add($txt) | Out-Null
        $row.Child = $sp

        # Click handler for detail popup
        if ($cat.IssueCount -gt 0) {
            $detailLines = @("$($cat.FriendlyName) - $($cat.IssueCount) issue(s) found:", "")
            foreach ($d in $cat.Details) { $detailLines += "  - $d" }
            $row.Tag = ($detailLines -join "`n")
            $row.Add_MouseLeftButtonUp({ param($s,$e)
                [System.Windows.MessageBox]::Show($s.Tag, "Scan Details", "OK", "Information")
            })
        }

        $ui.scanResults.Children.Add($row) | Out-Null
    }

    # Scan hint and detected count
    if ($totalIssues -gt 0) {
        $ui.txtScanHint.Text = "Click any highlighted item to see exactly what was changed"
    } else {
        $ui.txtScanHint.Text = ""
    }
    $ui.txtDetectedCount.Text = "$totalIssues found"

    # Build detected fix keys
    $detectedKeys = @()
    foreach ($c in $script:HealthReport.Values) {
        if ($c.IssueCount -gt 0 -and $c.FixKeys) { $detectedKeys += $c.FixKeys }
    }
    $detectedKeys = @($detectedKeys | Select-Object -Unique)

    # ---- Build custom page checkboxes programmatically ----
    $groupMeta = [ordered]@{
        Security = @{Label="CRITICAL SECURITY"; Color="#f85149"; Desc="Protects your PC from viruses, hackers, and unsafe software"}
        System   = @{Label="SYSTEM FUNCTIONALITY"; Color="#d29922"; Desc="Core Windows services and features that keep your PC running"}
        Privacy  = @{Label="PRIVACY AND PERSONALIZATION"; Color="#58a6ff"; Desc="Data collection, app permissions, and personalization features"}
        LookFeel = @{Label="LOOK AND FEEL"; Color="#8b949e"; Desc="Taskbar, Start menu, Explorer, and visual customization"}
        Apps     = @{Label="APPS AND BROWSERS"; Color="#8b949e"; Desc="Browser settings, Office, OneDrive, and third-party app policies"}
        Hardware = @{Label="HARDWARE AND DEVICES"; Color="#8b949e"; Desc="Bluetooth, biometrics, gaming, power, storage, and input devices"}
    }

    foreach ($grp in $groupMeta.GetEnumerator()) {
        # Group header
        $header = New-Object System.Windows.Controls.TextBlock
        $header.Margin = [System.Windows.Thickness]::new(0,8,0,2)
        $r1 = New-Object System.Windows.Documents.Run($grp.Value.Label)
        $r1.FontSize = 11; $r1.FontWeight = "Bold"; $r1.Foreground = $bc.ConvertFromString($grp.Value.Color)
        $header.Inlines.Add($r1) | Out-Null
        $r2 = New-Object System.Windows.Documents.Run("  $($grp.Value.Desc)")
        $r2.FontSize = 10; $r2.Foreground = $bc.ConvertFromString("#484f58")
        $header.Inlines.Add($r2) | Out-Null
        $ui.chkContainer.Children.Add($header) | Out-Null

        # Group border with WrapPanel
        $grpBorder = New-Object System.Windows.Controls.Border
        $grpBorder.Background = $bc.ConvertFromString("#161b22")
        $grpBorder.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $grpBorder.Padding = [System.Windows.Thickness]::new(12,6,12,6)
        $grpBorder.Margin = [System.Windows.Thickness]::new(0,0,0,4)
        $wp = New-Object System.Windows.Controls.WrapPanel

        $grpItems = $categories | Where-Object { $_.G -eq $grp.Key }
        foreach ($cat in $grpItems) {
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.Width = 264; $sp.Margin = [System.Windows.Thickness]::new(0,3,8,3)

            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $cat.L; $cb.IsChecked = $cat.On
            $cb.Foreground = $bc.ConvertFromString($(if($cat.On){"#c9d1d9"}else{"#8b949e"}))
            $cb.FontSize = 12; $cb.Cursor = [System.Windows.Input.Cursors]::Hand
            $sp.Children.Add($cb) | Out-Null

            $desc = New-Object System.Windows.Controls.TextBlock
            $desc.Text = $cat.D; $desc.FontSize = 10; $desc.TextWrapping = "Wrap"
            $desc.Margin = [System.Windows.Thickness]::new(20,0,0,0)
            $desc.Foreground = $bc.ConvertFromString($(if($cat.K -eq "chkAppx"){"#d29922"}else{"#6e7681"}))
            $sp.Children.Add($desc) | Out-Null

            $wp.Children.Add($sp) | Out-Null
            $ui[$cat.K] = $cb   # Store checkbox reference
        }

        $grpBorder.Child = $wp
        $ui.chkContainer.Children.Add($grpBorder) | Out-Null
    }

    # ================================================================
    # PRESETS AND RUN LOGIC
    # ================================================================
    $securityOnly = @("chkDefender","chkFirewall","chkSmartScreen","chkWindowsUpdate","chkUAC","chkSecurityUI","chkCrypto")
    $managementState = Get-PolicyManagementState
    $script:ManagedMode = $managementState.IsManaged
    $safeDefaults = $allChkNames | Where-Object { $_ -ne "chkTheme" -and $_ -ne "chkAppx" -and $_ -ne "chkSearchIndexer" -and $_ -ne "chkDefenderCpuCap" -and $_ -ne "chkGroupPolicy" }
    if ($managementState.IsManaged) { $safeDefaults = @($safeDefaults | Where-Object { $_ -notin @("chkSync","chkOneDrive","chkAccount") }) }

    $runRestore = {
        param($selectedKeys, $doRestorePoint, $scanOnlyMode)
        $ui.pageHome.Visibility = "Collapsed"
        $ui.pageCustom.Visibility = "Collapsed"
        $ui.pageProgress.Visibility = "Visible"
        $script:RestoreTimelineKeys = @($selectedKeys)
        $script:RestoreTimelineLabels = @($selectedKeys | ForEach-Object { $friendlyMap[$_] })
        $script:RestoreTimelineResults = @{}
        $capabilityEvaluations = @(Get-RestoreCapabilityEvaluation -SelectedKeys $selectedKeys -MachineProfile $script:CapabilityProfile -AllowManagedPolicy:$script:ManagedPolicyOverrideRequested)
        $capabilityMap = @{}
        foreach ($capabilityEvaluation in $capabilityEvaluations) { $capabilityMap[$capabilityEvaluation.Key] = $capabilityEvaluation }
        $runnableKeys = @($capabilityEvaluations | Where-Object CanMutate | ForEach-Object Key)
        foreach ($blockedCapability in @($capabilityEvaluations | Where-Object { -not $_.CanMutate })) {
            Write-Log "Capability gate: $($blockedCapability.Key) will not run - $($blockedCapability.Reason)" -Level Warning
        }
        $actionPlan = Get-RestoreActionPlan -SelectedKeys $selectedKeys -HealthReport $script:HealthReport -MachineProfile $script:CapabilityProfile -AllowManagedPolicy:$script:ManagedPolicyOverrideRequested -CreateRestorePoint:(($doRestorePoint -and -not $scanOnlyMode))
        $rollbackJournal = $null

        if ($scanOnlyMode) {
            $ui.txtProgressTitle.Text = "Scanning (preview mode)..."
            $ui.txtProgressSub.Text = "No changes will be made"
        }
        $window.Dispatcher.Invoke([action]{}, "Render")

        if (-not $scanOnlyMode -and $runnableKeys.Count -gt 0) {
            try {
                $journalPath = New-RestoreRollbackJournal -ActionPlan $actionPlan -SelectedKeys $runnableKeys
                if (-not $journalPath) { throw "journal write was skipped" }
                $rollbackJournal = $script:ActiveRollbackJournal
            } catch {
                Write-Log "Could not create rollback journal: $($_.Exception.Message)" -Level Error
                $ui.txtStatus.Text = "Restore stopped before any changes: rollback journal unavailable"
                $ui.btnLater.Content = "Close"; $ui.btnLater.Visibility = "Visible"
                $window.Dispatcher.Invoke([action]{}, "Render")
                return
            }
        }

        # Restore point is an explicit operation in the same versioned plan.
        if ($doRestorePoint -and !$scanOnlyMode -and $runnableKeys.Count -gt 0) {
            $ui.txtProgressSub.Text = "Creating restore point..."
            $window.Dispatcher.Invoke([action]{}, "Render")
            $restorePointResult = Invoke-RestoreActionPlan -ActionPlan $actionPlan -CategoryKey "__run"
            if ($restorePointResult.Errors -gt 0) { Write-Log "Could not create restore point; continuing with the planned restore" -Level Warning }
            elseif ($restorePointResult.Changed -gt 0) { Write-Log "Restore point created successfully" -Level Success }
            $ui.txtProgressSub.Text = "Do not close this window"
            $window.Dispatcher.Invoke([action]{}, "Render")
        }

        $mode = if ($scanOnlyMode) { "PREVIEW" } else { "RESTORE" }
        Write-Log "=== Windows Restore Tool v$($script:Version) - $mode MODE ===" -Level Section
        Write-Log "User: $env:USERNAME | Computer: $env:COMPUTERNAME | OS: $([System.Environment]::OSVersion.VersionString)" -Level Info
        Write-Log "Categories selected: $($selectedKeys.Count)" -Level Info
        Write-Log "" -Level Info

        if ($scanOnlyMode) {
            Write-Log "PREVIEW MODE: No actual changes will be made." -Level Section
            Write-Log "" -Level Info
            Write-Log "Action plan: $($actionPlan.Status); exact operations $($actionPlan.ExactOperationCount); review-required operations $($actionPlan.OpaqueOperationCount); plan hash $($actionPlan.PlanHash)" -Level Section
            foreach ($operation in @($actionPlan.Operations | Where-Object { $_.Exact })) {
                $operationLabel = if ($operation.Action -eq "NoOp") { "No change" } else { $operation.Action }
                Write-Log "$operationLabel $($operation.Target) [$($operation.Scope)]" -Level Info
            }
            if ($actionPlan.OpaqueOperationCount -gt 0) {
                Write-Log "Some category mutations still require review because they are not represented as individual plan operations." -Level Warning
            }
            $impactPreview = @(Get-RestoreImpactPreview -SelectedKeys $selectedKeys -HealthReport $script:HealthReport)
            Write-Log "Pre-flight impact preview:" -Level Section
            foreach ($impact in $impactPreview) {
                $impactLabel = $friendlyMap[$impact.FixKey]; if (-not $impactLabel) { $impactLabel = $impact.FixKey }
                Write-Log "$impactLabel - $($impact.DetectedIssueCount) detected issue(s), $($impact.DetailCount) detail(s), severity $($impact.Severity), capability $($impact.CapabilityStatus)" -Level Info
                if (-not $impact.CanMutate) { Write-Log "  Capability gate reason: $($impact.CapabilityReason)" -Level Warning }
            }
            Write-Log "" -Level Info
            foreach ($key in $selectedKeys) {
                $fn = $friendlyMap[$key]; if (!$fn) { $fn = $key }
                $capability = $capabilityMap[$key]
                if ($capability -and $capability.CanMutate) { Write-Log "Would restore: $fn" -Level Info }
                else { Write-Log "Would skip: $fn - $($capability.Reason)" -Level Warning }
            }
            Write-Log "" -Level Info
            Write-Log "=== PREVIEW COMPLETE ===" -Level Section
            $ui.txtProgressTitle.Text = "Preview complete"
            $ui.txtProgressSub.Text = "$($selectedKeys.Count) categories would be restored"
            $ui.progressBar.Value = $ui.progressBar.Maximum
            $ui.txtProgressPercent.Text = "Done"
            $ui.txtStatus.Text = "No changes were made (preview only)"
            $ui.btnLater.Content = "Close"; $ui.btnLater.Visibility = "Visible"
            $ui.btnViewLog.Visibility = "Visible"
            $window.Dispatcher.Invoke([action]{}, "Render")
            return
        }

        # ---- ACTUAL RESTORATION ----
        $ui.progressBar.Maximum = $selectedKeys.Count
        $ui.timelineScrubber.Minimum = 1
        $ui.timelineScrubber.Maximum = [Math]::Max(1, $selectedKeys.Count)
        $ui.timelineScrubber.Value = 1
        $ui.timelineScrubber.Visibility = "Visible"
        $ui.timelineScrubber.IsEnabled = $true
        $ui.categoryResultsPanel.Visibility = "Visible"
        $total = $selectedKeys.Count; $i = 0

        # Pre-populate SKIPPED indicators for unchecked categories
        foreach ($ak in $allChkNames) {
            if ($ak -notin $selectedKeys) {
                $skFn = $friendlyMap[$ak]; if (!$skFn) { $skFn = $ak }
                $skSP = New-Object System.Windows.Controls.StackPanel
                $skSP.Orientation = "Horizontal"
                $skSP.Margin = [System.Windows.Thickness]::new(0,2,10,2)
                $skLabel = New-Object System.Windows.Controls.TextBlock
                $skLabel.Text = "$skFn "; $skLabel.FontSize = 10
                $skLabel.Foreground = $bc.ConvertFromString("#484f58")
                $skSP.Children.Add($skLabel) | Out-Null
                $skStatus = New-Object System.Windows.Controls.TextBlock
                $skStatus.Text = "SKIPPED"; $skStatus.FontSize = 10; $skStatus.FontWeight = "Bold"
                $skStatus.Foreground = $bc.ConvertFromString("#484f58")
                $skSP.Children.Add($skStatus) | Out-Null
                $ui.categoryResultsList.Children.Add($skSP) | Out-Null
            }
        }

        foreach ($key in $selectedKeys) {
            $i++
            $fn = $friendlyMap[$key]; if (!$fn) { $fn = $key }
            $pct = [math]::Round(($i / $total) * 100)
            $ui.progressBar.Value = $i
            $ui.txtProgressPercent.Text = "$pct%"
            $ui.txtProgressStep.Text = "($i of $total) $fn"
            $ui.txtProgressSub.Text = "Fixing: $fn"
            $window.Dispatcher.Invoke([action]{}, "Render")

            $script:CurrentCategory = $fn
            $script:CategoryResults[$fn] = @{ Status="OK"; Changed=0; Errors=0 }
            $capability = $capabilityMap[$key]
            if (-not $capability -or -not $capability.CanMutate) {
                $script:CategoryResults[$fn].Status = "Skipped"
                $script:CategoryResults[$fn].Reason = if ($capability) { $capability.Reason } else { "Category is not declared in the capability catalog" }
            } else {
                try {
                    $categoryPlan = @($actionPlan.Categories | Where-Object { $_.Key -eq $key } | Select-Object -First 1)
                    if ($categoryPlan.Count -ne 1 -or $categoryPlan[0].Status -ne "Ready") {
                        $script:CategoryResults[$fn].Status = "Skipped"
                        $script:CategoryResults[$fn].Reason = if($categoryPlan.Count -eq 1){"Action plan requires review: $($categoryPlan[0].Status)"}else{"Action plan category is missing"}
                        Write-Log "Skipped $fn because its action plan is not executable: $($script:CategoryResults[$fn].Reason)" -Level Warning
                    } else {
                        $planResult = Invoke-RestoreActionPlan -ActionPlan $actionPlan -CategoryKey $key
                        $script:CategoryResults[$fn].Changed = [int]$planResult.Changed
                        $script:CategoryResults[$fn].Errors = [int]$planResult.Errors
                    }
                    if ($script:CategoryResults[$fn].Errors -gt 0 -and $script:CategoryResults[$fn].Changed -gt 0) {
                        $script:CategoryResults[$fn].Status = "Partial"
                    } elseif ($script:CategoryResults[$fn].Errors -gt 0) {
                        $script:CategoryResults[$fn].Status = "Error"
                    } elseif ($script:CategoryResults[$fn].Status -eq "Skipped") {
                        $script:CategoryResults[$fn].Status = "Skipped"
                    } elseif ($script:CategoryResults[$fn].Changed -gt 0) {
                        $script:CategoryResults[$fn].Status = "Fixed"
                    } else {
                        $script:CategoryResults[$fn].Status = "Already OK"
                    }
                } catch {
                    $script:CategoryResults[$fn].Status = "Error"
                    $script:CategoryResults[$fn].Errors++
                    Write-Log "Error in $fn : $($_.Exception.Message)" -Level Error
                }
            }

            # Add category result indicator
            $catSP = New-Object System.Windows.Controls.StackPanel
            $catSP.Orientation = "Horizontal"
            $catSP.Margin = [System.Windows.Thickness]::new(0,2,10,2)
            $catLabel = New-Object System.Windows.Controls.TextBlock
            $catLabel.Text = "$fn "; $catLabel.FontSize = 10
            $catLabel.Foreground = $bc.ConvertFromString("#c9d1d9")
            $catSP.Children.Add($catLabel) | Out-Null
            $catStatus = New-Object System.Windows.Controls.TextBlock
            $catStatus.FontSize = 10; $catStatus.FontWeight = "Bold"
            switch ($script:CategoryResults[$fn].Status) {
                "Fixed"      { $catStatus.Text = "FIXED"; $catStatus.Foreground = $bc.ConvertFromString("#3fb950") }
                "Partial"    { $catStatus.Text = "PARTIAL"; $catStatus.Foreground = $bc.ConvertFromString("#d29922") }
                "Error"      { $catStatus.Text = "FAILED"; $catStatus.Foreground = $bc.ConvertFromString("#f85149") }
                "Already OK" { $catStatus.Text = "FIXED"; $catStatus.Foreground = $bc.ConvertFromString("#3fb950") }
                default      { $catStatus.Text = "SKIPPED"; $catStatus.Foreground = $bc.ConvertFromString("#484f58") }
            }
            $script:RestoreTimelineResults[$key] = $script:CategoryResults[$fn].Status
            $ui.timelineScrubber.Value = $i
            $catSP.Children.Add($catStatus) | Out-Null
            $ui.categoryResultsList.Children.Add($catSP) | Out-Null

            $window.Dispatcher.Invoke([action]{}, "Render")
        }
        $script:CurrentCategory = ""

        if ($rollbackJournal) {
            $journalErrors = @($script:CategoryResults.Values | Where-Object { $_.Errors -gt 0 }).Count
            $journalOperationErrors = @($rollbackJournal.Operations | Where-Object { $_.JournalStatus -eq "Failed" }).Count
            $journalState = if ($journalErrors -gt 0 -or $journalOperationErrors -gt 0) { "Failed" } else { "Committed" }
            Update-RestoreRollbackJournal -Journal $rollbackJournal -JournalPath $script:ActiveRollbackJournalPath -State $journalState | Out-Null
        }

        # ---- SUMMARY ----
        Write-Log "" -Level Info
        Write-Log "=== RESTORATION SUMMARY ===" -Level Section
        $fixed   = @($script:CategoryResults.Values | Where-Object { $_.Status -eq "Fixed" -or $_.Status -eq "Already OK" }).Count
        $partial = @($script:CategoryResults.Values | Where-Object { $_.Status -eq "Partial" }).Count
        $already = @($script:CategoryResults.Values | Where-Object { $_.Status -eq "Already OK" }).Count
        $errored = @($script:CategoryResults.Values | Where-Object { $_.Status -eq "Error" }).Count
        Write-Log "Fixed: $fixed | Partial: $partial | Already OK: $already | Errors: $errored | Total changes: $script:ChangesCount" -Level Info
        Write-Log "" -Level Info
        foreach ($cat in $script:CategoryResults.GetEnumerator()) {
            $icon = switch ($cat.Value.Status) { "Fixed"{"[FIXED]"}; "Already OK"{"[ OK ]"}; "Partial"{"[PART]"}; "Error"{"[FAIL]"}; default{"[----]"} }
            $lvl = switch ($cat.Value.Status) { "Fixed"{"Success"}; "Partial"{"Warning"}; "Error"{"Error"}; default{"Info"} }
            $det = if ($cat.Value.Changed -gt 0) { " ($($cat.Value.Changed) changes)" } else { "" }
            Write-Log "$icon $($cat.Key)$det" -Level $lvl
        }
        Write-Log "" -Level Info
        Write-Log "Log saved: $(Split-Path $script:LogPath -Leaf)" -Level Info
        Write-Log "" -Level Section
        Write-Log "WHAT TO DO NEXT:" -Level Section
        Write-Log "1. Click 'Reboot Now' to finish applying changes" -Level Info
        Write-Log "2. After reboot, check that Defender and Firewall are on" -Level Info
        Write-Log "3. Run Windows Update to get latest security patches" -Level Info
        Write-Log "4. If anything is wrong, use System Restore to undo" -Level Info

        try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }

        $ui.txtProgressTitle.Text = "All done! Your PC has been restored."
        $parts = @()
        if ($fixed -gt 0) { $parts += "$fixed fixed" }
        if ($partial -gt 0) { $parts += "$partial partial" }
        if ($already -gt 0) { $parts += "$already already OK" }
        if ($errored -gt 0) { $parts += "$errored errors" }
        $ui.txtProgressSub.Text = ($parts -join "  |  ")
        $ui.progressBar.Value = $ui.progressBar.Maximum
        $ui.txtProgressPercent.Text = "Complete"; $ui.txtProgressStep.Text = ""
        $ui.txtStatus.Text = "Please reboot to finish applying changes"
        $ui.btnReboot.Visibility = "Visible"; $ui.btnLater.Visibility = "Visible"
        $ui.btnRollback.Visibility = "Visible"
        $ui.btnExportReport.Visibility = "Visible"; $ui.btnViewLog.Visibility = "Visible"
        $window.Dispatcher.Invoke([action]{}, "Render")
    }

    # ================================================================
    # WIRE EVENTS
    # ================================================================
    $ui.btnFixAll.Add_MouseLeftButtonUp({
        $r = [System.Windows.MessageBox]::Show(
            "This will restore your PC to factory Windows defaults.`n`nWhat it does:`n  - Turns security back on (Defender, Firewall, SmartScreen)`n  - Re-enables Windows Update and system services`n  - Removes debloat registry tweaks and host blocks`n  - Keeps your current dark theme`n  - Does NOT reinstall removed apps`n`nA restore point will be created first so you can undo.`n`nEstimated time: 1-3 minutes`n`nContinue?",
            "Recommended Fix", "YesNo", "Question")
        if ($r -eq "Yes") { & $runRestore $safeDefaults $ui.chkAutoRestore.IsChecked $false }
    })

    $ui.btnFixDetected.Add_MouseLeftButtonUp({
        if (!$detectedKeys.Count) {
            [System.Windows.MessageBox]::Show("No issues were detected by the scanner.`nYour system looks healthy!", "Nothing to Fix", "OK", "Information")
            return
        }
        $msg = "Fix only the $($detectedKeys.Count) categories where problems were found:`n`n"
        foreach ($k in $detectedKeys) { $fn = $friendlyMap[$k]; if ($fn) { $msg += "  - $fn`n" } }
        $msg += "`nEstimated time: Under 1 minute`n`nContinue?"
        $r = [System.Windows.MessageBox]::Show($msg, "Fix Detected Issues", "YesNo", "Question")
        if ($r -eq "Yes") { & $runRestore $detectedKeys $ui.chkAutoRestore.IsChecked $false }
    })

    $ui.btnFixSecurity.Add_MouseLeftButtonUp({
        $r = [System.Windows.MessageBox]::Show(
            "This ONLY fixes your security settings:`n`n  - Windows Defender (antivirus protection)`n  - Windows Firewall (network protection)`n  - SmartScreen (blocks dangerous downloads)`n  - Windows Update (keeps your PC up to date)`n  - UAC (asks before making big changes)`n  - Security protocols and Windows Security app`n`nEverything else stays exactly how it is.`n`nEstimated time: Under 1 minute`n`nContinue?",
            "Security Fix", "YesNo", "Question")
        if ($r -eq "Yes") { & $runRestore $securityOnly $ui.chkAutoRestore.IsChecked $false }
    })

    $ui.btnCustom.Add_MouseLeftButtonUp({
        $ui.pageHome.Visibility = "Collapsed"; $ui.pageCustom.Visibility = "Visible"
    })

    $ui.btnScanOnly.Add_MouseLeftButtonUp({ & $runRestore $safeDefaults $false $true })

    $ui.btnBack.Add_Click({ $ui.pageCustom.Visibility = "Collapsed"; $ui.pageHome.Visibility = "Visible" })

    $ui.btnRunCustom.Add_Click({
        $sel = @()
        foreach ($chk in $allChkNames) { if ($ui[$chk] -and $ui[$chk].IsChecked) { $sel += $chk } }
        if (!$sel.Count) {
            [System.Windows.MessageBox]::Show("Select at least one category.", "Nothing Selected", "OK", "Information"); return
        }
        $r = [System.Windows.MessageBox]::Show("Restore $($sel.Count) categories?", "Confirm", "YesNo", "Question")
        if ($r -eq "Yes") { & $runRestore $sel $ui.chkAutoRestoreC.IsChecked $false }
    })

    $ui.btnScheduleCustom.Add_Click({
        $sel = @()
        foreach ($chk in $allChkNames) { if ($ui[$chk] -and $ui[$chk].IsChecked) { $sel += $chk } }
        if (!$sel.Count) {
            [System.Windows.MessageBox]::Show("Select at least one category.", "Nothing Selected", "OK", "Information"); return
        }
        try {
            $scheduledPath = Register-RestoreAtNextBoot -SelectedKeys $sel -CreateRestorePoint:$ui.chkAutoRestoreC.IsChecked
            [System.Windows.MessageBox]::Show("The selected restore will run once at the next boot.`n`nState: $scheduledPath", "Restore Scheduled", "OK", "Information")
        } catch {
            [System.Windows.MessageBox]::Show("Could not schedule restore: $($_.Exception.Message)", "Schedule Error", "OK", "Error")
        }
    })

    $ui.btnSelectAll.Add_Click({ foreach ($c in $allChkNames) { if ($ui[$c]) { $ui[$c].IsChecked = $true } } })
    $ui.btnSelectNone.Add_Click({ foreach ($c in $allChkNames) { if ($ui[$c]) { $ui[$c].IsChecked = $false } } })
    $ui.btnSelectSafe.Add_Click({
        foreach ($c in $allChkNames) {
            if ($ui[$c]) {
                $isSafe = ($c -ne "chkTheme" -and $c -ne "chkAppx" -and $c -ne "chkSearchIndexer" -and $c -ne "chkDefenderCpuCap" -and $c -ne "chkGroupPolicy")
                if ($script:ManagedMode -and $c -in @("chkSync","chkOneDrive","chkAccount")) { $isSafe = $false }
                $ui[$c].IsChecked = $isSafe
            }
        }
    })

    $ui.btnClose.Add_Click({ $window.Close() })
    $ui.btnReboot.Add_Click({
        $r = [System.Windows.MessageBox]::Show("Your PC will restart now.`nMake sure you have saved any open work.", "Reboot", "OKCancel", "Warning")
        if ($r -eq "OK") { $window.Close(); Restart-Computer -Force }
    })
    $ui.btnLater.Add_Click({ $window.Close() })
    $ui.btnRollback.Add_Click({
        try {
            Invoke-RestoreRollback -RollbackPath $script:LastRollbackPath
            $ui.txtStatus.Text = "Rollback complete; reboot if a restored service requires it"
            [System.Windows.MessageBox]::Show("The registry, service, and task state captured before this run was restored.", "Rollback Complete", "OK", "Information")
        } catch {
            [System.Windows.MessageBox]::Show("Rollback failed: $($_.Exception.Message)", "Rollback Error", "OK", "Error")
        }
    })
    $ui.btnViewLog.Add_Click({ if (Test-Path $script:LogPath) { Start-Process notepad.exe $script:LogPath } })

    # ---- Import Manifest button ----
    $ui.btnImportManifest.Add_Click({
        $ofd = New-Object Microsoft.Win32.OpenFileDialog
        $ofd.Title = "Import Debloat Undo Manifest"
        $ofd.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*"
        $ofd.InitialDirectory = "$env:USERPROFILE\Desktop"
        if ($ofd.ShowDialog() -eq $true) {
            $manifest = Import-UndoManifest -ManifestPath $ofd.FileName
            if ($manifest.Success) {
                $script:ImportedManifest = $manifest
                $ui.manifestBanner.Visibility = "Visible"
                $ui.txtManifestSummary.Text = $manifest.Summary

                # Auto-check only relevant categories, uncheck the rest
                foreach ($c in $allChkNames) {
                    if ($ui[$c]) {
                        $ui[$c].IsChecked = ($c -in $manifest.RelevantCategories)
                    }
                }
                # Switch to custom page so user can see what's checked
                $ui.pageHome.Visibility = "Collapsed"
                $ui.pageCustom.Visibility = "Visible"
            } else {
                [System.Windows.MessageBox]::Show($manifest.Summary, "Manifest Import Failed", "OK", "Error")
            }
        }
    })

    # ---- Export Report button ----
    $ui.btnExportReport.Add_Click({
        $sfd = New-Object Microsoft.Win32.SaveFileDialog
        $sfd.Title = "Export Restoration Report"
        $sfd.Filter = "HTML files (*.html)|*.html"
        $sfd.InitialDirectory = "$env:USERPROFILE\Desktop"
        $sfd.FileName = "WindowsRestore_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
        if ($sfd.ShowDialog() -eq $true) {
            $success = Export-HtmlReport -OutputPath $sfd.FileName
            if ($success) {
                Start-Process $sfd.FileName
            } else {
                [System.Windows.MessageBox]::Show("Failed to save report.", "Export Error", "OK", "Error")
            }
        }
    })

    $window.ShowDialog() | Out-Null
}

# Preserve the descriptive collection-oriented command names used by earlier
# releases while keeping the implementation nouns singular for analyzer hygiene.
Set-Alias -Name Compare-RegistrySnapshots -Value Compare-RegistrySnapshot -Scope Script -Force
Set-Alias -Name Reset-WindowsUpdateChannelAndDeferrals -Value Reset-WindowsUpdateChannelAndDeferral -Scope Script -Force
Set-Alias -Name Restore-DevicePrivacySliders -Value Restore-DevicePrivacySlider -Scope Script -Force
Set-Alias -Name Restore-MissingScheduledTasks -Value Restore-MissingScheduledTask -Scope Script -Force
Set-Alias -Name ConvertTo-ExternalChangeOperations -Value ConvertTo-ExternalChangeOperation -Scope Script -Force
Set-Alias -Name Compare-RegExportSnapshots -Value Compare-RegExportSnapshot -Scope Script -Force
Set-Alias -Name Restore-LocalGroupPolicyDefaults -Value Restore-LocalGroupPolicyDefault -Scope Script -Force

# ============================================================================
# ENTRY POINT
# ============================================================================

if ($BaselineReport) {
    $catalogReportDocument = Get-RestoreBaselineCatalogReport
    Write-Output ($catalogReportDocument | ConvertTo-Json -Depth 30)
    exit 0
}

if ($CapabilityReport) {
    $capabilityKeys = if ($RestoreCategories) { @($RestoreCategories -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { $null }
    if ($AllowManagedPolicy) { $capabilityReportDocument = Get-RestoreCapabilityReport -SelectedKeys $capabilityKeys -AllowManagedPolicy }
    else { $capabilityReportDocument = Get-RestoreCapabilityReport -SelectedKeys $capabilityKeys }
    Write-Output ($capabilityReportDocument | ConvertTo-Json -Depth 20)
    exit 0
}

if ($WhatIf -or $PlanPath) {
    if (-not $RestoreCategories) { throw "-WhatIf or -PlanPath requires -RestoreCategories so the plan scope is explicit" }
    $planKeys = @($RestoreCategories -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($AllowManagedPolicy) { $actionPlan = Get-RestoreActionPlan -SelectedKeys $planKeys -AllowManagedPolicy }
    else { $actionPlan = Get-RestoreActionPlan -SelectedKeys $planKeys }
    if ($PlanPath) { $null = Export-RestoreActionPlan -ActionPlan $actionPlan -OutputPath $PlanPath }
    else { Write-Output ($actionPlan | ConvertTo-Json -Depth 30) }
    if ($actionPlan.Status -eq "Blocked") { exit 2 }
    exit 0
}

if ($ExportSnapshot) {
    $null = Export-RegistrySnapshot -OutputPath $ExportSnapshot
    Write-Output "Registry snapshot exported: $ExportSnapshot"
    exit
}

if ($CompareSnapshot) {
    $currentSnapshot = Get-RegistrySnapshot
    $diff = Compare-RegistrySnapshot -Before $CompareSnapshot -After $currentSnapshot
    Write-Output ($diff | ConvertTo-Json -Depth 12)
    exit
}

if ($PostUpdateCheck) {
    Write-Output ((Get-PostUpdateSecurityRecheck) | ConvertTo-Json -Depth 12)
    exit
}

if ($ExportSupportBundle) {
    Write-Output (Export-RestoreSupportBundle -OutputPath $ExportSupportBundle)
    exit
}

if ($RemoteComputerName) {
    if (-not $RemoteScriptPath) { $RemoteScriptPath = $PSCommandPath }
    $remoteKeys = if ($RestoreCategories) { @($RestoreCategories -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @("chkDefender","chkFirewall","chkWindowsUpdate","chkServices","chkTasks") }
    Write-Output ((Invoke-RemoteRestoreBatch -ComputerName $RemoteComputerName -SelectedKeys $remoteKeys -ScriptPath $RemoteScriptPath) | Out-String)
    exit
}

if ($RollbackLastRun) {
    Invoke-RestoreRollback
    exit
}

if ($ResumeRestoreJournal) {
    $resumeResult = Resume-RestoreRollbackJournal
    Write-Output ($resumeResult | ConvertTo-Json -Depth 30)
    exit (if($resumeResult.Success){0}else{1})
}

if ($ResumeScheduledRestore) {
    Invoke-ScheduledRestore
    exit
}

if ($SecurityReset) {
    if ($AllowManagedPolicy) { $securityResult = Invoke-RestoreSelection -SelectedKeys @("chkDefender","chkFirewall","chkSmartScreen","chkWindowsUpdate","chkSecurityUI") -CreateRollbackSnapshot -AllowManagedPolicy }
    else { $securityResult = Invoke-RestoreSelection -SelectedKeys @("chkDefender","chkFirewall","chkSmartScreen","chkWindowsUpdate","chkSecurityUI") -CreateRollbackSnapshot }
    Write-Output ($securityResult | ConvertTo-Json -Depth 20)
    exit ([int]$securityResult.ExitCode)
}

if ($RebuildSearch) {
    if ($AllowManagedPolicy) { $searchResult = Invoke-RestoreSelection -SelectedKeys @("chkSearchIndexer") -CreateRollbackSnapshot -AllowManagedPolicy }
    else { $searchResult = Invoke-RestoreSelection -SelectedKeys @("chkSearchIndexer") -CreateRollbackSnapshot }
    Write-Output ($searchResult | ConvertTo-Json -Depth 20)
    exit ([int]$searchResult.ExitCode)
}

if ($RestoreTier) {
    $tierResult = Invoke-RestoreTier -Tier $RestoreTier
    Write-Output ($tierResult | ConvertTo-Json -Depth 20)
    exit ([int]$tierResult.ExitCode)
}

if ($ScheduleRestore) {
    $scheduledKeys = if ($RestoreCategories) { @($RestoreCategories -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        else { @("chkDefender","chkFirewall","chkSmartScreen","chkWindowsUpdate","chkServices","chkTasks") }
    Register-RestoreAtNextBoot -SelectedKeys $scheduledKeys -CreateRestorePoint
    exit
}

if ($RestoreCategories) {
    $directKeys = @($RestoreCategories -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($AllowManagedPolicy) { $directResult = Invoke-RestoreSelection -SelectedKeys $directKeys -CreateRollbackSnapshot -AllowManagedPolicy }
    else { $directResult = Invoke-RestoreSelection -SelectedKeys $directKeys -CreateRollbackSnapshot }
    Write-Output ($directResult | ConvertTo-Json -Depth 20)
    exit ([int]$directResult.ExitCode)
}

if (-not $NoGui) { Show-MainWindow }
