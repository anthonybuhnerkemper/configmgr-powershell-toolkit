# ConfigMgr PowerShell Toolkit

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/ABK.ConfigMgrToolkit?label=PowerShell%20Gallery)](https://www.powershellgallery.com/packages/ABK.ConfigMgrToolkit) [![Downloads](https://img.shields.io/powershellgallery/dt/ABK.ConfigMgrToolkit)](https://www.powershellgallery.com/packages/ABK.ConfigMgrToolkit)

PowerShell scripts and a field guide for managing **Microsoft Configuration Manager** (SCCM / MECM) from the command line: connecting to a site, querying the SMS Provider, triggering client actions, health checks and remediation, application and package deployment, content distribution, and software update compliance.

Maintained by **Anthony Buhnerkemper**, M365 / PowerShell administrator in Houston, TX.

📘 **Read the guide:** [GUIDE.md](GUIDE.md): *Managing Microsoft Configuration Manager (SCCM/MECM) with PowerShell*


## Install from PowerShell Gallery

```powershell
Install-Module ABK.ConfigMgrToolkit -Scope CurrentUser
Import-Module ABK.ConfigMgrToolkit
Get-Command -Module ABK.ConfigMgrToolkit
```

Each script is also exported as a function with the same name and parameters (e.g. `Get-Help <FunctionName> -Full`). Prerequisite modules (Microsoft Graph, ExchangeOnlineManagement, ConfigMgr console, Citrix SDK, etc.) are not auto-installed; install the ones the functions you use need, as described below. The module source lives in [`ABK.ConfigMgrToolkit/`](ABK.ConfigMgrToolkit/).

## Requirements

- Windows PowerShell 5.1, or PowerShell 7.x (ConfigurationManager module supports PS7 from CM 2103)
- Configuration Manager current branch (2203+ recommended)
- **Configuration Manager console** installed for scripts that use the ConfigurationManager module (`Connect-CMSite`, `New-CMAppAndDeploy`, `New-CMPackageAndDeploy`, Notification mode of `Invoke-CMClientPolicyRefreshBulk`)
- Read access to the SMS Provider (`root\SMS\site_<SiteCode>`) for report scripts; a scoped role such as *Read-only Analyst* is enough
- WinRM (or DCOM where noted) and local admin on endpoints for client-side scripts
- Appropriately scoped RBAC role (e.g. *Application Administrator*) for deployment scripts

## Scripts

| Script | Purpose | Changes state? |
|---|---|---|
| `Connect-CMSite.ps1` | Import the module from `$ENV:SMS_ADMIN_UI_PATH`, create the CMSite PSDrive, `Set-Location` | No |
| `Get-CMClientHealthReport.ps1` | Site-side client presence, activity, version, last policy/DDR/HW scan | No |
| `Invoke-CMClientAction.ps1` | Trigger client schedules (`SMS_Client.TriggerSchedule`) by friendly name or GUID | Yes (`-WhatIf`) |
| `Invoke-CMClientPolicyRefreshBulk.ps1` | Machine policy refresh for a list, file, or collection: direct CIM (parallel on PS7) or site notification | Yes (`-WhatIf`) |
| `Get-CMDeviceInventoryReport.ps1` | Make/model/OS/serial/BIOS/memory from hardware inventory | No |
| `Test-CMClientConnectivity.ps1` | DNS, ping, WinRM, CcmExec service, client version | No |
| `Repair-CMClient.ps1` | `RepairClient`, restart CcmExec, or ccmsetup reinstall | Yes (`ConfirmImpact High`) |
| `Get-CMPendingRebootReport.ps1` | Pending reboot via CCM_ClientUtilities + registry, or site `ClientState` | No |
| `Get-CMDeploymentStatusReport.ps1` | Success/error/in-progress counts per deployment (`SMS_DeploymentSummary`) | No |
| `Get-CMContentDistributionStatus.ps1` | Per-DP content state (`SMS_PackageStatusDistPointsSummarizer`) | No |
| `New-CMAppAndDeploy.ps1` | MSI application + DT + distribute + deploy to pilot (defaults to **Available**) | Yes (`-WhatIf`) |
| `New-CMPackageAndDeploy.ps1` | Legacy package + program + distribute + deploy | Yes (`-WhatIf`) |
| `Start-CMContentRedistribution.ps1` | Redistribute content (RefreshNow), optionally only failed DPs | Yes (`-WhatIf`) |
| `Get-CMSoftwareUpdateCompliance.ps1` | SUG compliance per device for a collection, or live from clients | No |
| `Get-CMCollectionMembershipReport.ps1` | Members of a collection, or all collections a device is in | No |
| `Invoke-CMAppInstallOnClient.ps1` | Install/uninstall a deployed app via `CCM_Application` | Yes (`-WhatIf`) |

Every script has comment-based help: `Get-Help .\scripts\<name>.ps1 -Full`.

## Quick start

```powershell
.\scripts\Connect-CMSite.ps1 -SiteCode HOU -ProviderMachineName cm01.contoso.com
.\scripts\Get-CMClientHealthReport.ps1 -SiteCode HOU -ProviderMachineName cm01 -CollectionId HOU00042 -UnhealthyOnly
.\scripts\Invoke-CMClientAction.ps1 -ComputerName PC01 -Action MachinePolicyRetrieval,SoftwareUpdateScan -WhatIf
```

Reports written with `-OutputPath` should go under `reports/`, which is git-ignored.

## Disclaimer

**These scripts are syntax-tested only** (parsed with the PowerShell 7 parser). They have **not** been run against a live Configuration Manager site. Cmdlet parameters vary between ConfigMgr versions. Validate everything in a lab, use `-WhatIf`, and target pilot collections before using any of this in production. Provided as-is under the MIT License, with no warranty.

## License

[MIT](LICENSE) © 2026 Anthony Buhnerkemper
