<#
.SYNOPSIS
    Creates an MSI application + deployment type, distributes content, and deploys to a pilot collection.
.DESCRIPTION
    New-CMApplication -> Add-CMMsiDeploymentType -> Start-CMContentDistribution -> New-CMApplicationDeployment.
    Defaults to an Available deployment. Each step is gated by ShouldProcess, so -WhatIf shows the plan.
    Refuses built-in collections (SMS*) unless -AllowBuiltInCollection is specified.
.PARAMETER SiteCode
    Site code.
.PARAMETER ProviderMachineName
    SMS Provider server.
.PARAMETER Name
    Application name.
.PARAMETER Publisher
    Publisher.
.PARAMETER SoftwareVersion
    Version string.
.PARAMETER MsiPath
    UNC path to the MSI (readable by the site server computer account).
.PARAMETER DistributionPointGroupName
    DP group to distribute to (or use -DistributionPointName).
.PARAMETER DistributionPointName
    DP FQDN(s).
.PARAMETER CollectionName
    Pilot device collection.
.PARAMETER DeployPurpose
    Available (default) or Required.
.PARAMETER DeadlineDateTime
    Deadline for Required deployments (defaults to +3 days).
.PARAMETER AllowBuiltInCollection
    Permit targeting built-in SMS* collections.
.EXAMPLE
    .\New-CMAppAndDeploy.ps1 -SiteCode HOU -ProviderMachineName cm01 -Name '7-Zip 24.08 x64' -Publisher 'Igor Pavlov' `
        -SoftwareVersion 24.08 -MsiPath '\\fs01\sources$\7zip\7z2408-x64.msi' -DistributionPointGroupName 'All DPs' `
        -CollectionName 'Pilot - IT Workstations' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SiteCode,
    [Parameter(Mandatory)][Alias('SiteServer')][string]$ProviderMachineName,
    [Parameter(Mandatory)][string]$Name,
    [string]$Publisher,
    [string]$SoftwareVersion,
    [Parameter(Mandatory)][ValidatePattern('^\\\\.+\.msi$')][string]$MsiPath,
    [string]$DistributionPointGroupName,
    [string[]]$DistributionPointName,
    [Parameter(Mandatory)][string]$CollectionName,
    [ValidateSet('Available','Required')][string]$DeployPurpose = 'Available',
    [datetime]$DeadlineDateTime = (Get-Date).AddDays(3),
    [switch]$AllowBuiltInCollection
)
if (-not $DistributionPointGroupName -and -not $DistributionPointName) { throw 'Specify -DistributionPointGroupName or -DistributionPointName.' }

& (Join-Path $PSScriptRoot 'Connect-CMSite.ps1') -SiteCode $SiteCode -ProviderMachineName $ProviderMachineName -NoSetLocation | Out-Null
Push-Location "$($SiteCode):\"
try {
    $coll = Get-CMDeviceCollection -Name $CollectionName
    if (-not $coll) { throw "Collection '$CollectionName' not found." }
    if ($coll.CollectionID -like 'SMS*' -and -not $AllowBuiltInCollection) {
        throw "Refusing to deploy to built-in collection $($coll.CollectionID). Use -AllowBuiltInCollection if intentional."
    }
    Write-Verbose "Target collection $($coll.CollectionID) has $($coll.MemberCount) member(s)."

    $app = Get-CMApplication -Name $Name -Fast
    if ($app) { Write-Warning "Application '$Name' already exists; reusing it." }
    elseif ($PSCmdlet.ShouldProcess($Name, 'New-CMApplication')) {
        $p = @{ Name = $Name; AutoInstall = $true }
        if ($Publisher) { $p.Publisher = $Publisher }
        if ($SoftwareVersion) { $p.SoftwareVersion = $SoftwareVersion }
        $app = New-CMApplication @p
    }

    if ($PSCmdlet.ShouldProcess($Name, "Add-CMMsiDeploymentType from $MsiPath")) {
        Add-CMMsiDeploymentType -ApplicationName $Name -DeploymentTypeName "$Name - MSI" -ContentLocation $MsiPath `
            -InstallationBehaviorType InstallForSystem -LogonRequirementType WhetherOrNotUserLoggedOn `
            -UserInteractionMode Hidden -Force | Out-Null
    }

    $dist = @{ ApplicationName = $Name }
    if ($DistributionPointGroupName) { $dist.DistributionPointGroupName = $DistributionPointGroupName }
    if ($DistributionPointName) { $dist.DistributionPointName = $DistributionPointName }
    if ($PSCmdlet.ShouldProcess($Name, 'Start-CMContentDistribution')) {
        Start-CMContentDistribution @dist
    }

    $dep = @{ Name = $Name; CollectionName = $CollectionName; DeployAction = 'Install'; DeployPurpose = $DeployPurpose; UserNotification = 'DisplayAll'; AvailableDateTime = (Get-Date) }
    if ($DeployPurpose -eq 'Required') { $dep.DeadlineDateTime = $DeadlineDateTime }
    if ($PSCmdlet.ShouldProcess("$Name -> $CollectionName", "New-CMApplicationDeployment ($DeployPurpose)")) {
        New-CMApplicationDeployment @dep
    }
} finally {
    Pop-Location
}
