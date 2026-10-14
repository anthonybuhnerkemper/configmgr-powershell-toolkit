function Get-CMSoftwareUpdateCompliance {
    <#
    .SYNOPSIS
        Software update compliance per device for a Software Update Group (site) or live from clients.
    .DESCRIPTION
        Site mode: uses SMS_AuthorizationList (SUG) -> Updates CI_IDs, then SMS_UpdateComplianceStatus for
        members of -CollectionId. Status: 0 Unknown, 1 NotRequired, 2 Required (missing), 3 Installed.
        Live mode: lists CCM_SoftwareUpdate (applicable, not yet installed) on each client.
    .PARAMETER SiteCode
        Site code.
    .PARAMETER ProviderMachineName
        SMS Provider server.
    .PARAMETER SoftwareUpdateGroupName
        SUG name (LocalizedDisplayName).
    .PARAMETER CollectionId
        Collection to evaluate.
    .PARAMETER Summary
        Return one row per device with counts instead of per-update rows.
    .PARAMETER ComputerName
        Live mode targets.
    .EXAMPLE
        Get-CMSoftwareUpdateCompliance -SiteCode HOU -ProviderMachineName cm01 -SoftwareUpdateGroupName 'HOU - 2026-10 Pilot' -CollectionId HOU00042 -Summary
    .EXAMPLE
        Get-CMSoftwareUpdateCompliance -ComputerName PC01
    #>
    [CmdletBinding(DefaultParameterSetName = 'Site')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Site')][string]$SiteCode,
        [Parameter(Mandatory, ParameterSetName = 'Site')][Alias('SiteServer')][string]$ProviderMachineName,
        [Parameter(Mandatory, ParameterSetName = 'Site')][string]$SoftwareUpdateGroupName,
        [Parameter(Mandatory, ParameterSetName = 'Site')][string]$CollectionId,
        [Parameter(ParameterSetName = 'Site')][switch]$Summary,
        [Parameter(Mandatory, ParameterSetName = 'Live')][string[]]$ComputerName
    )
    $evalMap = @{ 0 = 'None'; 1 = 'Available'; 2 = 'Submitted'; 3 = 'Detecting'; 4 = 'PreDownload'; 5 = 'Downloading'; 6 = 'WaitInstall'; 7 = 'Installing'; 8 = 'PendingSoftReboot'; 9 = 'PendingHardReboot'; 10 = 'WaitReboot'; 11 = 'Verifying'; 12 = 'InstallComplete'; 13 = 'Error'; 14 = 'WaitServiceWindow' }

    if ($PSCmdlet.ParameterSetName -eq 'Live') {
        foreach ($c in $ComputerName) {
            try {
                Get-CimInstance -ComputerName $c -Namespace root\ccm\ClientSDK -ClassName CCM_SoftwareUpdate -ErrorAction Stop |
                    ForEach-Object {
                        [pscustomobject]@{ ComputerName = $c; ArticleID = "KB$($_.ArticleID)"; Name = $_.Name; State = $evalMap[[int]$_.EvaluationState]; Deadline = $_.Deadline; ErrorCode = $_.ErrorCode }
                    }
            } catch { Write-Warning "$c : $($_.Exception.Message)" }
        }
        return
    }

    $cim = @{ ComputerName = $ProviderMachineName; Namespace = "root\SMS\site_$SiteCode"; ErrorAction = 'Stop' }
    $sug = Get-CimInstance @cim -ClassName SMS_AuthorizationList -Filter "LocalizedDisplayName='$($SoftwareUpdateGroupName -replace "'", "''")'"
    if (-not $sug) { throw "SUG '$SoftwareUpdateGroupName' not found." }
    $sug = $sug | Get-CimInstance   # load lazy Updates property
    $ciIds = @($sug.Updates)
    if (-not $ciIds) { Write-Warning 'SUG contains no updates.'; return }

    $updates = @{}
    foreach ($chunk in 0..([math]::Floor(($ciIds.Count - 1) / 50))) {
        $slice = $ciIds[($chunk * 50)..([math]::Min($ciIds.Count, ($chunk + 1) * 50) - 1)]
        Get-CimInstance @cim -Query ("SELECT CI_ID, ArticleID, LocalizedDisplayName FROM SMS_SoftwareUpdate WHERE CI_ID IN (" + ($slice -join ',') + ")") |
            ForEach-Object { $updates[[int]$_.CI_ID] = $_ }
    }
    $members = @{}
    Get-CimInstance @cim -Query "SELECT ResourceID, Name FROM SMS_FullCollectionMembership WHERE CollectionID='$CollectionId'" | ForEach-Object { $members[[int]$_.ResourceID] = $_.Name }

    $statusMap = @{ 0 = 'Unknown'; 1 = 'NotRequired'; 2 = 'Required'; 3 = 'Installed' }
    $rows = foreach ($ci in $updates.Keys) {
        Get-CimInstance @cim -Query "SELECT ResourceID, CI_ID, Status, LastStatusCheckTime FROM SMS_UpdateComplianceStatus WHERE CI_ID = $ci" |
            Where-Object { $members.ContainsKey([int]$_.ResourceID) } |
            ForEach-Object {
                [pscustomobject]@{
                    ComputerName = $members[[int]$_.ResourceID]
                    ArticleID    = "KB$($updates[$ci].ArticleID)"
                    Update       = $updates[$ci].LocalizedDisplayName
                    Status       = $statusMap[[int]$_.Status]
                    LastChecked  = $_.LastStatusCheckTime
                }
            }
    }
    if ($Summary) {
        $rows | Group-Object ComputerName | ForEach-Object {
            $g = $_.Group
            [pscustomobject]@{
                ComputerName = $_.Name
                Required     = @($g | Where-Object Status -eq 'Required').Count
                Installed    = @($g | Where-Object Status -eq 'Installed').Count
                NotRequired  = @($g | Where-Object Status -eq 'NotRequired').Count
                Unknown      = @($g | Where-Object Status -eq 'Unknown').Count
                Compliant    = -not ($g | Where-Object { $_.Status -in 'Required', 'Unknown' })
            }
        } | Sort-Object Compliant, ComputerName
    } else { $rows }
}

