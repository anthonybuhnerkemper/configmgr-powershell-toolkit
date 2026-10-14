function New-CMPackageAndDeploy {
    <#
    .SYNOPSIS
        Creates a legacy package + standard program, distributes, and deploys to a collection.
    .DESCRIPTION
        New-CMPackage -> New-CMProgram -> Start-CMContentDistribution -> New-CMPackageDeployment -StandardProgram.
        Defaults to Available. Required deployments run once at -RunAt (New-CMSchedule -Start ... -Nonrecurring).
    .PARAMETER SiteCode
        Site code.
    .PARAMETER ProviderMachineName
        SMS Provider server.
    .PARAMETER Name
        Package name.
    .PARAMETER SourcePath
        UNC source folder.
    .PARAMETER ProgramName
        Program name.
    .PARAMETER CommandLine
        Program command line (relative to the package root).
    .PARAMETER DistributionPointGroupName
        DP group.
    .PARAMETER DistributionPointName
        DP FQDN(s).
    .PARAMETER CollectionName
        Target device collection.
    .PARAMETER DeployPurpose
        Available (default) or Required.
    .PARAMETER RunAt
        Assignment time for Required.
    .PARAMETER AllowBuiltInCollection
        Permit targeting built-in SMS* collections.
    .EXAMPLE
        New-CMPackageAndDeploy -SiteCode HOU -ProviderMachineName cm01 -Name 'HOU - Clear Teams Cache' `
            -SourcePath '\\fs01\sources$\Scripts\TeamsCache' -ProgramName Run `
            -CommandLine 'powershell.exe -ExecutionPolicy Bypass -File .\Clear-TeamsCache' `
            -DistributionPointGroupName 'All DPs' -CollectionName 'Pilot - IT Workstations' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SiteCode,
        [Parameter(Mandatory)][Alias('SiteServer')][string]$ProviderMachineName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidatePattern('^\\\\')][string]$SourcePath,
        [string]$ProgramName = 'Install',
        [Parameter(Mandatory)][string]$CommandLine,
        [string]$DistributionPointGroupName,
        [string[]]$DistributionPointName,
        [Parameter(Mandatory)][string]$CollectionName,
        [ValidateSet('Available','Required')][string]$DeployPurpose = 'Available',
        [datetime]$RunAt = (Get-Date).AddHours(1),
        [switch]$AllowBuiltInCollection
    )
    if (-not $DistributionPointGroupName -and -not $DistributionPointName) { throw 'Specify -DistributionPointGroupName or -DistributionPointName.' }

    Connect-CMSite -SiteCode $SiteCode -ProviderMachineName $ProviderMachineName -NoSetLocation | Out-Null
    Push-Location "$($SiteCode):\"
    try {
        $coll = Get-CMDeviceCollection -Name $CollectionName
        if (-not $coll) { throw "Collection '$CollectionName' not found." }
        if ($coll.CollectionID -like 'SMS*' -and -not $AllowBuiltInCollection) {
            throw "Refusing to deploy to built-in collection $($coll.CollectionID)."
        }

        $pkg = Get-CMPackage -Name $Name -Fast
        if (-not $pkg -and $PSCmdlet.ShouldProcess($Name, "New-CMPackage ($SourcePath)")) {
            $pkg = New-CMPackage -Name $Name -Path $SourcePath
        }
        if ($PSCmdlet.ShouldProcess("$Name\$ProgramName", 'New-CMProgram')) {
            New-CMProgram -PackageName $Name -StandardProgramName $ProgramName -CommandLine $CommandLine `
                -RunType Hidden -ProgramRunType WhetherOrNotUserIsLoggedOn -RunMode RunWithAdministrativeRights | Out-Null
        }
        $dist = @{ PackageName = $Name }
        if ($DistributionPointGroupName) { $dist.DistributionPointGroupName = $DistributionPointGroupName }
        if ($DistributionPointName) { $dist.DistributionPointName = $DistributionPointName }
        if ($PSCmdlet.ShouldProcess($Name, 'Start-CMContentDistribution')) { Start-CMContentDistribution @dist }

        $dep = @{ StandardProgram = $true; PackageName = $Name; ProgramName = $ProgramName; CollectionName = $CollectionName; DeployPurpose = $DeployPurpose }
        if ($DeployPurpose -eq 'Required') { $dep.Schedule = New-CMSchedule -Start $RunAt -Nonrecurring }
        if ($PSCmdlet.ShouldProcess("$Name\$ProgramName -> $CollectionName", "New-CMPackageDeployment ($DeployPurpose)")) {
            New-CMPackageDeployment @dep
        }
    } finally {
        Pop-Location
    }
}

