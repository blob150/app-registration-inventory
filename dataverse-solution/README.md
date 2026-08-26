# Dataverse solution

The **App Registration Inventory** solution (publisher prefix `appreg`) contains
everything the model-driven side needs.

## Contents

| Component | Logical name | Notes |
| --- | --- | --- |
| Table: **App Registration** (parent) | `appreg_appregistration` | 1 row per app. Manifest + hash, ownerless flag, owner count, business-owner email, earliest credential expiry, last synced/changed. Alternate key `appreg_objectid` for upserts. |
| Table: **App Credential** | `appreg_appcredential` | Secrets / certificates / FICs. Type, key ID, start/expiration, days-to-expiry, cert CN + thumbprint, FIC subject/issuer/audiences + raw JSON. |
| Table: **App Owner** | `appreg_appowner` | UPN, display name, object ID, email, Power Platform premium flag. |
| Table: **App Permission** | `appreg_apppermission` | Resource (API), permission name, Delegated vs Application, granted flag. |
| Table: **Sync State** | `appreg_syncstate` | Stores the Graph `deltaLink`, last run status/details, apps processed. |
| Model-driven app | **App Registration Inventory** | Views of the four inventory tables + a Sync State admin area. |
| Security role | **App Registration Sync** | CRUD + Append/AppendTo on the five `appreg_` tables only (least privilege for the sync identity). |

## Install

**Recommended (managed):** download the latest managed zip from
[Releases](../../releases) and import — no build step.

```powershell
pac auth create --url https://YOURORG.crm.dynamics.com
pac solution import --path AppRegistrationInventory_v1.0.0_managed.zip --activate-plugins
```

Or **make.powerapps.com → Solutions → Import solution**.

Use the **unmanaged** zip only if you intend to customize and re-export.

## After import

1. Run `azure-setup/Add-DataverseAppUser.ps1` to add the managed identity as an
   application user and assign the **App Registration Sync** role.
2. Open the **App Registration Inventory** app to view data once the runbook has run.

## Rebuilding the source (`src/`)

`src/` is the unpacked unmanaged solution, kept in source control for diffing.
To regenerate after making changes in an environment:

```powershell
pac solution export --name AppRegistrationInventory --path build/AppRegistrationInventory.zip --managed false --overwrite
pac solution unpack --zipfile build/AppRegistrationInventory.zip --folder src --packagetype Unmanaged --allowDelete true --allowWrite true
```
