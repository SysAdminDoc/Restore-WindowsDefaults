[CmdletBinding()]
param(
    [switch]$Remediate,
    [string]$ToolPath = (Join-Path $PSScriptRoot "..\Restore-WindowsDefaults.ps1")
)

$ErrorActionPreference = "Stop"
$categories = "chkDefender,chkFirewall,chkSmartScreen,chkWindowsUpdate,chkUAC,chkServices,chkTasks"
$issues = New-Object System.Collections.Generic.List[string]

foreach ($serviceName in @("WinDefend","MpsSvc","wuauserv","BITS")) {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service -and $service.StartType -eq "Disabled") { $issues.Add("Service disabled: $serviceName") }
}
$policy = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -ErrorAction SilentlyContinue
if ($policy -and $policy.NoAutoUpdate -eq 1) { $issues.Add("Windows Update disabled by policy") }
$firewall = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\PublicProfile" -Name "EnableFirewall" -ErrorAction SilentlyContinue
if ($firewall -and $firewall.EnableFirewall -eq 0) { $issues.Add("Public firewall profile disabled") }

if (-not $Remediate) {
    [pscustomobject]@{ Compliant=($issues.Count -eq 0); Issues=@($issues) } | ConvertTo-Json -Depth 4
    if ($issues.Count -gt 0) { exit 1 }
    exit 0
}

if (-not (Test-Path -LiteralPath $ToolPath)) { throw "Restore tool not found: $ToolPath" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ToolPath -NoGui -NoElevation -RestoreCategories $categories
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
exit 0
