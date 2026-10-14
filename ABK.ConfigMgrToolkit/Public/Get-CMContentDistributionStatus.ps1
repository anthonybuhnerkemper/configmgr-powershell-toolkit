function Get-CMContentDistributionStatus {
    <#
    .SYNOPSIS
        Per-DP content distribution status from SMS_PackageStatusDistPointsSummarizer.
    .PARAMETER SiteCode
        Site code.
    .PARAMETER ProviderMachineName
        SMS Provider server.
    .PARAMETER PackageId
        Optional content ID(s) (applications also have a PackageID for their content).
    .PARAMETER FailedOnly
        Exclude State 0 (installed).
    .PARAMETER OutputPath
        Optional CSV output.
    .EXAMPLE
        Get-CMContentDistributionStatus -SiteCode HOU -ProviderMachineName cm01 -FailedOnly
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteCode,
        [Parameter(Mandatory)][Alias('SiteServer')][string]$ProviderMachineName,
        [string[]]$PackageId,
        [switch]$FailedOnly,
        [string]$OutputPath
    )
    $stateMap = @{ 0 = 'Installed'; 1 = 'InstallPending'; 2 = 'InstallRetrying'; 3 = 'InstallFailed'; 4 = 'RemovalPending'; 5 = 'RemovalRetrying'; 6 = 'RemovalFailed'; 7 = 'Validating'; 8 = 'ValidationFailed' }
    $cim = @{ ComputerName = $ProviderMachineName; Namespace = "root\SMS\site_$SiteCode"; ErrorAction = 'Stop' }
    $f = @()
    if ($PackageId) { $f += '(' + (($PackageId | ForEach-Object { "PackageID = '$_'" }) -join ' OR ') + ')' }
    if ($FailedOnly) { $f += 'State <> 0' }
    $q = 'SELECT PackageID, ServerNALPath, State, SummaryDate, SourceVersion FROM SMS_PackageStatusDistPointsSummarizer'
    if ($f) { $q += ' WHERE ' + ($f -join ' AND ') }

    $names = @{}
    Get-CimInstance @cim -Query 'SELECT PackageID, Name FROM SMS_PackageBaseclass' | ForEach-Object { $names[$_.PackageID] = $_.Name }

    $report = Get-CimInstance @cim -Query $q | ForEach-Object {
        $dp = if ($_.ServerNALPath -match '\\\\([^\\\]]+)\\') { $Matches[1] } else { $_.ServerNALPath }
        [pscustomobject]@{
            PackageID     = $_.PackageID
            Name          = $names[$_.PackageID]
            DistributionPoint = $dp
            State         = $stateMap[[int]$_.State]
            StateCode     = $_.State
            SourceVersion = $_.SourceVersion
            SummaryDate   = $_.SummaryDate
        }
    } | Sort-Object StateCode -Descending
    if ($OutputPath) { $report | Export-Csv -Path $OutputPath -NoTypeInformation }
    $report
}

