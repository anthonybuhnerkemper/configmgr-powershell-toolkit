function Invoke-CMAppInstallOnClient {
    <#
    .SYNOPSIS
        Installs (or uninstalls) an application deployed to a client via CCM_Application in root\ccm\ClientSDK.
    .DESCRIPTION
        Equivalent to clicking Install in Software Center. The application must already be deployed
        (Available or Required) to the device. Matches by exact application name (FullName/Name).
    .PARAMETER ComputerName
        Target computers.
    .PARAMETER ApplicationName
        Application name as shown in Software Center.
    .PARAMETER Action
        Install (default) or Uninstall.
    .PARAMETER Priority
        Foreground, High, Normal, Low.
    .EXAMPLE
        Invoke-CMAppInstallOnClient -ComputerName PC01 -ApplicationName '7-Zip 24.08 x64' -WhatIf
    .NOTES
        CCM_Application only returns user-targeted apps for the logged-on user context; device-targeted
        deployments are returned when queried remotely as SYSTEM/admin. IsMachineTarget is passed accordingly.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('Name')][string[]]$ComputerName,
        [Parameter(Mandatory)][string]$ApplicationName,
        [ValidateSet('Install','Uninstall')][string]$Action = 'Install',
        [ValidateSet('Foreground','High','Normal','Low')][string]$Priority = 'High'
    )
    process {
        foreach ($c in $ComputerName) {
            try {
                $app = Get-CimInstance -ComputerName $c -Namespace root\ccm\ClientSDK -ClassName CCM_Application -ErrorAction Stop |
                    Where-Object { $_.FullName -eq $ApplicationName -or $_.Name -eq $ApplicationName } | Select-Object -First 1
                if (-not $app) {
                    [pscustomobject]@{ ComputerName = $c; Application = $ApplicationName; Result = 'NotDeployedToDevice'; ReturnValue = $null }
                    continue
                }
                if ($Action -eq 'Install' -and $app.InstallState -eq 'Installed') {
                    [pscustomobject]@{ ComputerName = $c; Application = $ApplicationName; Result = 'AlreadyInstalled'; ReturnValue = $null }
                    continue
                }
                if ($PSCmdlet.ShouldProcess($c, "$Action '$ApplicationName' (rev $($app.Revision))")) {
                    $r = Invoke-CimMethod -ComputerName $c -Namespace root\ccm\ClientSDK -ClassName CCM_Application -MethodName $Action -ErrorAction Stop -Arguments @{
                        Id               = [string]$app.Id
                        Revision         = [string]$app.Revision
                        IsMachineTarget  = [bool]$app.IsMachineTarget
                        EnforcePreference = [uint32]0
                        Priority         = $Priority
                        IsRebootIfNeeded = $false
                    }
                    [pscustomobject]@{ ComputerName = $c; Application = $ApplicationName; Result = 'Requested'; ReturnValue = $r.ReturnValue }
                }
            } catch {
                [pscustomobject]@{ ComputerName = $c; Application = $ApplicationName; Result = "Failed: $($_.Exception.Message)"; ReturnValue = $null }
            }
        }
    }
}

