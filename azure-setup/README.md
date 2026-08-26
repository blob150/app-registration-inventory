# Azure setup scripts

PowerShell (5.1+) scripts to stand up the Azure/Dataverse side. All use the
**Azure CLI** for authentication — run `az login` first. Run them in order.

| # | Script | What it does | Auth needed |
| --- | --- | --- | --- |
| 1 | `Grant-GraphRoles.ps1` | Grants the Automation account's managed identity `Application.Read.All` + `Directory.Read.All` on Microsoft Graph | A directory role that can grant Graph app roles (Privileged Role Admin / Global Admin / Cloud App Admin) |
| 2 | `Add-DataverseAppUser.ps1` | Adds the managed identity as a Dataverse application user and assigns the **App Registration Sync** role | System Administrator in the target Dataverse env; **solution must be imported first** |
| 3 | `Deploy-Runbook.ps1` | Imports + publishes `Sync-AppRegistrations.ps1` and creates the (disabled) schedule linked to the runbook | Contributor on the Automation account |
| — | `Start-SyncJob.ps1` | Starts a run with parameters (bounded test / manual re-sync); can wait and print output | Contributor on the Automation account |
| — | `Sync-AppRegistrations.ps1` | The runbook. Not run locally — deployed by `Deploy-Runbook.ps1` | Runs in Azure as the MI |

## Order of operations

```
Import solution  ->  1 Grant-GraphRoles  ->  2 Add-DataverseAppUser  ->  3 Deploy-Runbook  ->  Start-SyncJob (test)  ->  enable schedule
```

## Runbook parameters (`Sync-AppRegistrations.ps1`)

| Parameter | Type | Purpose |
| --- | --- | --- |
| `-OrgUrl` (required) | string | Dataverse org URL, e.g. `https://yourorg.crm.dynamics.com` |
| `-MaxApps` | int | Bound the run to N apps (0 = all). Use for a controlled first test. |
| `-Reset` | switch | Delta mode: ignore the stored deltaLink and do a full baseline. |
| `-ResyncExisting` | switch | Re-read only object-IDs already in Dataverse (scoped; no tenant enumeration). Tombstones apps deleted from Entra. |
| `-Force` | switch | With `-ResyncExisting`, rewrite every record regardless of manifest hash. |

## Why jobs are started via ARM REST, not `az automation runbook start`

The `az automation` CLI extension is experimental and does **not** reliably pass
`--parameters` into the job. `Deploy-Runbook.ps1` and `Start-SyncJob.ps1` therefore
create job(-schedule)s through the Azure Resource Manager REST API, which passes
parameters correctly.

## Notes

- **Az.Accounts** must be present in the Automation account (Modules blade). The runbook
  calls `Connect-AzAccount -Identity` and `Get-AzAccessToken`.
- Grants can take a minute to propagate before the first run can read owner details.
- The schedule is created **disabled**; validate with a bounded `Start-SyncJob.ps1 -MaxApps 50`
  before enabling.
