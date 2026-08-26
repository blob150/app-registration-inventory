# Architecture & design

## Overview

```
                Azure Automation (system-assigned managed identity)
                        |
        Connect-AzAccount -Identity ; Get-AzAccessToken
                        |
        +---------------+-----------------------------+
        |                                             |
   Microsoft Graph                              Dataverse Web API
   (Application.Read.All,                       (application user +
    Directory.Read.All)                          "App Registration Sync" role)
        |                                             |
   GET /applications/delta  -----------------> upsert appreg_appregistration (by alt key)
   GET /applications/{id}/owners                     + child rows:
   GET /applications/{id}/federatedIdentity...         appreg_appcredential
   GET /users/{id}/licenseDetails                      appreg_appowner
   GET /servicePrincipals(appId=...)                   appreg_apppermission
                                                     + appreg_syncstate (deltaLink)
```

The model-driven app reads the same tables. No plugins, no custom code in Dataverse.

## Why delta query, not change notifications

Microsoft Graph change-notification **subscriptions are not supported for the
`applications` resource**. Among directory objects only `user` and `group` are
subscribable. The supported, purpose-built mechanism for "what app registrations
changed" is **`/applications/delta`**, which returns created/updated/deleted objects
since a stored `deltaLink`. This scales cleanly to tens of thousands of apps because
each incremental run returns only the delta.

If sub-hour freshness is ever required, stream **Entra audit logs** (Diagnostic
Settings -> Event Hub / Log Analytics) and trigger a targeted `GET /applications/{id}`
on `Add/Update/Delete application` events. That is an optional latency reducer layered
*on top of* delta, never a replacement — delta remains the source of truth.

## Managed-identity permission model (least privilege)

| Surface | Grant | Why |
| --- | --- | --- |
| Microsoft Graph | `Application.Read.All` | Read all app registrations + their credential/permission metadata. Graph never returns secret/cert *values*, only metadata. |
| Microsoft Graph | `Directory.Read.All` | Resolve owner display name / UPN / mail and read owner `licenseDetails` for the Power Platform premium flag. |
| Dataverse | Custom role **App Registration Sync** | CRUD + Append/AppendTo on the five `appreg_` tables only. Not System Administrator. |

No secrets or certificates are stored anywhere; the identity is a system-assigned
managed identity resolved at runtime.

## Change detection

The full application object is serialized to JSON and hashed (SHA-256). The parent row
stores the hash; a run rewrites an app (parent + rebuilt children) only when the hash
differs. This keeps Dataverse audit history clean and makes re-runs cheap.

> Note: the JSON shape differs between the `/applications/delta` endpoint and a direct
> `GET /applications/{id}`. Hashes are therefore stable *within* an endpoint path.
> The first `-ResyncExisting` after a delta baseline rewrites all rows, then stabilizes.

## Data model

`appreg_appregistration` (parent, owner-owned) 1:N to:
- `appreg_appcredential` (cascade delete)
- `appreg_appowner` (cascade delete)
- `appreg_apppermission` (cascade delete)

`appreg_syncstate` is a standalone config table holding one row (`applications-delta`)
with the current `deltaLink` and last-run telemetry.

Upserts key on the parent alternate key **`appreg_objectid`** (the directory object ID),
so re-runs are idempotent.

## Owner -> record owner (design note)

App owners are captured as child rows regardless of licensing, and the parent carries a
business-owner email — so **owner-based mass email works even for owners without Power
Platform licenses** (it does not depend on Dataverse record ownership). The
`Has Power Platform Premium` flag on each owner is derived from Graph `licenseDetails`
(standalone premium Power Platform / Dynamics 365 SKUs). Note that holding a premium
license is necessary but not identical to being an enabled `systemuser` in a specific
environment, which is the true gate for assigning Dataverse record ownership.

## Scale considerations (13k+ apps)

- `$select` narrow, `$top=999`, follow `@odata.nextLink`.
- Owner/FIC/service-principal calls are per-app; incremental delta keeps that set small.
- Honor `Retry-After` on 429/503 with backoff (built into the runbook helpers).
- Azure Automation caps a single job at ~3 hours. The cold baseline is the only run at
  risk; run it bounded (`-MaxApps`) in batches or shard, then let incremental delta run.
