<#
.SYNOPSIS
    Triggers machine policy retrieval + evaluation on many clients from a list or a collection.
.DESCRIPTION
    Source devices from -ComputerName, a text file (-InputFile, one name per line), or a
    collection (-CollectionId, resolved via the SMS Provider). Two modes:
      Direct       - CIM TriggerSchedule on each client (needs WinRM/DCOM + local admin), parallel on PS7.
      Notification - Invoke-CMClientNotification via the site (needs the console module, no client remoting).
.PARAMETER SiteCode
    Site code (needed for -CollectionId or Notification mode).
.PARAMETER ProviderMachineName
    SMS Provider server.
.PARAMETER ComputerName
    Explicit device names.
.PARAMETER InputFile
    Text file with device names.
.PARAMETER CollectionId
    Collection whose members are targeted.
.PARAMETER Mode
    Direct or Notification.
.PARAMETER ThrottleLimit
    Parallelism for Direct mode on PowerShell 7.
.EXAMPLE
    .\Invoke-CMClientPolicyRefreshBulk.ps1 -SiteCode HOU -ProviderMachineName cm01 -CollectionId HOU00042 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SiteCode,
    [Alias('SiteServer')][string]$ProviderMachineName,
    [string[]]$ComputerName,
    [string]$InputFile,
    [string]$CollectionId,
    [ValidateSet('Direct','Notification')][string]$Mode = 'Direct',
    [ValidateRange(1,128)][int]$ThrottleLimit = 32
)

if (($CollectionId -or $Mode -eq 'Notification') -and (-not $SiteCode -or -not $ProviderMachineName)) {
    throw '-SiteCode and -ProviderMachineName are required for -CollectionId or Notification mode.'
}

if ($Mode -eq 'Notification' -and $CollectionId -and -not $ComputerName -and -not $InputFile) {
    & (Join-Path $PSScriptRoot 'Connect-CMSite.ps1') -SiteCode $SiteCode -ProviderMachineName $ProviderMachineName | Out-Null
    if ($PSCmdlet.ShouldProcess("Collection $CollectionId", 'Invoke-CMClientNotification DownloadComputerPolicy')) {
        Invoke-CMClientNotification -DeviceCollectionId $CollectionId -ActionType DownloadComputerPolicy
    }
    return
}

$names = [System.Collections.Generic.List[string]]::new()
if ($ComputerName) { $names.AddRange([string[]]$ComputerName) }
if ($InputFile) { Get-Content -LiteralPath $InputFile | Where-Object { $_.Trim() } | ForEach-Object { $names.Add($_.Trim()) } }
if ($CollectionId) {
    Get-CimInstance -ComputerName $ProviderMachineName -Namespace "root\SMS\site_$SiteCode" -ErrorAction Stop `
        -Query "SELECT Name FROM SMS_FullCollectionMembership WHERE CollectionID = '$CollectionId'" |
        ForEach-Object { $names.Add($_.Name) }
}
$names = $names | Sort-Object -Unique
if (-not $names) { Write-Warning 'No devices to target.'; return }
Write-Verbose "Targeting $($names.Count) device(s) in $Mode mode."

if ($Mode -eq 'Notification') {
    & (Join-Path $PSScriptRoot 'Connect-CMSite.ps1') -SiteCode $SiteCode -ProviderMachineName $ProviderMachineName | Out-Null
    foreach ($n in $names) {
        if ($PSCmdlet.ShouldProcess($n, 'Invoke-CMClientNotification DownloadComputerPolicy')) {
            Invoke-CMClientNotification -DeviceName $n -ActionType DownloadComputerPolicy
        }
    }
    return
}

if (-not $PSCmdlet.ShouldProcess("$($names.Count) device(s)", 'Trigger Machine Policy Retrieval + Evaluation')) { return }

$block = {
    param($c)
    $ids = '{00000000-0000-0000-0000-000000000021}', '{00000000-0000-0000-0000-000000000022}'
    try {
        foreach ($id in $ids) {
            Invoke-CimMethod -ComputerName $c -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule `
                -Arguments @{ sScheduleID = $id } -OperationTimeoutSec 30 -ErrorAction Stop | Out-Null
        }
        [pscustomobject]@{ ComputerName = $c; Result = 'Triggered' }
    } catch {
        [pscustomobject]@{ ComputerName = $c; Result = "Failed: $($_.Exception.Message)" }
    }
}

if ($PSVersionTable.PSVersion.Major -ge 7) {
    $text = $block.ToString()
    $names | ForEach-Object -Parallel { & ([scriptblock]::Create($using:text)) $_ } -ThrottleLimit $ThrottleLimit
} else {
    foreach ($n in $names) { & $block $n }
}
