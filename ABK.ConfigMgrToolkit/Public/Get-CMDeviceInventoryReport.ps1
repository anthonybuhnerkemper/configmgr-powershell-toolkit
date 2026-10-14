function Get-CMDeviceInventoryReport {
    <#
    .SYNOPSIS
        Hardware inventory summary per device from the SMS Provider.
    .DESCRIPTION
        Joins SMS_R_System with SMS_G_System_COMPUTER_SYSTEM, SMS_G_System_OPERATING_SYSTEM and
        SMS_G_System_PC_BIOS. Devices without hardware inventory are included with blank fields.
    .PARAMETER SiteCode
        Site code.
    .PARAMETER ProviderMachineName
        SMS Provider server.
    .PARAMETER CollectionId
        Optional collection scope.
    .PARAMETER ComputerName
        Optional device name filter (wildcards with % per WQL LIKE).
    .PARAMETER OutputPath
        Optional CSV output.
    .EXAMPLE
        Get-CMDeviceInventoryReport -SiteCode HOU -ProviderMachineName cm01 -CollectionId HOU00042 -OutputPath .\reports\inv.csv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteCode,
        [Parameter(Mandatory)][Alias('SiteServer')][string]$ProviderMachineName,
        [string]$CollectionId,
        [string]$ComputerName,
        [string]$OutputPath
    )
    $cim = @{ ComputerName = $ProviderMachineName; Namespace = "root\SMS\site_$SiteCode"; ErrorAction = 'Stop' }

    $where = @()
    if ($ComputerName) { $where += "Name LIKE '$($ComputerName -replace "'", "''")'" }
    $sysQuery = 'SELECT ResourceId, Name, ADSiteName, LastLogonUserName, Client, ClientVersion FROM SMS_R_System'
    if ($where) { $sysQuery += ' WHERE ' + ($where -join ' AND ') }
    $systems = Get-CimInstance @cim -Query $sysQuery
    if ($CollectionId) {
        $ids = @((Get-CimInstance @cim -Query "SELECT ResourceID FROM SMS_FullCollectionMembership WHERE CollectionID='$CollectionId'").ResourceID)
        $systems = $systems | Where-Object { $ids -contains $_.ResourceId }
    }

    $index = { param($rows) $h = @{}; foreach ($r in $rows) { $h[[int]$r.ResourceID] = $r }; $h }
    $cs   = & $index (Get-CimInstance @cim -Query 'SELECT ResourceID, Manufacturer, Model, TotalPhysicalMemory FROM SMS_G_System_COMPUTER_SYSTEM')
    $os   = & $index (Get-CimInstance @cim -Query 'SELECT ResourceID, Caption, BuildNumber, Version, LastBootUpTime, InstallDate FROM SMS_G_System_OPERATING_SYSTEM')
    $bios = & $index (Get-CimInstance @cim -Query 'SELECT ResourceID, SerialNumber, SMBIOSBIOSVersion FROM SMS_G_System_PC_BIOS')

    $report = foreach ($s in $systems) {
        $id = [int]$s.ResourceId
        [pscustomobject]@{
            Name          = $s.Name
            ResourceID    = $id
            Client        = [bool]$s.Client
            ClientVersion = $s.ClientVersion
            LastUser      = $s.LastLogonUserName
            ADSite        = $s.ADSiteName
            Manufacturer  = $cs[$id].Manufacturer
            Model         = $cs[$id].Model
            MemoryGB      = if ($cs[$id].TotalPhysicalMemory) { [math]::Round($cs[$id].TotalPhysicalMemory / 1MB, 1) } else { $null }  # value is KB
            OS            = $os[$id].Caption
            Build         = $os[$id].BuildNumber
            LastBoot      = $os[$id].LastBootUpTime
            Serial        = $bios[$id].SerialNumber
            BIOSVersion   = $bios[$id].SMBIOSBIOSVersion
        }
    }
    if ($OutputPath) { $report | Export-Csv -Path $OutputPath -NoTypeInformation }
    $report
}

