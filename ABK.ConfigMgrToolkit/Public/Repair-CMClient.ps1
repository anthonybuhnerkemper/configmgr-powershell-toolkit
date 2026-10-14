function Repair-CMClient {
    <#
    .SYNOPSIS
        Remediates a ConfigMgr client: WMI RepairClient, service restart, or ccmsetup reinstall.
    .DESCRIPTION
        Method RepairClient : invokes SMS_Client.RepairClient (runs ccmrepair.exe). Least invasive.
        Method RestartService: restarts CcmExec via Invoke-Command.
        Method Reinstall    : runs ccmsetup.exe from \\SiteServer\SMS_<SiteCode>\Client with /forceinstall.
        All methods are gated by ShouldProcess with ConfirmImpact High.
    .PARAMETER ComputerName
        Target computers.
    .PARAMETER Method
        RepairClient (default), RestartService, Reinstall.
    .PARAMETER SiteCode
        Site code (Reinstall).
    .PARAMETER SiteServer
        Site server hosting the client source share (Reinstall).
    .PARAMETER ManagementPoint
        Optional MP passed as /mp: (Reinstall).
    .EXAMPLE
        Repair-CMClient -ComputerName PC01 -WhatIf
    .EXAMPLE
        Repair-CMClient -ComputerName PC01 -Method Reinstall -SiteCode HOU -SiteServer cm01.contoso.com
    .NOTES
        Reinstall copies ccmsetup from the share inside the remote session; this requires CredSSP/Kerberos
        delegation or a share readable by the target computer account. Lab-test first.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('Name')][string[]]$ComputerName,
        [ValidateSet('RepairClient','RestartService','Reinstall')][string]$Method = 'RepairClient',
        [string]$SiteCode,
        [Alias('ProviderMachineName')][string]$SiteServer,
        [string]$ManagementPoint
    )
    begin {
        if ($Method -eq 'Reinstall' -and (-not $SiteCode -or -not $SiteServer)) {
            throw 'Reinstall requires -SiteCode and -SiteServer.'
        }
    }
    process {
        foreach ($c in $ComputerName) {
            if (-not $PSCmdlet.ShouldProcess($c, "Repair ConfigMgr client ($Method)")) { continue }
            try {
                switch ($Method) {
                    'RepairClient' {
                        Invoke-CimMethod -ComputerName $c -Namespace root\ccm -ClassName SMS_Client -MethodName RepairClient -ErrorAction Stop | Out-Null
                    }
                    'RestartService' {
                        Invoke-Command -ComputerName $c -ErrorAction Stop -ScriptBlock { Restart-Service -Name CcmExec -Force }
                    }
                    'Reinstall' {
                        $src = "\\$SiteServer\SMS_$SiteCode\Client\ccmsetup.exe"
                        $setupArgs = @('/forceinstall', "SMSSITECODE=$SiteCode")
                        if ($ManagementPoint) { $setupArgs = @("/mp:$ManagementPoint") + $setupArgs }
                        Invoke-Command -ComputerName $c -ErrorAction Stop -ArgumentList $src, $setupArgs -ScriptBlock {
                            param($src, $a)
                            $dst = Join-Path $env:TEMP 'ccmsetup.exe'
                            Copy-Item -LiteralPath $src -Destination $dst -Force
                            Start-Process -FilePath $dst -ArgumentList $a -WindowStyle Hidden
                        }
                    }
                }
                [pscustomobject]@{ ComputerName = $c; Method = $Method; Result = 'Started' }
            } catch {
                [pscustomobject]@{ ComputerName = $c; Method = $Method; Result = "Failed: $($_.Exception.Message)" }
            }
        }
    }
}

