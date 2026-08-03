[CmdletBinding()]
param(
    [switch]$Remediate,
    [string]$ToolPath = (Join-Path $PSScriptRoot "..\Restore-WindowsDefaults.ps1")
)

$ErrorActionPreference = "Stop"
$categories = "chkDefender,chkFirewall,chkSmartScreen,chkWindowsUpdate,chkUAC,chkServices,chkTasks"
$issues = @()

foreach ($serviceName in @("WinDefend","MpsSvc","wuauserv","BITS")) {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service -and $service.StartType -eq "Disabled") { $issues += "Service disabled: $serviceName" }
}
$defenderPolicy = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "DisableAntiSpyware" -ErrorAction SilentlyContinue
if ($defenderPolicy -and $defenderPolicy.DisableAntiSpyware -eq 1) { $issues += "Defender policy disabled antivirus" }
$uac = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -ErrorAction SilentlyContinue
if ($uac -and $uac.EnableLUA -eq 0) { $issues += "UAC disabled" }

if (-not $Remediate) {
    [pscustomobject]@{ Compliant=($issues.Count -eq 0); Issues=@($issues) } | ConvertTo-Json -Depth 4
    if ($issues.Count -gt 0) { exit 1 }
    exit 0
}

if (-not (Test-Path -LiteralPath $ToolPath)) { throw "Restore tool not found: $ToolPath" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ToolPath -NoGui -NoElevation -RestoreCategories $categories
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
exit 0
