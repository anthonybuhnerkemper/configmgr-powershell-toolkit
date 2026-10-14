function Test-CMClientConnectivity {
    <#
    .SYNOPSIS
        Live connectivity check for ConfigMgr clients: ping, WinRM, CcmExec service, client version.
    .PARAMETER ComputerName
        Target computers.
    .PARAMETER TimeoutSeconds
        Operation timeout for CIM calls.
    .EXAMPLE
        Get-Content .\pcs.txt | .\Test-CMClientConnectivity | Format-Table
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('Name')][string[]]$ComputerName,
        [ValidateRange(1,300)][int]$TimeoutSeconds = 15
    )
    process {
        foreach ($c in $ComputerName) {
            $r = [ordered]@{ ComputerName = $c; DnsResolves = $false; Ping = $false; WinRM = $false; CcmExec = $null; ClientVersion = $null; Error = $null }
            try { [void][System.Net.Dns]::GetHostEntry($c); $r.DnsResolves = $true } catch { $r.Error = 'DNS lookup failed' }
            if ($r.DnsResolves) {
                try {
                    $p = New-Object System.Net.NetworkInformation.Ping
                    $r.Ping = ($p.Send($c, 2000).Status -eq 'Success')
                } catch { }
                try { Test-WSMan -ComputerName $c -ErrorAction Stop | Out-Null; $r.WinRM = $true } catch { }
                if ($r.WinRM) {
                    try {
                        $svc = Get-CimInstance -ComputerName $c -ClassName Win32_Service -Filter "Name='CcmExec'" -OperationTimeoutSec $TimeoutSeconds -ErrorAction Stop
                        $r.CcmExec = if ($svc) { "$($svc.State)/$($svc.StartMode)" } else { 'NotInstalled' }
                        if ($svc) {
                            $r.ClientVersion = (Get-CimInstance -ComputerName $c -Namespace root\ccm -ClassName SMS_Client -OperationTimeoutSec $TimeoutSeconds -ErrorAction Stop).ClientVersion
                        }
                    } catch { $r.Error = $_.Exception.Message }
                }
            }
            [pscustomobject]$r
        }
    }
}

