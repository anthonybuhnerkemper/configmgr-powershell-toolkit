<#
.SYNOPSIS
    Redistributes content to DPs by setting RefreshNow on SMS_DistributionPoint (same as console Redistribute).
.DESCRIPTION
    Works for any content type with a PackageID. Use -FailedOnly to target only DPs whose
    SMS_PackageStatusDistPointsSummarizer state is failed (3, 6, 8) or retrying (2).
.PARAMETER SiteCode
    Site code.
.PARAMETER ProviderMachineName
    SMS Provider server.
.PARAMETER PackageId
    Content ID(s).
.PARAMETER DistributionPointName
    Optional DP name filter (substring match on ServerNALPath).
.PARAMETER FailedOnly
    Only redistribute where status is failed/retrying. If no -PackageId, all failed content is targeted.
.EXAMPLE
    .\Start-CMContentRedistribution.ps1 -SiteCode HOU -ProviderMachineName cm01 -FailedOnly -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$SiteCode,
    [Parameter(Mandatory)][Alias('SiteServer')][string]$ProviderMachineName,
    [string[]]$PackageId,
    [string]$DistributionPointName,
    [switch]$FailedOnly
)
if (-not $PackageId -and -not $FailedOnly) { throw 'Specify -PackageId and/or -FailedOnly.' }
$cim = @{ ComputerName = $ProviderMachineName; Namespace = "root\SMS\site_$SiteCode"; ErrorAction = 'Stop' }

$pairs = @()
if ($FailedOnly) {
    $q = 'SELECT PackageID, ServerNALPath, State FROM SMS_PackageStatusDistPointsSummarizer WHERE State IN (2,3,6,8)'
    $pairs = Get-CimInstance @cim -Query $q
    if ($PackageId) { $pairs = $pairs | Where-Object { $PackageId -contains $_.PackageID } }
} else {
    $pairs = foreach ($p in $PackageId) { Get-CimInstance @cim -ClassName SMS_DistributionPoint -Filter "PackageID='$p'" }
}
if ($DistributionPointName) { $pairs = $pairs | Where-Object { $_.ServerNALPath -like "*$DistributionPointName*" } }
if (-not $pairs) { Write-Verbose 'Nothing to redistribute.'; return }

foreach ($pair in $pairs) {
    $nal = $pair.ServerNALPath -replace "'", "''" -replace '\\', '\\'
    $dp = Get-CimInstance @cim -ClassName SMS_DistributionPoint -Filter "PackageID='$($pair.PackageID)' AND ServerNALPath='$nal'"
    if (-not $dp) { Write-Warning "No SMS_DistributionPoint for $($pair.PackageID) on $($pair.ServerNALPath)"; continue }
    if ($PSCmdlet.ShouldProcess("$($pair.PackageID) on $($pair.ServerNALPath)", 'Redistribute (RefreshNow)')) {
        try {
            Set-CimInstance -InputObject $dp -Property @{ RefreshNow = $true } -ErrorAction Stop
            [pscustomobject]@{ PackageID = $pair.PackageID; DP = $pair.ServerNALPath; Result = 'Redistribution requested' }
        } catch {
            [pscustomobject]@{ PackageID = $pair.PackageID; DP = $pair.ServerNALPath; Result = "Failed: $($_.Exception.Message)" }
        }
    }
}
