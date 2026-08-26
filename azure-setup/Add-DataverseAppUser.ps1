#requires -Version 5.1
<#
.SYNOPSIS
  Adds the Automation account's managed identity as a Dataverse application user
  and assigns it the "App Registration Sync" security role that ships with the solution.

.DESCRIPTION
  * Looks up the managed identity's application (client) ID from the Automation account.
  * Creates a Dataverse application user bound to the root business unit (idempotent).
  * Assigns the security role (default: "App Registration Sync") which is imported
    as part of the AppRegistrationInventory solution and already carries CRUD/Append
    privileges on the five appreg_ tables.

  Auth: uses an Azure CLI access token for Dataverse, so run `az login` first as a
  user with the System Administrator role in the target environment. Import the
  solution BEFORE running this script (the security role must already exist).

.PARAMETER EnvironmentUrl
  Dataverse org URL, e.g. https://yourorg.crm.dynamics.com (no trailing slash).

.PARAMETER AutomationAccountName
  Automation account whose managed identity becomes the application user.

.PARAMETER ResourceGroup
  Resource group of the Automation account.

.PARAMETER RoleName
  Security role to assign. Default: "App Registration Sync".

.EXAMPLE
  ./Add-DataverseAppUser.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com `
      -AutomationAccountName MyAutomationAccount -ResourceGroup my-rg
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$EnvironmentUrl,
  [Parameter(Mandatory=$true)][string]$AutomationAccountName,
  [Parameter(Mandatory=$true)][string]$ResourceGroup,
  [string]$RoleName = 'App Registration Sync',
  [string]$SubscriptionId
)
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$api = "$EnvironmentUrl/api/data/v9.2"

if ($SubscriptionId) { az account set --subscription $SubscriptionId | Out-Null }
if (-not (az extension show --name automation 2>$null)) { az extension add --name automation --only-show-errors | Out-Null }

Write-Host "Resolving managed identity appId ..." -ForegroundColor Cyan
$principalId = az automation account show --name $AutomationAccountName --resource-group $ResourceGroup --query "identity.principalId" -o tsv
if (-not $principalId) { throw "Automation account has no system-assigned managed identity." }
$miAppId = az ad sp show --id $principalId --query "appId" -o tsv
Write-Host "  MI appId: $miAppId"

$tok = az account get-access-token --resource $EnvironmentUrl --query accessToken -o tsv
$H = @{ Authorization="Bearer $tok"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json"; "Content-Type"="application/json; charset=utf-8" }

# Root business unit
$rootBu = (Invoke-RestMethod -Uri "$api/businessunits?`$select=businessunitid,name&`$filter=parentbusinessunitid eq null" -Headers $H).value[0]
Write-Host "  Root BU: $($rootBu.name)"

# Application user (idempotent)
$existing = (Invoke-RestMethod -Uri "$api/systemusers?`$select=systemuserid&`$filter=applicationid eq $miAppId" -Headers $H).value
if ($existing) {
  $userId = $existing[0].systemuserid; Write-Host "  App user already exists: $userId" -ForegroundColor DarkGray
} else {
  $body = @{ applicationid = $miAppId; "businessunitid@odata.bind" = "/businessunits($($rootBu.businessunitid))" } | ConvertTo-Json
  $rh = $null
  Invoke-RestMethod -Uri "$api/systemusers" -Headers $H -Method Post -Body $body -ResponseHeadersVariable rh | Out-Null
  $userId = ($rh["OData-EntityId"] -replace '.*systemusers\(','' -replace '\).*','')
  Write-Host "  CREATED app user: $userId" -ForegroundColor Green
}

# Security role (must exist from solution import)
$role = (Invoke-RestMethod -Uri "$api/roles?`$select=roleid,name&`$filter=name eq '$RoleName'" -Headers $H).value
if (-not $role) { throw "Security role '$RoleName' not found. Import the AppRegistrationInventory solution first." }
$roleId = $role[0].roleid

$assigned = (Invoke-RestMethod -Uri "$api/systemusers($userId)/systemuserroles_association?`$select=roleid" -Headers $H).value.roleid
if ($assigned -contains $roleId) {
  Write-Host "  Role already assigned." -ForegroundColor DarkGray
} else {
  $body = @{ "@odata.id" = "$api/roles($roleId)" } | ConvertTo-Json
  Invoke-RestMethod -Uri "$api/systemusers($userId)/systemuserroles_association/`$ref" -Headers $H -Method Post -Body $body | Out-Null
  Write-Host "  ASSIGNED role '$RoleName'." -ForegroundColor Green
}
Write-Host "Done." -ForegroundColor Cyan
