function Get-CMCollectionMembershipReport {
    <#
    .SYNOPSIS
        Collection membership report: members of a collection, or all collections a device belongs to.
    .PARAMETER SiteCode
        Site code.
    .PARAMETER ProviderMachineName
        SMS Provider server.
    .PARAMETER CollectionId
        Report members of this collection (or use -CollectionName).
    .PARAMETER CollectionName
        Collection name.
    .PARAMETER ComputerName
        Report every collection this device is in.
    .PARAMETER OutputPath
        Optional CSV.
    .EXAMPLE
        Get-CMCollectionMembershipReport -SiteCode HOU -ProviderMachineName cm01 -CollectionName 'Pilot - IT Workstations'
    .EXAMPLE
        Get-CMCollectionMembershipReport -SiteCode HOU -ProviderMachineName cm01 -ComputerName PC01
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param(
        [Parameter(Mandatory)][string]$SiteCode,
        [Parameter(Mandatory)][Alias('SiteServer')][string]$ProviderMachineName,
        [Parameter(Mandatory, ParameterSetName = 'ById')][string]$CollectionId,
        [Parameter(Mandatory, ParameterSetName = 'ByName')][string]$CollectionName,
        [Parameter(Mandatory, ParameterSetName = 'ByDevice')][string]$ComputerName,
        [string]$OutputPath
    )
    $cim = @{ ComputerName = $ProviderMachineName; Namespace = "root\SMS\site_$SiteCode"; ErrorAction = 'Stop' }
    $esc = { param($s) $s -replace "'", "''" }

    switch ($PSCmdlet.ParameterSetName) {
        'ByDevice' {
            $colls = @{}
            Get-CimInstance @cim -Query 'SELECT CollectionID, Name, MemberCount FROM SMS_Collection' | ForEach-Object { $colls[$_.CollectionID] = $_ }
            $report = Get-CimInstance @cim -Query "SELECT CollectionID, IsDirect FROM SMS_FullCollectionMembership WHERE Name='$(& $esc $ComputerName)'" |
                ForEach-Object {
                    [pscustomobject]@{ ComputerName = $ComputerName; CollectionID = $_.CollectionID; CollectionName = $colls[$_.CollectionID].Name; IsDirect = $_.IsDirect; CollectionMembers = $colls[$_.CollectionID].MemberCount }
                } | Sort-Object CollectionName
        }
        default {
            if ($PSCmdlet.ParameterSetName -eq 'ByName') {
                $c = Get-CimInstance @cim -ClassName SMS_Collection -Filter "Name='$(& $esc $CollectionName)'"
                if (-not $c) { throw "Collection '$CollectionName' not found." }
                $CollectionId = $c.CollectionID
            }
            $devInfo = @{}
            Get-CimInstance @cim -Query 'SELECT ResourceID, IsClient, ClientActiveStatus, LastActiveTime FROM SMS_CombinedDeviceResources' | ForEach-Object { $devInfo[[int]$_.ResourceID] = $_ }
            $report = Get-CimInstance @cim -Query "SELECT Name, ResourceID, IsDirect FROM SMS_FullCollectionMembership WHERE CollectionID='$CollectionId'" |
                ForEach-Object {
                    $d = $devInfo[[int]$_.ResourceID]
                    [pscustomobject]@{ CollectionID = $CollectionId; ComputerName = $_.Name; ResourceID = $_.ResourceID; IsDirect = $_.IsDirect; IsClient = [bool]$d.IsClient; Active = ($d.ClientActiveStatus -eq 1); LastActiveTime = $d.LastActiveTime }
                } | Sort-Object ComputerName
        }
    }
    if ($OutputPath) { $report | Export-Csv -Path $OutputPath -NoTypeInformation }
    $report
}

