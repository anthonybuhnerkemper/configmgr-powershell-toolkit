# Managing Microsoft Configuration Manager (SCCM/MECM) with PowerShell

*A practical field guide by Anthony Buhnerkemper*

> **Scope and honesty note.** Configuration Manager has gone by several names: SMS, System Center Configuration Manager (SCCM), Microsoft Endpoint Configuration Manager (MECM), and today simply **Configuration Manager** as part of Microsoft Intune family branding. This guide targets **current branch** (version 2203 and later). Where cmdlet behavior or parameters changed between versions, I say so. Cmdlet parameter sets do change between releases, so run `Get-Help <cmdlet> -Full` against *your* console version before you script anything for production. Everything in the companion `scripts/` folder has been syntax-checked, **not** run against a live site. Validate it in a lab first.

---

## Table of Contents

1. [The Three Ways PowerShell Talks to ConfigMgr](#1-the-three-ways-powershell-talks-to-configmgr)
2. [The ConfigurationManager Module](#2-the-configurationmanager-module)
3. [WMI/CIM Against the SMS Provider](#3-wmicim-against-the-sms-provider)
4. [WMI/CIM Against the Client](#4-wmicim-against-the-client)
5. [Client Actions and Trigger Schedules](#5-client-actions-and-trigger-schedules)
6. [Polling and Querying Devices](#6-polling-and-querying-devices)
7. [Applications vs. Packages](#7-applications-vs-packages)
8. [Distribution Points and Content Status](#8-distribution-points-and-content-status)
9. [Software Updates](#9-software-updates)
10. [Client Health and Remediation](#10-client-health-and-remediation)
11. [The Run Scripts Feature](#11-the-run-scripts-feature)
12. [CMPivot](#12-cmpivot)
13. [Safe Practice](#13-safe-practice)
14. [Least Privilege with RBAC](#14-least-privilege-with-rbac)
15. [Quick Reference](#15-quick-reference)

---

## 1. The Three Ways PowerShell Talks to ConfigMgr

There are three distinct surfaces, and knowing which one you are using saves a lot of confusion:

| Surface | Where it runs | What it's good for |
|---|---|---|
| **ConfigurationManager module** | Any machine with the admin console installed | Creating/modifying site objects: apps, packages, deployments, collections, SUGs, ADRs |
| **SMS Provider (WMI/CIM)** | Remote CIM to the provider server, namespace `root\SMS\site_<SiteCode>` | Fast, read-heavy queries; anything the module doesn't expose; works without the console installed |
| **Client WMI/CIM** | Remote CIM to each endpoint, namespaces `root\ccm`, `root\ccm\ClientSDK` | Triggering client actions, installing available apps, checking client state |

The module is a wrapper around the SMS Provider. Every `Get-CMDevice` call ends up as a WQL query against `SMS_R_System` / `SMS_CombinedDeviceResources`. When the module is slow (and some cmdlets, notably `Get-CMDevice` against large collections or `Get-CMSoftwareUpdate` without filters, can be painfully slow), going straight to CIM is a legitimate optimization.

The client side has nothing to do with the module. The module has a few cmdlets that *ask the site* to notify clients (for example `Invoke-CMClientNotification`), but triggering a schedule directly on a client is a CIM call to the client itself.

---

## 2. The ConfigurationManager Module

### 2.1 Where it lives

The module ships with the Configuration Manager console. It is **not** on the PowerShell Gallery. The console installer sets the environment variable `SMS_ADMIN_UI_PATH` to something like:

```
C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\i386
```

The module manifest sits one directory up, in `bin`:

```powershell
$modulePath = Join-Path (Split-Path $ENV:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1'
Import-Module $modulePath
```

That `Split-Path -Parent` idiom is the officially documented approach and works regardless of whether the console is installed under the older "Microsoft Configuration Manager" folder or the newer "Microsoft Endpoint Manager" folder.

### 2.2 PowerShell edition support

- Historically the module was **Windows PowerShell 5.1 only**, and it loaded only in a 32-bit-aware way in very old releases.
- Starting with **version 2103**, the module supports **PowerShell 7** (Core) on Windows. Some cmdlets still had issues in early PS7 builds; if something misbehaves in 7.x, try 5.1 before filing a bug against yourself.
- It is Windows-only. You cannot import it on Linux or macOS.

### 2.3 Connecting: the site PSDrive

Importing the module normally creates a PSDrive named after your site code (for example `HOU:`). It does this only if the current user has already opened the console at least once and the console has the site connection cached. In automation (service accounts, scheduled tasks), it often isn't there, so create it explicitly:

```powershell
$SiteCode     = 'HOU'
$ProviderMachineName = 'cm01.contoso.com'

if (-not (Get-Module ConfigurationManager)) {
    Import-Module (Join-Path (Split-Path $ENV:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1')
}
if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName | Out-Null
}
Set-Location "$($SiteCode):\"
```

This is essentially the snippet the console generates from **Connect via Windows PowerShell** in the top-left menu.

### 2.4 The location trap

Most ConfigMgr cmdlets **only work when your current location is the CMSite drive**. Run `Get-CMDevice` from `C:\` and you get an error telling you to connect to a site. The flip side: while you're on `HOU:\`, cmdlets that use the FileSystem provider (`Test-Path C:\temp`, `Get-ChildItem \\server\share`) can behave strangely because relative paths resolve against the CMSite provider. Common patterns:

```powershell
Push-Location "$($SiteCode):\"
try {
    # ConfigMgr work here
} finally {
    Pop-Location
}
```

And when you need to touch UNC paths for content sources, use the explicit provider-qualified path (`Microsoft.PowerShell.Core\FileSystem::\\fs01\sources$\App`) or step out with `Pop-Location` first.

### 2.5 Discovering cmdlets

```powershell
Get-Command -Module ConfigurationManager | Measure-Object     # 1,000+ cmdlets
Get-Command -Module ConfigurationManager -Noun CMDevice*
Get-CMSite                                                      # sanity check
```

Version note: `Update-Help` does not cover this module in the usual way; documentation lives on Microsoft Learn under **ConfigurationManager**. Several cmdlets have been renamed or deprecated over time (for example, the `*-CMDeploymentType` cmdlets were replaced by technology-specific ones like `Add-CMMsiDeploymentType`; `Start-CMApplicationDeployment` was replaced by `New-CMApplicationDeployment`). Old blog posts frequently show the deprecated names.

---

## 3. WMI/CIM Against the SMS Provider

### 3.1 The namespace

Every primary site and CAS has one or more SMS Providers. The namespace is:

```
root\SMS\site_<SiteCode>
```

If you don't know the site code, query `SMS_ProviderLocation` in `root\SMS`:

```powershell
Get-CimInstance -ComputerName cm01 -Namespace root\SMS -ClassName SMS_ProviderLocation |
    Where-Object ProviderForLocalSite |
    Select-Object SiteCode, Machine
```

### 3.2 Common classes

| Class | What it holds |
|---|---|
| `SMS_R_System` | Discovery data for devices (resource records) |
| `SMS_CombinedDeviceResources` | What the console's Devices node shows; includes client activity & health |
| `SMS_Collection` | Collections (`CollectionType` 2 = device, 1 = user) |
| `SMS_FullCollectionMembership` | Every member of every collection |
| `SMS_G_System_*` | Hardware inventory classes (e.g. `SMS_G_System_OPERATING_SYSTEM`) |
| `SMS_ClientHealthState` / `SMS_CH_Summary` | Client check results |
| `SMS_DeploymentSummary` | Deployment rollups |
| `SMS_PackageStatusDistPointsSummarizer` | Content state per DP per package |
| `SMS_DistributionPointInfo` | DP inventory |
| `SMS_SoftwareUpdate` | Update metadata |
| `SMS_UpdateComplianceStatus` | Per-device update state |
| `SMS_Application`, `SMS_Package`, `SMS_Program` | Content objects |

### 3.3 Example queries

```powershell
$cim = @{ ComputerName = 'cm01'; Namespace = 'root\SMS\site_HOU' }

# Devices with no client or inactive client
Get-CimInstance @cim -ClassName SMS_CombinedDeviceResources -Filter "IsClient = 0 OR ClientActiveStatus = 0" |
    Select-Object Name, IsClient, ClientActiveStatus, LastActiveTime

# Members of a collection
Get-CimInstance @cim -Query "SELECT Name, ResourceID FROM SMS_FullCollectionMembership WHERE CollectionID = 'HOU00042'"

# Join example: OS caption per device (WQL supports JOIN on the provider)
Get-CimInstance @cim -Query @"
SELECT SMS_R_System.Name, SMS_G_System_OPERATING_SYSTEM.Caption, SMS_G_System_OPERATING_SYSTEM.BuildNumber
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
"@
```

> **Lazy properties.** Some provider classes have *lazy* properties (for example `SMS_Collection.CollectionRules`, `SMS_Application.SDMPackageXML`) that are not returned by a query. Pipe the instance to `Get-CimInstance` (with no other parameters) to re-read it fully. With old `Get-WmiObject`, you called `.Get()`.

### 3.4 Why use CIM instead of the module?

- No console install required: a jump box with just PowerShell and network access to the provider can query.
- Faster for bulk reads: you control `SELECT` columns and filters, so you avoid pulling the full object.
- Runs in PowerShell 7 everywhere, with no module compatibility concerns.

The downside: writes via raw WMI are harder and easier to get wrong (you have to build embedded objects yourself). Use the module for writes.

---

## 4. WMI/CIM Against the Client

The ConfigMgr client (`CcmExec`, the "SMS Agent Host" service) exposes several namespaces:

| Namespace | Use |
|---|---|
| `root\ccm` | Core client: `SMS_Client` (TriggerSchedule, RepairClient, version), `CCM_Client` (client ID), `SMS_Authority` (assigned site) |
| `root\ccm\ClientSDK` | Software Center surface: `CCM_Application`, `CCM_SoftwareUpdate`, `CCM_Program`, `CCM_ClientUtilities` (`DetermineIfRebootPending`), `CCM_SoftwareUpdatesManager` |
| `root\ccm\Policy\Machine\ActualConfig` | Effective machine policy (e.g. `CCM_SoftwareUpdatesClientConfig`) |
| `root\ccm\SoftMgmtAgent` | `CCM_ExecutionRequestEx` and other agent internals |
| `root\ccm\SoftwareUpdates\UpdatesStore` | `CCM_UpdateStatus` |
| `root\ccm\CIModels` and `root\ccm\dcm` | Compliance settings (configuration baselines: `SMS_DesiredConfiguration`) |

Quick examples:

```powershell
# Client version and assigned site
Get-CimInstance -ComputerName PC01 -Namespace root\ccm -ClassName SMS_Client | Select-Object ClientVersion
Invoke-CimMethod -ComputerName PC01 -Namespace root\ccm -ClassName SMS_Client -MethodName GetAssignedSite

# Pending reboot (returns RebootPending, IsHardRebootPending, etc.)
Invoke-CimMethod -ComputerName PC01 -Namespace root\ccm\ClientSDK -ClassName CCM_ClientUtilities -MethodName DetermineIfRebootPending

# Missing updates as Software Center sees them
Get-CimInstance -ComputerName PC01 -Namespace root\ccm\ClientSDK -ClassName CCM_SoftwareUpdate |
    Select-Object ArticleID, Name, EvaluationState
```

**Transport.** `Get-CimInstance -ComputerName` uses **WinRM (WS-Man)** by default. Many shops have WinRM locked down but DCOM open (or vice versa). If WinRM isn't available, create a DCOM session:

```powershell
$opt = New-CimSessionOption -Protocol Dcom
$s   = New-CimSession -ComputerName PC01 -SessionOption $opt
Get-CimInstance -CimSession $s -Namespace root\ccm -ClassName SMS_Client
```

The companion scripts accept a `-Protocol` parameter for this reason.

---

## 5. Client Actions and Trigger Schedules

### 5.1 How it works

Every action in the client's Control Panel applet (Configuration Manager Properties → Actions) maps to a **schedule ID**, a GUID. You trigger it with the `TriggerSchedule` static method on `SMS_Client`:

```powershell
Invoke-CimMethod -ComputerName PC01 -Namespace root\ccm -ClassName SMS_Client `
    -MethodName TriggerSchedule -Arguments @{ sScheduleID = '{00000000-0000-0000-0000-000000000021}' }
```

### 5.2 The common schedule IDs

| Action | Schedule ID |
|---|---|
| Hardware Inventory | `{00000000-0000-0000-0000-000000000001}` |
| Software Inventory | `{00000000-0000-0000-0000-000000000002}` |
| Discovery Data Record (Heartbeat) | `{00000000-0000-0000-0000-000000000003}` |
| File Collection | `{00000000-0000-0000-0000-000000000010}` |
| Machine Policy Retrieval | `{00000000-0000-0000-0000-000000000021}` |
| Machine Policy Evaluation | `{00000000-0000-0000-0000-000000000022}` |
| User Policy Retrieval | `{00000000-0000-0000-0000-000000000026}` |
| User Policy Evaluation | `{00000000-0000-0000-0000-000000000027}` |
| Software Metering Usage Report | `{00000000-0000-0000-0000-000000000031}` |
| Windows Installer Source List Update | `{00000000-0000-0000-0000-000000000032}` |
| Software Updates Assignments Evaluation | `{00000000-0000-0000-0000-000000000108}` |
| Software Update Scan | `{00000000-0000-0000-0000-000000000113}` |
| Software Update Deployment Evaluation | `{00000000-0000-0000-0000-000000000114}` |
| Application Deployment Evaluation | `{00000000-0000-0000-0000-000000000121}` |
| State Message Refresh | `{00000000-0000-0000-0000-000000000111}` |

Notes:

- **Full** hardware inventory: delete the existing `InventoryActionStatus` instance for `{...001}` in `root\ccm\invagt` before triggering. That forces a full report instead of a delta. Use it sparingly, because it can flood the site with large MIF files.
- **User Policy** triggers only work in the context of a logged-on user, because they're tied to the user's SID. Remote triggering of `{...026}` as an admin targets *your* policy, not the user's. Generally skip it remotely.
- The **Configuration Baseline** evaluation isn't a schedule ID; you call `TriggerEvaluation` on `SMS_DesiredConfiguration` in `root\ccm\dcm`.

### 5.3 Site-side alternative: client notification

Instead of hitting each client over WinRM/DCOM, you can ask the site to push a notification over the **client notification channel** (port 10123 / fallback HTTP via the management point):

```powershell
Invoke-CMClientNotification -DeviceCollectionId 'HOU00042' -ActionType DownloadComputerPolicy
Invoke-CMClientNotification -DeviceName 'PC01' -ActionType RequestScanForUpdate
```

`-ActionType` values include `DownloadComputerPolicy`, `DownloadUserPolicy`, `CollectDiscoveryData`, `CollectSoftwareInventory`, `CollectHardwareInventory`, `EvaluateApplicationDeployment`, `EvaluateSoftwareUpdateDeployment`, `SwitchToNextSoftwareUpdatePoint`, `EvaluateDeviceHealthAttestation`, `CheckConditionalAccessCompliance`, `WakeUp`, `Restart`, `RequestScanForUpdate`... The available values depend on version; check `Get-Help Invoke-CMClientNotification -Parameter ActionType`. Older versions only had `Invoke-CMClientAction` (now deprecated in favor of `Invoke-CMClientNotification`).

This is the better approach for big batches: no remote management firewall rules required to every endpoint, and the work is throttled by the site.

---

## 6. Polling and Querying Devices

### 6.1 Module cmdlets

```powershell
Get-CMDevice -Name 'PC01'
Get-CMDevice -CollectionName 'All Houston Workstations' -Fast |
    Select-Object Name, ClientVersion, LastActiveTime, ClientActiveStatus, IsActive
Get-CMCollection -Name 'All Houston Workstations'
Get-CMCollectionMember -CollectionName 'All Houston Workstations'
```

**Use `-Fast`.** `Get-CMDevice` without `-Fast` loads lazy properties for every object, which is extremely slow for big collections. `-Fast` skips them. (Present since roughly 1810; on very old builds it may not exist.)

`Get-CMCollectionMember` was added later than `Get-CMDevice -CollectionName`; both work on current branch.

### 6.2 What the console "Client Activity" means

`SMS_CombinedDeviceResources.ClientActiveStatus` is `1` when the client has done *something* (heartbeat DDR, hardware inventory, policy request, status message) within the **client activity** thresholds in Client Status Settings (default 7 days). An "active" client in the console doesn't prove the machine is online right now. That's why the toolkit separates **site-side health** (`Get-CMClientHealthReport`) from **live connectivity** (`Test-CMClientConnectivity`).

### 6.3 Live checks

```powershell
Test-Connection -ComputerName PC01 -Count 1 -Quiet          # ICMP (5.1 syntax; PS7 uses -TargetName)
Test-WSMan -ComputerName PC01 -ErrorAction SilentlyContinue  # WinRM listener
Get-Service -ComputerName PC01 -Name CcmExec                 # 5.1 only; PS7 removed -ComputerName
```

Version differences to watch:

- PowerShell 7 renamed `Test-Connection -ComputerName` to `-TargetName` (`-ComputerName` remains an alias in 7.x) and changed its output objects.
- `Get-Service -ComputerName` was **removed** in PowerShell 7. Query `Win32_Service` via CIM instead. That works in both editions, so the toolkit uses it:

```powershell
Get-CimInstance -ComputerName PC01 -ClassName Win32_Service -Filter "Name='CcmExec'" |
    Select-Object Name, State, StartMode
```

### 6.4 Scaling out

Serial checks against 5,000 machines take hours. Options:

- PowerShell 7: `ForEach-Object -Parallel -ThrottleLimit 32`.
- Windows PowerShell 5.1: `Invoke-Command -ComputerName $list -ScriptBlock {...}` fans out natively (default throttle 32), or use runspaces / `Start-Job`.
- CIM sessions: `New-CimSession -ComputerName $list` then pass the array of sessions to one `Get-CimInstance` call.

Or skip remoting entirely and use **CMPivot** or **Run Scripts** (sections 11-12), which use the client notification channel.

---

## 7. Applications vs. Packages

### 7.1 Which to use

| | Application model | Package/Program (legacy) |
|---|---|---|
| Detection | Yes, detection methods (MSI code, file, registry, script) | No, success = exit code |
| Requirements | Yes, global conditions | Limited (platform only) |
| Supersedence / dependencies | Yes | Program "run another first" only |
| User-targeted + Software Center | Full | Available only |
| Self-healing / reinstall when missing | Yes (re-evaluation cycle) | No |
| Best for | Almost everything | Scripts, one-shot tasks, utilities with no install footprint, task sequence steps |

Microsoft's guidance: use applications unless you have a specific reason not to.

### 7.2 Creating an MSI application

```powershell
$app = New-CMApplication -Name '7-Zip 24.08 x64' -Publisher 'Igor Pavlov' -SoftwareVersion '24.08' `
        -Description 'Pilot build' -AutoInstall $true    # AutoInstall = allow in task sequences

Add-CMMsiDeploymentType -ApplicationName '7-Zip 24.08 x64' -DeploymentTypeName '7-Zip MSI' `
    -ContentLocation '\\fs01\sources$\7zip\24.08\7z2408-x64.msi' `
    -InstallationBehaviorType InstallForSystem -LogonRequirementType WhetherOrNotUserLoggedOn `
    -UserInteractionMode Hidden -Force
```

`Add-CMMsiDeploymentType` reads the MSI and fills in the product code for detection automatically. `-Force` suppresses the "content may not be accessible" warning. `-ContentLocation` must be a **UNC path** the site server's computer account can read.

### 7.3 Script deployment types

For EXEs or wrapped installs (PSADT etc.):

```powershell
$detect = New-CMDetectionClauseFile -Path '%ProgramFiles%\Contoso' -FileName 'tool.exe' `
            -PropertyType Version -ExpectedValue '5.2.0.0' -ExpressionOperator GreaterEquals -Value

Add-CMScriptDeploymentType -ApplicationName 'Contoso Tool 5.2' -DeploymentTypeName 'Install' `
    -ContentLocation '\\fs01\sources$\Contoso\5.2' `
    -InstallCommand 'setup.exe /quiet' -UninstallCommand 'setup.exe /uninstall /quiet' `
    -AddDetectionClause $detect -InstallationBehaviorType InstallForSystem
```

Version note: detection-clause cmdlets (`New-CMDetectionClauseFile`, `New-CMDetectionClauseRegistryKeyValue`, `New-CMDetectionClauseWindowsInstaller`, `New-CMDetectionClauseDirectory`) and the `-AddDetectionClause` parameter appeared around 1706. Older scripts used `-ScriptText`/`-ScriptLanguage` for script detection, which is still supported via `-ScriptLanguage PowerShell -ScriptText $s`.

### 7.4 Legacy package and program

```powershell
$pkg = New-CMPackage -Name 'Houston - Clear Teams Cache' -Path '\\fs01\sources$\Scripts\TeamsCache'
New-CMProgram -PackageName 'Houston - Clear Teams Cache' -StandardProgramName 'Run' `
    -CommandLine 'powershell.exe -ExecutionPolicy Bypass -File .\Clear-TeamsCache.ps1' `
    -RunType Hidden -ProgramRunType WhetherOrNotUserIsLoggedOn -RunMode RunWithAdministrativeRights
```

`New-CMProgram` has two parameter sets: `-StandardProgramName` and `-DeviceProgramName` (for old Windows CE devices; irrelevant today).

### 7.5 Distributing content

Nothing deploys until content is on a DP the client can reach:

```powershell
Start-CMContentDistribution -ApplicationName '7-Zip 24.08 x64' -DistributionPointGroupName 'All DPs'
Start-CMContentDistribution -PackageName 'Houston - Clear Teams Cache' -DistributionPointName 'dp-hou01.contoso.com'
```

Only run this once per object/DP. Running it again for content already targeted throws an error. For re-sending, use redistribution (section 8).

### 7.6 Deploying

```powershell
# Application: Available to a pilot collection
New-CMApplicationDeployment -Name '7-Zip 24.08 x64' -CollectionName 'Pilot - IT Workstations' `
    -DeployAction Install -DeployPurpose Available -UserNotification DisplayAll -WhatIf

# Required, with a deadline
New-CMApplicationDeployment -Name '7-Zip 24.08 x64' -CollectionName 'Pilot - IT Workstations' `
    -DeployAction Install -DeployPurpose Required -AvailableDateTime (Get-Date) `
    -DeadlineDateTime (Get-Date).AddDays(3) -TimeBaseOn LocalTime

# Package/program
New-CMPackageDeployment -StandardProgram -PackageName 'Houston - Clear Teams Cache' -ProgramName 'Run' `
    -CollectionName 'Pilot - IT Workstations' -DeployPurpose Available
```

Version notes:

- `New-CMApplicationDeployment` replaced `Start-CMApplicationDeployment` (deprecated around 1902; still present but warns).
- `New-CMPackageDeployment` replaced `Start-CMPackageDeployment`. It requires a parameter-set switch (`-StandardProgram` or `-DeviceProgram`).
- Required deployments of packages use `-Schedule` with a schedule object from `New-CMSchedule`, not a deadline parameter.

**Default to Available.** An Available deployment to a pilot collection lets you see detection, install, and logs on real hardware with no blast radius. Promote to Required only after the pilot looks clean. The companion script `New-CMAppAndDeploy.ps1` defaults `-DeployPurpose` to `Available` for this reason.

---

## 8. Distribution Points and Content Status

### 8.1 Inventory

```powershell
Get-CMDistributionPoint | Select-Object NetworkOSPath, SiteCode
Get-CMDistributionPointGroup | Select-Object Name, MemberCount
Get-CMDistributionPointInfo | Select-Object Name, IsPullDP, IsPXE, Description
```

### 8.2 Content status

The console's *Content Status* node is driven by `SMS_PackageStatusDistPointsSummarizer`. `State` values:

| State | Meaning |
|---|---|
| 0 | Installed (success) |
| 1 | Install pending |
| 2 | Install retrying |
| 3 | Install failed |
| 4 | Removal pending |
| 5 | Removal retrying |
| 6 | Removal failed |
| 7 | Content validating |
| 8 | Content validation failed (hash mismatch) |

```powershell
Get-CimInstance -ComputerName cm01 -Namespace root\SMS\site_HOU -ClassName SMS_PackageStatusDistPointsSummarizer `
    -Filter "State <> 0" | Select-Object PackageID, ServerNALPath, State, SummaryDate
```

The module has `Get-CMDistributionStatus` (rollup per object) and `Get-CMDeploymentPackageDistributionStatus`, but the CIM class gives per-DP detail most efficiently.

### 8.3 Redistributing

The supported module cmdlet is:

```powershell
Invoke-CMContentRedistribution -ApplicationName '7-Zip 24.08 x64' -DistributionPointName 'dp-hou01.contoso.com'
```

Under the covers, the console's *Redistribute* sets `RefreshNow = $true` on the `SMS_DistributionPoint` instance for that package and DP. You can do the same via CIM, and the companion `Start-CMContentRedistribution.ps1` does this so it works for any content type (applications, packages, boot images, update packages) with one code path:

```powershell
$dp = Get-CimInstance -ComputerName cm01 -Namespace root\SMS\site_HOU -ClassName SMS_DistributionPoint `
        -Filter "PackageID='HOU0012A' AND ServerNALPath LIKE '%dp-hou01%'"
Set-CimInstance -InputObject $dp -Property @{ RefreshNow = $true }
```

`Update-CMDistributionPoint` is different: it pushes a **new version** of the content when the source files changed. Redistribution resends the existing version.

---

## 9. Software Updates

### 9.1 The moving parts

- **Software Update Point (SUP)** syncs metadata from WSUS/Microsoft Update.
- **Software Update Groups (SUGs)** are lists of updates.
- **Deployment packages** hold the actual binaries on DPs.
- **Deployments** target a SUG to a collection with schedule, deadline, and restart behavior.
- **Automatic Deployment Rules (ADRs)** create or refresh SUGs and deployments on a schedule (Patch Tuesday +N).

### 9.2 Querying updates

```powershell
Get-CMSoftwareUpdate -Fast -DatePostedMin (Get-Date).AddDays(-30) -IsSuperseded $false -IsExpired $false |
    Select-Object ArticleID, LocalizedDisplayName, NumMissing, NumPresent
```

Always filter. Unfiltered `Get-CMSoftwareUpdate` can return tens of thousands of objects and take many minutes.

### 9.3 SUGs and deployments

```powershell
$updates = Get-CMSoftwareUpdate -Fast -ArticleId '5044284'
New-CMSoftwareUpdateGroup -Name 'HOU - 2026-10 Pilot' -SoftwareUpdateId $updates.CI_ID

New-CMSoftwareUpdateDeployment -SoftwareUpdateGroupName 'HOU - 2026-10 Pilot' `
    -CollectionName 'Pilot - IT Workstations' -DeploymentName 'HOU - 2026-10 Pilot - IT' `
    -DeploymentType Required -AvailableDateTime (Get-Date) -DeadlineDateTime (Get-Date).AddDays(2) `
    -UserNotification DisplaySoftwareCenterOnly -SoftwareInstallation $false -AllowRestart $false `
    -RestartWorkstation $false -WhatIf
```

Version notes: `Start-CMSoftwareUpdateDeployment` was deprecated in favor of `New-CMSoftwareUpdateDeployment` (around 1902). Parameter names for restart suppression (`-RestartServer`, `-RestartWorkstation`) take `$true` to **suppress** restarts, an infamously confusing naming carried over from the console's "Suppress restart" checkboxes. Read the help carefully and test with `-WhatIf`.

### 9.4 ADRs

```powershell
Get-CMSoftwareUpdateAutoDeploymentRule -Fast | Select-Object Name, LastRunTime, LastErrorCode
Invoke-CMSoftwareUpdateAutoDeploymentRule -Name 'HOU - Monthly Workstation Patching'   # run now
New-CMSoftwareUpdateAutoDeploymentRule  # many parameters; build in the console first, then inspect
```

ADRs are where PowerShell offers the least value over the console. Build them in the console, then use PowerShell for *monitoring* (`LastErrorCode` ≠ 0) and ad-hoc runs.

### 9.5 Compliance

Compliance per device per update lives in `SMS_UpdateComplianceStatus` (`Status`: 0 = unknown, 1 = not required, 2 = required/missing, 3 = installed). For a SUG-level view use `Get-CMSoftwareUpdateDeploymentStatus` or the provider class `SMS_SUMDeploymentAssetDetails`. The deployment summary class `SMS_DeploymentSummary` gives counts (`NumberSuccess`, `NumberErrors`, `NumberInProgress`, `NumberUnknown`, `NumberOther`) for any feature type.

From the client side, `CCM_SoftwareUpdate` in `root\ccm\ClientSDK` lists updates the client sees as applicable and their `EvaluationState` (0 none, 1 available, 5 downloading, 7 installing, 8 pending soft reboot, 13 error, etc.).

To install pending required updates now on one device:

```powershell
$u = Get-CimInstance -ComputerName PC01 -Namespace root\ccm\ClientSDK -ClassName CCM_SoftwareUpdate -Filter 'ComplianceState = 0'
Invoke-CimMethod -ComputerName PC01 -Namespace root\ccm\ClientSDK -ClassName CCM_SoftwareUpdatesManager `
    -MethodName InstallUpdates -Arguments @{ CCMUpdates = [ciminstance[]]$u }
```

---

## 10. Client Health and Remediation

### 10.1 Built-in client health

- **ccmeval.exe** runs daily as a scheduled task (`Configuration Manager Health Evaluation`) and checks WMI, services, prerequisites, and more, reporting to the site. Results appear in `SMS_CH_EvalResult` / the *Client Check* columns.
- **Client Status Settings** (Monitoring → Client Status) defines what "active" means.

### 10.2 Common symptoms and fixes

| Symptom | Check | Typical fix |
|---|---|---|
| Inactive in console | Is the device online? DNS correct? | Fix DNS/network; trigger DDR `{...003}` |
| `CcmExec` stopped | `Win32_Service` | Start service; check `CcmExec.log` |
| WMI corrupt | `winmgmt /verifyrepository` | `winmgmt /salvagerepository`, then repair client |
| Policy not arriving | `PolicyAgent.log`, MP reachability | Machine policy `{...021}`; check boundaries |
| Stuck downloads | `CAS.log`, `ContentTransferManager.log`, `DataTransferService.log` | Clear cache via `UIResource.UIResourceMgr`; check DP/boundary group |
| Certificate/PKI issues | `ClientIDManagerStartup.log`, `LocationServices.log` | Reissue cert; reset client identity |

### 10.3 Repair options

1. **`SMS_Client.RepairClient`**: client-side WMI method that kicks off `ccmrepair.exe`. Least invasive.
   ```powershell
   Invoke-CimMethod -ComputerName PC01 -Namespace root\ccm -ClassName SMS_Client -MethodName RepairClient
   ```
2. **Restart the service**: `Restart-Service CcmExec` inside `Invoke-Command`.
3. **Reinstall**: `ccmsetup.exe` from `\\<siteserver>\SMS_<SiteCode>\Client` with `/forceinstall` or client push from the console (`Install-CMClient -DeviceName PC01 -SiteCode HOU -AlwaysInstallClient $true`).
4. **Uninstall and reinstall** (`ccmsetup.exe /uninstall`) for truly broken clients. This is the sledgehammer.

The companion `Repair-CMClient.ps1` implements levels 1-3 behind `-Method` and `SupportsShouldProcess` with `ConfirmImpact = 'High'`, so nothing happens without confirmation or `-Confirm:$false`.

### 10.4 Pending reboots

ConfigMgr tracks its own reboot pending flag, separate from Windows. Check both:

```powershell
Invoke-CimMethod -ComputerName PC01 -Namespace root\ccm\ClientSDK -ClassName CCM_ClientUtilities -MethodName DetermineIfRebootPending
```

And the Windows signals (via `Invoke-Command`): `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending`, `...\WindowsUpdate\Auto Update\RebootRequired`, and `PendingFileRenameOperations` under `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager`. Site-side, `SMS_CombinedDeviceResources.ClientState` is a bitmask of pending reboot reasons (1 = Configuration Manager, 2 = File rename, 4 = Windows Update, 8 = Add/remove feature), and the console has a *Pending Restart* column since 1710.

---

## 11. The Run Scripts Feature

**Run Scripts** (Software Library → Scripts) runs approved PowerShell scripts on devices or collections in near-real time via the client notification channel. No WinRM is required. Output returns to the console (and the `SMS_ScriptsExecutionStatus` class).

```powershell
# Create (requires the script author role)
New-CMScript -ScriptName 'Get Teams Version' -ScriptFile 'C:\Scripts\Get-TeamsVersion.ps1' -Fast

# Approve (must be a *different* admin unless the hierarchy setting allows self-approval)
Approve-CMScript -ScriptGuid $guid -Comment 'Reviewed 2026-10-10 AB'

# Run against a collection
Invoke-CMScript -ScriptGuid $guid -CollectionId 'HOU00042'
```

Key points:

- **Approval workflow:** by default, authors can't approve their own scripts. Keep it that way in production (*Hierarchy Settings → Script authors require additional script approver*).
- Scripts run as **SYSTEM**.
- Output is capped (roughly 4 KB per device, returned as JSON if possible). Return compact objects.
- Parameters are supported; values are defined at run time.
- `New-CMScript` and friends were added around 1802/1806; older builds have only the console experience.
- Requires PowerShell 3.0+ on clients and ConfigMgr client 1706+.

---

## 12. CMPivot

CMPivot queries live data on online clients using a **KQL-like** language, over the client notification channel. Great for "which machines have file X right now?" or "who is running service Y?".

```kusto
Device | project Device, Manufacturer, Model, OSVersion
Service | where Name == 'CcmExec' and State != 'Running'
File('%windir%\System32\drivers\etc\hosts') | project Device, LastWriteTime, Size
InstalledSoftware | where ProductName like '%Chrome%' | summarize count() by ProductVersion
```

From PowerShell:

```powershell
Invoke-CMCMPivot -CollectionId 'HOU00042' -Query "Service | where Name == 'CcmExec'"
```

Version notes: `Invoke-CMCMPivot` arrived around 1906/1910. Results come back asynchronously; the cmdlet returns an operation object and you poll the provider (`SMS_CMPivotStatus`) for results. The standalone CMPivot app (`CMPivot.exe` under the console bin folder) supports more operators. CMPivot permissions are governed by the **Run CMPivot** permission on the collection (and Read on SMS Scripts in older builds). 

---

## 13. Safe Practice

### 13.1 `-WhatIf` and `-Confirm`

Most ConfigMgr cmdlets that change state support `-WhatIf`. Always dry-run first:

```powershell
New-CMApplicationDeployment ... -WhatIf
Remove-CMDevice -Name PC01 -WhatIf
```

Not every cmdlet honors `-WhatIf` equally well. A few older ones accept it but act anyway; test before trusting.

Every state-changing script in this repository declares `[CmdletBinding(SupportsShouldProcess)]` and wraps its changes in `$PSCmdlet.ShouldProcess(...)`, so `-WhatIf` propagates. Destructive ones set `ConfirmImpact = 'High'`.

### 13.2 Pilot collections and rings

A sensible ring model:

1. **Ring 0:** IT test VMs (lab).
2. **Ring 1:** IT staff workstations (Available, then Required).
3. **Ring 2:** ~5-10% representative users per department and site.
4. **Ring 3:** Broad production.
5. **Ring 4:** Critical servers, with change approval.

Collection naming that sorts well (`HOU - Pilot - Ring1`) and **limiting collections** that contain blast radius are cheap insurance.

### 13.3 Maintenance windows

```powershell
$sched = New-CMSchedule -DayOfWeek Saturday -WeekOrder Second -Start '2026-10-10 22:00' -End '2026-10-11 02:00'
New-CMMaintenanceWindow -CollectionName 'HOU - Servers - Group A' -Name 'Patch Sat 2200' `
    -Schedule $sched -ApplyTo SoftwareUpdatesOnly
Get-CMMaintenanceWindow -CollectionName 'HOU - Servers - Group A'
```

`-ApplyTo` values: `Any`, `SoftwareUpdatesOnly`, `TaskSequencesOnly`. Version note: older builds used `-ApplyToSoftwareUpdateOnly` / `-ApplyToTaskSequenceOnly` switches instead of `-ApplyTo`. Note `New-CMSchedule -WeekOrder` maps to "Nth weekday of month"; offset-based schedules (e.g. Patch Tuesday +4) need `-OffsetDay` on 2010+.

### 13.4 The "All Systems" footgun

Never target *All Systems* or *All Desktop and Server Clients* with a Required deployment unless you absolutely mean it. The infamous 2014 incident where a university's task sequence wiped its own servers is still the cautionary tale. Recommended guardrails:

- Enable **Deployment verification**: the hierarchy setting that warns or blocks high-risk deployments (task sequences to collections exceeding a size or containing site servers).
- Build scripts that **refuse** certain collection IDs (`SMS00001`, `SMSDM003`, etc.). The companion deploy scripts block the built-in collections unless `-AllowBuiltInCollection` is passed.

### 13.5 Logging

Use `Start-Transcript` in automation, and write CSV evidence of what you changed. The `.gitignore` in this repo excludes report output so you don't accidentally commit hostnames.

---

## 14. Least Privilege with RBAC

ConfigMgr's role-based administration has three pieces:

- **Security roles:** *what* you can do (e.g. *Application Administrator*, *Software Update Manager*, *Read-only Analyst*, *Remote Tools Operator*, *Operations Administrator*, *Full Administrator*).
- **Security scopes:** *which objects* you can see (apps, packages, DPs tagged with a scope).
- **Collections:** *which devices/users* you can act on.

```powershell
Get-CMSecurityRole | Select-Object RoleName, IsBuiltIn
Get-CMAdministrativeUser -Name 'CONTOSO\svc-cmreports'
New-CMAdministrativeUser -Name 'CONTOSO\HOU-CM-Helpdesk' -RoleName 'Remote Tools Operator' `
    -SecurityScopeName 'Houston' -CollectionName 'HOU - All Workstations'
Copy-CMSecurityRole -SourceRoleName 'Read-only Analyst' -Name 'HOU Reporting + Run Scripts'
```

Recommendations:

- **Report scripts** in this repo need only *Read-only Analyst* on the relevant collections plus WMI read access to the provider (membership in the **SMS Admins** local group on the provider server, which ConfigMgr manages automatically for admin users).
- **Client-side** scripts (`Invoke-CMClientAction`, `Invoke-CMAppInstallOnClient`) need local admin on the endpoints, not ConfigMgr roles at all. Use a dedicated tier-appropriate account; don't use a domain admin.
- **Deploy scripts** need *Application Administrator* (or *Application Deployment Manager* for deploy-only) scoped to a pilot collection.
- Use **separate accounts** for authoring and approving Run Scripts.
- Never run automation as *Full Administrator* when a scoped role works. Audit with the *Administrative Security* reports and `Get-CMAdministrativeUser`.
- For scheduled tasks, consider a gMSA where supported.

---

## 15. Quick Reference

```powershell
# Connect
Import-Module (Join-Path (Split-Path $ENV:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1')
New-PSDrive -Name HOU -PSProvider CMSite -Root cm01.contoso.com
Set-Location HOU:

# Devices & collections
Get-CMDevice -Name PC01
Get-CMDevice -CollectionName 'X' -Fast
Get-CMCollectionMember -CollectionId HOU00042
Add-CMDeviceCollectionDirectMembershipRule -CollectionName 'Pilot' -ResourceId (Get-CMDevice -Name PC01 -Fast).ResourceID
Invoke-CMCollectionUpdate -Name 'Pilot'

# Client actions
Invoke-CMClientNotification -DeviceName PC01 -ActionType DownloadComputerPolicy
Invoke-CimMethod -ComputerName PC01 -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{sScheduleID='{00000000-0000-0000-0000-000000000021}'}

# Apps & packages
New-CMApplication; Add-CMMsiDeploymentType; Add-CMScriptDeploymentType
New-CMPackage; New-CMProgram
Start-CMContentDistribution; Invoke-CMContentRedistribution; Update-CMDistributionPoint
New-CMApplicationDeployment; New-CMPackageDeployment

# Updates
Get-CMSoftwareUpdate -Fast; New-CMSoftwareUpdateGroup; New-CMSoftwareUpdateDeployment
Get-CMSoftwareUpdateAutoDeploymentRule; Invoke-CMSoftwareUpdateAutoDeploymentRule

# Monitoring
Get-CMDeployment; Get-CMDistributionStatus; Get-CMSoftwareUpdateDeploymentStatus

# Run scripts / CMPivot
New-CMScript; Approve-CMScript; Invoke-CMScript; Invoke-CMCMPivot
```

### Key client logs (`C:\Windows\CCM\Logs`)

| Log | Topic |
|---|---|
| `PolicyAgent.log` | Policy download |
| `AppDiscovery.log`, `AppEnforce.log`, `AppIntentEval.log` | Application detection/install |
| `execmgr.log` | Packages/programs and Run Scripts |
| `CAS.log`, `ContentTransferManager.log`, `DataTransferService.log` | Content download |
| `WUAHandler.log`, `UpdatesDeployment.log`, `UpdatesHandler.log`, `ScanAgent.log` | Software updates |
| `InventoryAgent.log` | Hardware/software inventory |
| `CcmEval.log` | Client health |
| `LocationServices.log`, `ClientLocation.log` | MP/DP/boundary lookup |
| `ccmsetup.log` (in `C:\Windows\ccmsetup\Logs`) | Install/repair |

Use **CMTrace** (`C:\Windows\CCM\CMTrace.exe` on clients since 1806, or the console's Tools folder) or the **Support Center** OneTrace viewer to read them.

---

*Validate everything in a lab. Configuration Manager makes it very easy to do the wrong thing to many machines very quickly.*
