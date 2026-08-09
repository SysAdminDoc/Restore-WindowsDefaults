[CmdletBinding()]
param(
    [switch]$Remediate,
    [string]$ToolPath
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($ToolPath)) {
    $wrapperRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $ToolPath = Join-Path $wrapperRoot "..\Restore-WindowsDefaults.ps1"
}
$categories = "chkDefender,chkFirewall,chkSmartScreen,chkWindowsUpdate,chkUAC,chkServices,chkTasks"
$issues = @()
$capabilitySummary = $null

if (-not (Test-Path -LiteralPath $ToolPath)) { throw "Restore tool not found: $ToolPath" }
$capabilityJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ToolPath -NoGui -NoElevation -CapabilityReport -RestoreCategories $categories
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Capability report failed with exit code $LASTEXITCODE" }
try {
    $capability = ($capabilityJson -join "`n") | ConvertFrom-Json -ErrorAction Stop
    $profile = $capability.Profile
    $management = if ($profile.Management) { $profile.Management | Select-Object IsManaged,IsKnown,DomainJoined,MdmEnrolled,Ownership,PolicyOwnership,Decision,ManagementConfidence,DsregStatus,DsregWarning,Evidence,QueryErrors } else { $null }
    $capabilitySummary = [pscustomobject][ordered]@{
        Status=$capability.Status; Profile=$profile | Select-Object SchemaVersion,Status,ProductFamily,Edition,DisplayVersion,Build,BuildRevision,Architecture,Locale,IsWindows,IsOnline,PowerShellMajor,IsWindowsPowerShell,IsAdministrator
        Management=$management; ManagementDecision=$capability.ManagementDecision; ManagedPolicyOverride=$capability.ManagedPolicyOverride
        PendingRebootState=$capability.PendingRebootState
        BlockedCategories=@($capability.Categories | Where-Object { -not $_.CanMutate } | Select-Object Key,Status,Reason,ManagedPolicyDecision,ManagementEvidence)
    }
    foreach ($blocked in @($capabilitySummary.BlockedCategories)) {
        $issues += "Capability gate: $($blocked.Key) [$($blocked.Status)] $($blocked.Reason)"
    }
} catch {
    $issues += "Capability report could not be parsed: $($_.Exception.Message)"
}

foreach ($serviceName in @("WinDefend","MpsSvc","wuauserv","BITS")) {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service -and $service.StartType -eq "Disabled") { $issues += "Service disabled: $serviceName" }
}
$defenderPolicy = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "DisableAntiSpyware" -ErrorAction SilentlyContinue
if ($defenderPolicy -and $defenderPolicy.DisableAntiSpyware -eq 1) { $issues += "Defender policy disabled antivirus" }
$uac = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -ErrorAction SilentlyContinue
if ($uac -and $uac.EnableLUA -eq 0) { $issues += "UAC disabled" }

if (-not $Remediate) {
    [pscustomobject]@{ Compliant=($issues.Count -eq 0); Capability=$capabilitySummary; Issues=@($issues) } | ConvertTo-Json -Depth 8
    if ($issues.Count -gt 0) { exit 1 }
    exit 0
}

if (@($capabilitySummary.BlockedCategories).Count -gt 0) {
    [pscustomobject]@{ Compliant=$false; Remediated=$false; Capability=$capabilitySummary; Issues=@($issues) } | ConvertTo-Json -Depth 8
    exit 2
}
$restoreOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ToolPath -NoGui -NoElevation -RestoreCategories $categories)
$restoreExitCode = $LASTEXITCODE
$restoreResult = $null
try { $restoreResult = ($restoreOutput -join "`n") | ConvertFrom-Json -ErrorAction Stop } catch { $issues += "Restore result could not be parsed: $($_.Exception.Message)" }
$remediation = [pscustomobject][ordered]@{Compliant=($restoreExitCode -eq 0 -and $issues.Count -eq 0);Remediated=($restoreExitCode -eq 0);ExitCode=$restoreExitCode;Capability=$capabilitySummary;Restore=$restoreResult;PendingReboot=if($restoreResult){[bool]$restoreResult.PendingReboot}else{[bool]$capability.PendingRebootState.PendingReboot};PendingRebootState=if($restoreResult){$restoreResult.PendingRebootState}else{$capability.PendingRebootState};Verification=if($restoreResult){[pscustomobject]@{Status=$restoreResult.VerificationStatus;VerificationFailedCount=$restoreResult.VerificationFailedCount;NotObservableCount=$restoreResult.NotObservableCount;Report=$restoreResult.VerificationReport}}else{$null};Issues=@($issues)}
$remediation | ConvertTo-Json -Depth 12
if ($restoreExitCode -ne 0) { exit $restoreExitCode }
if ($issues.Count -gt 0) { exit 1 }
exit 0
