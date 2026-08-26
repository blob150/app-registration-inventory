#requires -Version 5.1
<#
.SYNOPSIS
  Grants the Azure Automation account's system-assigned managed identity the
  Microsoft Graph application permissions required to read app registrations
  and resolve owner details.

.DESCRIPTION
  Grants (app-role assignments on the Microsoft Graph service principal):
    * Application.Read.All  - read all application registrations + credentials/permissions metadata
    * Directory.Read.All    - resolve owner display name / UPN / mail and owner license details

  Requires the caller to be signed in with Azure CLI (az login) as a user who can
  grant Microsoft Graph app roles (e.g. Privileged Role Administrator / Global
  Administrator / Cloud Application Administrator).

  Idempotent: skips any grant that already exists.

.PARAMETER AutomationAccountName
  Name of the Azure Automation account whose system-assigned managed identity gets the grants.

.PARAMETER ResourceGroup
  Resource group containing the Automation account.

.PARAMETER SubscriptionId
  Optional. Azure subscription to target. Defaults to the current az context.

.EXAMPLE
  ./Grant-GraphRoles.ps1 -AutomationAccountName MyAutomationAccount -ResourceGroup my-rg
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$AutomationAccountName,
  [Parameter(Mandatory=$true)][string]$ResourceGroup,
  [string]$SubscriptionId
)
$ErrorActionPreference = 'Stop'

$GRAPH_APPID = '00000003-0000-0000-c000-000000000000'
$ROLES = @('Application.Read.All','Directory.Read.All')

if ($SubscriptionId) { az account set --subscription $SubscriptionId | Out-Null }

Write-Host "Resolving managed identity for $AutomationAccountName ..." -ForegroundColor Cyan
if (-not (az extension show --name automation 2>$null)) { az extension add --name automation --only-show-errors | Out-Null }
$principalId = az automation account show --name $AutomationAccountName --resource-group $ResourceGroup --query "identity.principalId" -o tsv
if (-not $principalId) { throw "Automation account has no system-assigned managed identity. Enable it first (Identity blade)." }
Write-Host "  MI principalId: $principalId"

$graphSpId = az ad sp show --id $GRAPH_APPID --query "id" -o tsv
$appRoles  = az ad sp show --id $GRAPH_APPID --query "appRoles" -o json | ConvertFrom-Json
$existing  = az rest --method get --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" --query "value[].appRoleId" -o json | ConvertFrom-Json

foreach ($roleValue in $ROLES) {
  $role = $appRoles | Where-Object { $_.value -eq $roleValue }
  if (-not $role) { Write-Warning "Role $roleValue not found on Graph SP"; continue }
  if ($existing -contains $role.id) { Write-Host "  already granted: $roleValue" -ForegroundColor DarkGray; continue }
  $body = @{ principalId = $principalId; resourceId = $graphSpId; appRoleId = $role.id } | ConvertTo-Json -Compress
  $tmp = New-TemporaryFile; $body | Set-Content $tmp -Encoding utf8
  az rest --method post --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" --headers "Content-Type=application/json" --body "@$tmp" | Out-Null
  Remove-Item $tmp -Force
  Write-Host "  GRANTED: $roleValue" -ForegroundColor Green
}
Write-Host "Done. (Grants can take a minute to propagate.)" -ForegroundColor Cyan
