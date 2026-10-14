function Get-CMDeploymentStatusReport {
    <#
    .SYNOPSIS
        Summarizes deployment status (success/in progress/error/unknown) from SMS_DeploymentSummary.
    .PARAMETER SiteCode
        Site code.
    .PARAMETER ProviderMachineName
        SMS Provider server.
    .PARAMETER SoftwareName
        Optional software name filter (WQL LIKE, use %).
    .PARAMETER CollectionId
        Optional collection filter.
    .PARAMETER MinErrorPercent
        Return only deployments at or above this error percentage.
    .PARAMETER OutputPath
        Optional CSV output.
    .EXAMPLE
        Get-CMDeploymentStatusReport -SiteCode HOU -ProviderMachineName cm01 -SoftwareName '7-Zip%'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteCode,
        [Parameter(Mandatory)][Alias('SiteServer')][string]$ProviderMachineName,
        [string]$SoftwareName,
        [string]$CollectionId,
        [ValidateRange(0,100)][int]$MinErrorPercent = 0,
        [string]$OutputPath
    )
    $featureMap = @{ 1 = 'Application'; 2 = 'Program'; 3 = 'MobileProgram'; 4 = 'Script'; 5 = 'SoftwareUpdate'; 6 = 'Baseline'; 7 = 'TaskSequence'; 8 = 'ContentDistribution'; 9 = 'DistributionPointGroup'; 10 = 'DistributionPointHealth'; 11 = 'ConfigurationPolicy' }
    $filters = @()
    if ($SoftwareName) { $filters += "SoftwareName LIKE '$($SoftwareName -replace "'", "''")'" }
    if ($CollectionId) { $filters += "CollectionID = '$CollectionId'" }
    $q = 'SELECT * FROM SMS_DeploymentSummary'
    if ($filters) { $q += ' WHERE ' + ($filters -join ' AND ') }

    $report = Get-CimInstance -ComputerName $ProviderMachineName -Namespace "root\SMS\site_$SiteCode" -Query $q -ErrorAction Stop |
        ForEach-Object {
            $total = [int]$_.NumberTargeted
            $errPct = if ($total) { [math]::Round(100 * $_.NumberErrors / $total, 1) } else { 0 }
            [pscustomobject]@{
                SoftwareName   = $_.SoftwareName
                Collection     = $_.CollectionName
                Feature        = $featureMap[[int]$_.FeatureType]
                Purpose        = if ($_.DeploymentIntent -eq 1) { 'Required' } elseif ($_.DeploymentIntent -eq 2) { 'Available' } else { $_.DeploymentIntent }
                Targeted       = $total
                Success        = $_.NumberSuccess
                InProgress     = $_.NumberInProgress
                Errors         = $_.NumberErrors
                RequirementsNotMet = $_.NumberOther
                Unknown        = $_.NumberUnknown
                ErrorPercent   = $errPct
                DeploymentTime = $_.DeploymentTime
                SummaryTime    = $_.SummarizationTime
            }
        } | Where-Object { $_.ErrorPercent -ge $MinErrorPercent } | Sort-Object ErrorPercent -Descending
    if ($OutputPath) { $report | Export-Csv -Path $OutputPath -NoTypeInformation }
    $report
}

