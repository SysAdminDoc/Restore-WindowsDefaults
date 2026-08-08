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
$issues = New-Object System.Collections.Generic.List[string]
$capabilitySummary = $null

if (-not (Test-Path -LiteralPath $ToolPath)) { throw "Restore tool not found: $ToolPath" }
$capabilityJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ToolPath -NoGui -NoElevation -CapabilityReport -RestoreCategories $categories
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Capability report failed with exit code $LASTEXITCODE" }
try {
    $capability = ($capabilityJson -join "`n") | ConvertFrom-Json -ErrorAction Stop
    $profile = $capability.Profile
    $management = if ($profile.Management) { $profile.Management | Select-Object IsManaged,IsKnown,DomainJoined,MdmEnrolled,Ownership,Signals,QueryErrors } else { $null }
    $capabilitySummary = [pscustomobject][ordered]@{
        Status=$capability.Status; Profile=$profile | Select-Object SchemaVersion,Status,ProductFamily,Edition,DisplayVersion,Build,BuildRevision,Architecture,Locale,IsWindows,IsOnline,PowerShellMajor,IsWindowsPowerShell,IsAdministrator
        Management=$management; BlockedCategories=@($capability.Categories | Where-Object { -not $_.CanMutate } | Select-Object Key,Status,Reason)
    }
    foreach ($blocked in @($capabilitySummary.BlockedCategories)) {
        $issues.Add("Capability gate: $($blocked.Key) [$($blocked.Status)] $($blocked.Reason)")
    }
} catch {
    $issues.Add("Capability report could not be parsed: $($_.Exception.Message)")
}

foreach ($serviceName in @("WinDefend","MpsSvc","wuauserv","BITS")) {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service -and $service.StartType -eq "Disabled") { $issues.Add("Service disabled: $serviceName") }
}
$policy = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -ErrorAction SilentlyContinue
if ($policy -and $policy.NoAutoUpdate -eq 1) { $issues.Add("Windows Update disabled by policy") }
$firewall = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\PublicProfile" -Name "EnableFirewall" -ErrorAction SilentlyContinue
if ($firewall -and $firewall.EnableFirewall -eq 0) { $issues.Add("Public firewall profile disabled") }

if (-not $Remediate) {
    [pscustomobject]@{ Compliant=($issues.Count -eq 0); Capability=$capabilitySummary; Issues=@($issues) } | ConvertTo-Json -Depth 8
    if ($issues.Count -gt 0) { exit 1 }
    exit 0
}

if (@($capabilitySummary.BlockedCategories).Count -gt 0) {
    [pscustomobject]@{ Compliant=$false; Remediated=$false; Capability=$capabilitySummary; Issues=@($issues) } | ConvertTo-Json -Depth 8
    exit 2
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ToolPath -NoGui -NoElevation -RestoreCategories $categories
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
exit 0
