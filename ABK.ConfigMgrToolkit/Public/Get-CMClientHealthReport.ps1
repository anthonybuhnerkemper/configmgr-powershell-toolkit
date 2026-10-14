function Get-CMClientHealthReport {
    <#
    .SYNOPSIS
        Site-side client health report from the SMS Provider.
    .DESCRIPTION
        Queries SMS_CombinedDeviceResources via CIM (no console required) for client presence,
        activity, version, last policy request and last heartbeat. Optionally scoped to a collection.
    .PARAMETER SiteCode
        Site code.
    .PARAMETER ProviderMachineName
        SMS Provider server.
    .PARAMETER CollectionId
        Optional collection ID to scope the report.
    .PARAMETER UnhealthyOnly
        Return only devices with no client or inactive client.
    .PARAMETER OutputPath
        Optional CSV path.
    .EXAMPLE
        Get-CMClientHealthReport -SiteCode HOU -ProviderMachineName cm01 -CollectionId HOU00042 -UnhealthyOnly
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteCode,
        [Parameter(Mandatory)][Alias('SiteServer')][string]$ProviderMachineName,
        [string]$CollectionId,
        [switch]$UnhealthyOnly,
        [string]$OutputPath
    )

    $cim = @{ ComputerName = $ProviderMachineName; Namespace = "root\SMS\site_$SiteCode"; ErrorAction = 'Stop' }
    $props = 'Name,ResourceID,IsClient,ClientActiveStatus,ClientVersion,LastActiveTime,LastPolicyRequest,LastDDR,LastHardwareScan,ADSiteName,ClientState'
    $query = "SELECT $props FROM SMS_CombinedDeviceResources"
    if ($CollectionId) {
        $members = Get-CimInstance @cim -Query "SELECT ResourceID FROM SMS_FullCollectionMembership WHERE CollectionID = '$CollectionId'"
        $ids = @($members.ResourceID)
        if (-not $ids) { Write-Warning "Collection $CollectionId has no members."; return }
    }
    $devices = Get-CimInstance @cim -Query $query
    if ($CollectionId) { $devices = $devices | Where-Object { $ids -contains $_.ResourceID } }

    $report = foreach ($d in $devices) {
        $status = if (-not $d.IsClient) { 'NoClient' } elseif ($d.ClientActiveStatus -ne 1) { 'Inactive' } else { 'Active' }
        [pscustomobject]@{
            Name              = $d.Name
            ResourceID        = $d.ResourceID
            Status            = $status
            ClientVersion     = $d.ClientVersion
            LastActiveTime    = $d.LastActiveTime
            LastPolicyRequest = $d.LastPolicyRequest
            LastDDR           = $d.LastDDR
            LastHardwareScan  = $d.LastHardwareScan
            PendingRebootFlag = [bool]($d.ClientState -band 0xF)
            ADSite            = $d.ADSiteName
        }
    }
    if ($UnhealthyOnly) { $report = $report | Where-Object Status -ne 'Active' }
    if ($OutputPath) { $report | Export-Csv -Path $OutputPath -NoTypeInformation; Write-Verbose "Saved $OutputPath" }
    $report
}

