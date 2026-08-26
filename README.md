# App Registration Inventory

Catalog every Microsoft Entra ID **application registration** in your tenant into
**Dataverse**, on a schedule, using an Azure Automation PowerShell runbook that
authenticates with a **system-assigned managed identity** (no secrets). View and
manage the data in a **model-driven app**.

Built for governance reporting at scale (tested against a tenant with **13,000+**
app registrations).

> Licensed under the [MIT License](LICENSE).

---

## What it captures

For every app registration:

| Area | Details |
| --- | --- |
| **Identity** | Display name, App (client) ID, directory object ID, sign-in audience, publisher domain, created date |
| **Manifest** | The full application object JSON, stored once and only rewritten when it changes (SHA-256 hash comparison) |
| **Owners** | Every owner (0, 1, or many) as child rows — display name, UPN, email, object ID, and whether they hold a **Power Platform premium** license. An `Ownerless` flag + owner count on the parent make ownerless apps trivial to filter and drive owner-based mass email. |
| **Credentials** | Secrets, certificates, and federated identity credentials (FICs) with expiration dates, days-to-expiry, certificate CN/thumbprint, and the raw FIC JSON. Since nothing is non-expiring, an earliest-expiry rollup drives "expiring in 30/60/90" views. |
| **Permissions** | Requested API permissions (Microsoft Graph, SharePoint, etc.) with the resolved permission name and whether each is **Delegated** or **Application**. |

## How it syncs

- **Microsoft Graph `/applications/delta`** is the source of truth. The runbook stores
  the `deltaLink` in a Sync State table and, on every run, pulls only **created /
  updated / deleted** apps. The first run is a full baseline; every run after is cheap.
- Runs on a schedule (default **every 4 hours**) as the managed identity.
- **Change notifications are *not* used** — Microsoft Graph does not support change
  notification subscriptions on the `applications` resource (only `user` and `group`
  among directory objects). Delta query is the correct, supported mechanism. For
  near-real-time you can layer Entra audit-log streaming later; it is not required.

See [docs/architecture.md](docs/architecture.md) for the full design and the
managed-identity permission model.

---

## Quick start

### 0. Prerequisites
- An **Azure Automation account** with a **system-assigned managed identity** enabled.
- The **Az.Accounts** module available in that Automation account (Modules blade).
- A **Dataverse environment** where you have the System Administrator role.
- Local tooling: **Azure CLI** (`az`) and (for solution import) **Power Platform CLI** (`pac`)
  or the maker portal.
- Rights to grant Microsoft Graph app roles (Privileged Role Admin / Global Admin /
  Cloud Application Admin).

### 1. Import the Dataverse solution
Download the latest **managed** solution zip from
[Releases](../../releases) (no build required) and import it:

```powershell
pac auth create --url https://YOURORG.crm.dynamics.com
pac solution import --path AppRegistrationInventory_v1.0.0_managed.zip --activate-plugins
```
Or import via **make.powerapps.com → Solutions → Import**.

This creates the 5 tables, the **App Registration Inventory** model-driven app, and the
**App Registration Sync** security role.

### 2. Grant the managed identity its Graph permissions
```powershell
az login
./azure-setup/Grant-GraphRoles.ps1 `
  -AutomationAccountName MyAutomationAccount -ResourceGroup my-rg
```
Grants `Application.Read.All` + `Directory.Read.All` to the MI.

### 3. Add the managed identity as a Dataverse application user
```powershell
./azure-setup/Add-DataverseAppUser.ps1 `
  -EnvironmentUrl https://YOURORG.crm.dynamics.com `
  -AutomationAccountName MyAutomationAccount -ResourceGroup my-rg
```

### 4. Deploy the runbook + schedule
```powershell
./azure-setup/Deploy-Runbook.ps1 `
  -AutomationAccountName MyAutomationAccount -ResourceGroup my-rg `
  -EnvironmentUrl https://YOURORG.crm.dynamics.com
```
The schedule is created **disabled** so the baseline does not fire unattended.

### 5. Validate with a bounded run, then enable
```powershell
./azure-setup/Start-SyncJob.ps1 `
  -AutomationAccountName MyAutomationAccount -ResourceGroup my-rg `
  -EnvironmentUrl https://YOURORG.crm.dynamics.com -MaxApps 50 -Wait
```
When you're happy, enable the schedule:
```powershell
az automation schedule update -g my-rg --automation-account-name MyAutomationAccount `
  --name AppReg-Sync-Every4h --is-enabled true
```

---

## Repository layout

```
azure-setup/          PowerShell setup + operations scripts
  Grant-GraphRoles.ps1        Grant MI the Graph app roles
  Add-DataverseAppUser.ps1    Add MI as Dataverse app user + assign role
  Deploy-Runbook.ps1          Import/publish runbook + create schedule
  Start-SyncJob.ps1           Start a run with parameters (bounded test / re-sync)
  Sync-AppRegistrations.ps1   The runbook itself
dataverse-solution/   Unpacked solution source (tables, app, sitemap, role)
releases/             Downloadable managed + unmanaged solution zips
docs/                 Architecture and design notes
```

## Operational notes

- **Scale:** at 13k+ apps the cold baseline is the heavy run (per-app owner + FIC calls).
  Azure Automation caps a single job at ~3 hours; if a cold baseline risks that, run it in
  bounded batches with `-MaxApps` first, or shard, then let incremental delta take over.
- **Re-sync a subset:** `Start-SyncJob.ps1 -ResyncExisting` re-reads only apps already in
  Dataverse; add `-Force` to rewrite regardless of the manifest hash (useful after a
  schema/logic change).
- **Least privilege:** the MI is read-only in Entra (`Application.Read.All` +
  `Directory.Read.All`) and holds a scoped custom role in Dataverse (CRUD on the five
  `appreg_` tables only) — not System Administrator.
