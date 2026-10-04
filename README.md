# Azure Arc Server Rename Kit

Copyright (c) September 2026
Shannon Eldridge-Kuehn

Scripts and a runbook for renaming an Azure Arc-enabled server without losing track of what was attached to the server.

## Why this exists

The name of an Azure Arc-enabled server resource is fixed at the moment `azcmagent connect` runs, and by default it matches the hostname at that moment. If you rename the operating system later, the agent keeps running and the resource in Azure keeps its old name, which leaves your CMDB and your Azure inventory quietly disagreeing with each other. The only supported way to change the Azure resource name is to disconnect the agent, which deletes the resource, and then connect again, which creates a new one.

That new resource gets a new system-assigned managed identity, and this is where people get hurt. Role assignments that pointed at the old identity now point at nothing, extensions are removed by the disconnect, and Data Collection Rule associations vanish with the resource. These two scripts capture all of that before you disconnect and replay it afterward, so the rename becomes a short maintenance window instead of an afternoon of figuring out which Key Vault stopped working.

## What is in the repo

| Path | Purpose |
|------|---------|
| `scripts/Export-ArcMachineState.ps1` | Run before the disconnect. Writes a JSON snapshot of tags, managed identity principal ID, role assignments, extensions, and DCR associations. |
| `scripts/Restore-ArcMachineState.ps1` | Run after the reconnect. Reapplies the snapshot to the new resource and its new managed identity. Supports `-WhatIf`. |
| `examples/sample-state.json` | A sanitized example of the snapshot format, so you can see what gets captured before you run anything. |
| `LICENSE` | MIT. |

## Requirements

You will need PowerShell 7 or later. Windows PowerShell 5.1 can behave differently with some Azure endpoints, so run these from PowerShell 7 to stay on the safe side. You will also need the Az.Accounts, Az.ConnectedMachine, and Az.Resources modules, which you can install like this:

```powershell
Install-Module Az.Accounts, Az.ConnectedMachine, Az.Resources -Scope CurrentUser
```

For permissions, the account running the scripts needs Azure Connected Machine Resource Administrator on the resource group, plus User Access Administrator (or an equivalent role with permission to write role assignments) at every scope where the old identity held a role. The `azcmagent` commands on the server itself need an elevated session and credentials that can delete and create Arc resources.

## How to run it

Steps 1, 4, and 5 run from a workstation with the Az modules. Steps 2 and 3 run on the server being renamed.

**1. Capture state (workstation).** Sign in with `Connect-AzAccount`, then export everything attached to the current resource.

```powershell
git clone https://github.com/sbkuehn/arc-server-rename-kit.git
cd arc-server-rename-kit
.\scripts\Export-ArcMachineState.ps1 -MachineName oldbox02 -ResourceGroupName rg-arc-prod
```

This writes `oldbox02-arc-state.json` in the current folder. Open it and confirm the role assignments and extensions look right before moving on, because the Azure resource and everything in this file are about to become impossible to query.

**2. Disconnect the agent (server, elevated).**

```
azcmagent disconnect
```

You can sign in interactively, or pass `--service-principal-id`, `--service-principal-secret`, and `--tenant-id`. The Azure resource is deleted and its extensions are removed, but the Connected Machine agent stays installed on the server.

**3. Rename the server and reboot (server).**

```powershell
Rename-Computer -NewName APP-PRD-07 -Restart
```

After the reboot, confirm the new hostname. If the server is domain-joined, also make sure the computer account is healthy, since Arc does not care about Active Directory but the rest of your environment does.

**4. Reconnect the agent (server, elevated).**

```
azcmagent connect --subscription-id <sub-id> --resource-group rg-arc-prod --location eastus2
```

The resource name defaults to the new hostname. If your naming standard differs from the hostname, add `--resource-name <name>`. Setting tags here with `--tags` is cheaper than patching them afterward, although the restore script will reapply the old tags either way.

**5. Restore state (workstation).** Do a dry run first, then the real thing.

```powershell
.\scripts\Restore-ArcMachineState.ps1 -StatePath .\oldbox02-arc-state.json -NewMachineName APP-PRD-07 -WhatIf
.\scripts\Restore-ArcMachineState.ps1 -StatePath .\oldbox02-arc-state.json -NewMachineName APP-PRD-07
```

The script reapplies tags, waits for the new managed identity to replicate through Entra ID, recreates each role assignment against the new principal, redeploys extensions asynchronously, and re-associates Data Collection Rules. Anything that lived in protected extension settings, such as Log Analytics workspace keys, is never returned by the API, so supply it again at restore time:

```powershell
.\scripts\Restore-ArcMachineState.ps1 `
    -StatePath .\oldbox02-arc-state.json `
    -NewMachineName APP-PRD-07 `
    -ProtectedSettings @{ 'MicrosoftMonitoringAgent' = @{ workspaceKey = '<key>' } }
```

**6. Verify.** On the server, run `azcmagent show` and confirm the agent reports Connected under the new name. From the workstation, check the results:

```powershell
Get-AzConnectedMachineExtension -MachineName APP-PRD-07 -ResourceGroupName rg-arc-prod
Get-AzRoleAssignment -ObjectId <new-principal-id>
```

Give Azure Policy a compliance cycle to re-evaluate. If you have deployIfNotExists policies, they will often put standard extensions back on their own, but confirm rather than assume.

## Script parameters

Both scripts follow the usual PowerShell conventions, so `Get-Help .\scripts\Export-ArcMachineState.ps1 -Full` works. The restore script also accepts `-SkipTags`, `-SkipRoleAssignments`, `-SkipExtensions`, and `-SkipDcrAssociations` so you can rerun just one piece, and `-IdentityWaitSeconds` to lengthen the Entra ID replication wait (default 120 seconds).

## Things these scripts cannot do

They cannot update your CMDB, DNS aliases, dashboards, or anything else keyed on the old resource ID. They cannot restore protected extension settings, because Azure never returns them. They also have no visibility into access the old identity received through Entra ID group membership, so check group memberships separately. And they cannot speed up Entra ID replication, so if role assignments fail on the first pass, wait a few minutes and rerun with `-SkipTags -SkipExtensions -SkipDcrAssociations`.

## Decoupling the Arc name from the hostname

If a server is likely to be renamed, consider passing `--resource-name` deliberately at onboarding so the Azure identity does not track whatever the OS happens to be called. A rename then becomes a purely on-premises event. The trade-off is two names for one machine, so keep a mapping in your CMDB or as a tag on the resource. Also keep in mind that Arc resource names are limited to 54 characters.

## Security notes

The exported state file contains principal IDs, scopes, and extension settings, so treat it as sensitive and delete it once the rename is verified. The `.gitignore` in this repo excludes `*-arc-state.json` so a snapshot does not get committed by accident. Always run the restore script with `-WhatIf` in production before applying changes.

## Disclaimer

These scripts are provided as is, without warranty, and I have not been able to test them against every tenant configuration or Az module version. Try them on a lab Arc machine first. In particular, confirm that the `IdentityPrincipalId` and `MachineExtensionType` properties resolve with the Az.ConnectedMachine version you have installed, since property names can shift between module releases.

## References

Microsoft documents the underlying behavior in its Arc-enabled servers articles on renaming and migrating machines and in the `azcmagent connect` CLI reference on Microsoft Learn.

## Author

Shannon Eldridge-Kuehn, Principal Solutions Architect. Blog: [Cloudy Musings](https://shankuehn.io). GitHub: [@sbkuehn](https://github.com/sbkuehn).

## License

Released under the [MIT License](LICENSE).
