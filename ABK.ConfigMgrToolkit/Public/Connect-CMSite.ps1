function Connect-CMSite {
    <#
    .SYNOPSIS
        Imports the ConfigurationManager module and connects to a site PSDrive.
    .DESCRIPTION
        Locates the module via $ENV:SMS_ADMIN_UI_PATH (set by the admin console installer),
        imports it, creates the CMSite PSDrive if missing, and optionally sets location to it.
    .PARAMETER SiteCode
        Three-character site code (e.g. HOU).
    .PARAMETER ProviderMachineName
        FQDN of the SMS Provider / site server.
    .PARAMETER NoSetLocation
        Do not change the current location to the site drive.
    .EXAMPLE
        Connect-CMSite -SiteCode HOU -ProviderMachineName cm01.contoso.com
    .NOTES
        Requires the Configuration Manager console. Windows only. PS7 supported from CM 2103.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]{3}$')][string]$SiteCode,
        [Parameter(Mandatory)][Alias('SiteServer')][string]$ProviderMachineName,
        [switch]$NoSetLocation
    )

    if (-not (Get-Module -Name ConfigurationManager)) {
        if (-not $ENV:SMS_ADMIN_UI_PATH) {
            throw 'SMS_ADMIN_UI_PATH is not set. Install the Configuration Manager console on this machine.'
        }
        $modulePath = Join-Path (Split-Path $ENV:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1'
        if (-not (Test-Path -LiteralPath $modulePath)) { throw "Module not found at $modulePath" }
        Write-Verbose "Importing $modulePath"
        Import-Module $modulePath -ErrorAction Stop
    }

    if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        Write-Verbose "Creating PSDrive $SiteCode -> $ProviderMachineName"
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName -Scope Global -ErrorAction Stop | Out-Null
    }

    if (-not $NoSetLocation) { Set-Location "$($SiteCode):\" }
    Get-PSDrive -Name $SiteCode -PSProvider CMSite
}

