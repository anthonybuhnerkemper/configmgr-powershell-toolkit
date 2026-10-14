function Invoke-CMClientAction {
    <#
    .SYNOPSIS
        Triggers Configuration Manager client actions remotely via SMS_Client.TriggerSchedule.
    .DESCRIPTION
        Uses Invoke-CimMethod against root\ccm on each target. Supports friendly action names
        or a raw schedule ID GUID. Supports WSMan (default) or DCOM.
    .PARAMETER ComputerName
        One or more target computers.
    .PARAMETER Action
        Friendly action name(s).
    .PARAMETER ScheduleId
        Raw schedule ID, e.g. {00000000-0000-0000-0000-000000000021}.
    .PARAMETER Protocol
        Wsman or Dcom.
    .EXAMPLE
        Invoke-CMClientAction -ComputerName PC01,PC02 -Action MachinePolicyRetrieval,MachinePolicyEvaluation -WhatIf
    .EXAMPLE
        Invoke-CMClientAction -ComputerName PC01 -ScheduleId '{00000000-0000-0000-0000-000000000113}'
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Action')]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('Name')][string[]]$ComputerName,
        [Parameter(Mandatory, ParameterSetName = 'Action')]
        [ValidateSet('HardwareInventory','SoftwareInventory','DiscoveryDataRecord','FileCollection',
            'MachinePolicyRetrieval','MachinePolicyEvaluation','SoftwareMeteringUsageReport',
            'WindowsInstallerSourceListUpdate','SoftwareUpdatesAssignmentsEvaluation','StateMessageRefresh',
            'SoftwareUpdateScan','SoftwareUpdateDeploymentEvaluation','ApplicationDeploymentEvaluation')]
        [string[]]$Action,
        [Parameter(Mandatory, ParameterSetName = 'Id')][ValidatePattern('^\{[0-9A-Fa-f-]{36}\}$')][string]$ScheduleId,
        [ValidateSet('Wsman','Dcom')][string]$Protocol = 'Wsman'
    )
    begin {
        $map = @{
            HardwareInventory                    = '{00000000-0000-0000-0000-000000000001}'
            SoftwareInventory                    = '{00000000-0000-0000-0000-000000000002}'
            DiscoveryDataRecord                  = '{00000000-0000-0000-0000-000000000003}'
            FileCollection                       = '{00000000-0000-0000-0000-000000000010}'
            MachinePolicyRetrieval               = '{00000000-0000-0000-0000-000000000021}'
            MachinePolicyEvaluation              = '{00000000-0000-0000-0000-000000000022}'
            SoftwareMeteringUsageReport          = '{00000000-0000-0000-0000-000000000031}'
            WindowsInstallerSourceListUpdate     = '{00000000-0000-0000-0000-000000000032}'
            SoftwareUpdatesAssignmentsEvaluation = '{00000000-0000-0000-0000-000000000108}'
            StateMessageRefresh                  = '{00000000-0000-0000-0000-000000000111}'
            SoftwareUpdateScan                   = '{00000000-0000-0000-0000-000000000113}'
            SoftwareUpdateDeploymentEvaluation   = '{00000000-0000-0000-0000-000000000114}'
            ApplicationDeploymentEvaluation      = '{00000000-0000-0000-0000-000000000121}'
        }
        $targets = if ($PSCmdlet.ParameterSetName -eq 'Id') { @{ $ScheduleId = $ScheduleId } } else {
            $h = [ordered]@{}; foreach ($a in $Action) { $h[$a] = $map[$a] }; $h }
        $opt = New-CimSessionOption -Protocol $Protocol
    }
    process {
        foreach ($c in $ComputerName) {
            $session = $null
            try {
                $session = New-CimSession -ComputerName $c -SessionOption $opt -ErrorAction Stop
                foreach ($k in $targets.Keys) {
                    $id = $targets[$k]
                    if ($PSCmdlet.ShouldProcess($c, "TriggerSchedule $k $id")) {
                        try {
                            $r = Invoke-CimMethod -CimSession $session -Namespace root\ccm -ClassName SMS_Client `
                                -MethodName TriggerSchedule -Arguments @{ sScheduleID = $id } -ErrorAction Stop
                            [pscustomobject]@{ ComputerName = $c; Action = $k; ScheduleId = $id; Result = 'Triggered'; ReturnValue = $r.ReturnValue }
                        } catch {
                            [pscustomobject]@{ ComputerName = $c; Action = $k; ScheduleId = $id; Result = "Failed: $($_.Exception.Message)"; ReturnValue = $null }
                        }
                    }
                }
            } catch {
                [pscustomobject]@{ ComputerName = $c; Action = 'Connect'; ScheduleId = $null; Result = "Unreachable: $($_.Exception.Message)"; ReturnValue = $null }
            } finally {
                if ($session) { Remove-CimSession $session }
            }
        }
    }
}

