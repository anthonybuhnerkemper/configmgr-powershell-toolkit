<#
.SYNOPSIS
    Reports pending reboot state from the ConfigMgr client and Windows.
.DESCRIPTION
    Live mode (default): CCM_ClientUtilities.DetermineIfRebootPending plus Windows registry
    indicators via Invoke-Command. Site mode (-SiteCode/-ProviderMachineName/-CollectionId):
    reads the SMS_CombinedDeviceResources.ClientState bitmask without contacting clients.
.PARAMETER ComputerName
    Live mode targets.
.PARAMETER SiteCode
    Site mode site code.
.PARAMETER ProviderMachineName
    Site mode provider.
.PARAMETER CollectionId
    Site mode collection.
.EXAMPLE
    .\Get-CMPendingRebootReport.ps1 -ComputerName PC01,PC02
.EXAMPLE
    .\Get-CMPendingRebootReport.ps1 -SiteCode HOU -ProviderMachineName cm01 -CollectionId HOU00042
#>
[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Live', ValueFromPipeline)][string[]]$ComputerName,
    [Parameter(Mandatory, ParameterSetName = 'Site')][string]$SiteCode,
    [Parameter(Mandatory, ParameterSetName = 'Site')][Alias('SiteServer')][string]$ProviderMachineName,
    [Parameter(Mandatory, ParameterSetName = 'Site')][string]$CollectionId
)
process {
    if ($PSCmdlet.ParameterSetName -eq 'Site') {
        $ns = "root\SMS\site_$SiteCode"
        $ids = @((Get-CimInstance -ComputerName $ProviderMachineName -Namespace $ns -ErrorAction Stop `
            -Query "SELECT ResourceID FROM SMS_FullCollectionMembership WHERE CollectionID='$CollectionId'").ResourceID)
        Get-CimInstance -ComputerName $ProviderMachineName -Namespace $ns -ErrorAction Stop `
            -Query 'SELECT Name, ResourceID, ClientState FROM SMS_CombinedDeviceResources WHERE ClientState > 0' |
            Where-Object { $ids -contains $_.ResourceID } |
            ForEach-Object {
                [pscustomobject]@{
                    ComputerName  = $_.Name
                    ConfigMgr     = [bool]($_.ClientState -band 1)
                    FileRename    = [bool]($_.ClientState -band 2)
                    WindowsUpdate = [bool]($_.ClientState -band 4)
                    Feature       = [bool]($_.ClientState -band 8)
                    Source        = 'Site'
                }
            }
        return
    }
    foreach ($c in $ComputerName) {
        $o = [ordered]@{ ComputerName = $c; ConfigMgr = $null; HardReboot = $null; CBS = $null; WindowsUpdate = $null; FileRename = $null; Source = 'Live'; Error = $null }
        try {
            $r = Invoke-CimMethod -ComputerName $c -Namespace root\ccm\ClientSDK -ClassName CCM_ClientUtilities -MethodName DetermineIfRebootPending -ErrorAction Stop
            $o.ConfigMgr = [bool]$r.RebootPending; $o.HardReboot = [bool]$r.IsHardRebootPending
        } catch { $o.Error = "CCM: $($_.Exception.Message)" }
        try {
            $w = Invoke-Command -ComputerName $c -ErrorAction Stop -ScriptBlock {
                [pscustomobject]@{
                    CBS = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
                    WU  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
                    PFR = [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
                }
            }
            $o.CBS = $w.CBS; $o.WindowsUpdate = $w.WU; $o.FileRename = $w.PFR
        } catch { $o.Error = ($o.Error, "Registry: $($_.Exception.Message)" | Where-Object { $_ }) -join '; ' }
        [pscustomobject]$o
    }
}
