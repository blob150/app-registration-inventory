#requires -Version 5.1
<#
.SYNOPSIS
  Deploys the Sync-AppRegistrations PowerShell runbook into an Azure Automation
  account and (optionally) creates a recurring schedule that runs it as the
  system-assigned managed identity.

.DESCRIPTION
  * Imports/updates Sync-AppRegistrations.ps1 as a PowerShell (5.1) runbook and publishes it.
  * Creates an hourly-interval schedule (default every 4 hours), created DISABLED
    for safety so the first (full baseline) run does not fire unattended.
  * Links the schedule to the runbook (job schedule), passing the -OrgUrl parameter.

  Prerequisites:
    - az login as a user with rights on the Automation account.
    - The Automation account has a system-assigned managed identity (see Grant-GraphRoles.ps1).
    - The Az.Accounts module is available in the Automation account (Modules blade).
      The runbook uses Connect-AzAccount -Identity + Get-AzAccessToken.

  After deploying, run the runbook once manually (bounded, e.g. MaxApps=50) to validate,
  then enable the schedule from the portal or:
    az automation schedule update -g <rg> --automation-account-name <aa> --name <schedule> --is-enabled true

.PARAMETER AutomationAccountName
  Target Automation account.

.PARAMETER ResourceGroup
  Resource group of the Automation account.

.PARAMETER EnvironmentUrl
  Dataverse org URL passed to the runbook (-OrgUrl), e.g. https://yourorg.crm.dynamics.com.

.PARAMETER IntervalHours
  Schedule interval in hours. Default 4.

.PARAMETER RunbookName
  Runbook name. Default: Sync-AppRegistrations.

.PARAMETER EnableSchedule
  Create the schedule enabled instead of disabled. Not recommended until validated.

.EXAMPLE
  ./Deploy-Runbook.ps1 -AutomationAccountName MyAutomationAccount -ResourceGroup my-rg `
      -EnvironmentUrl https://yourorg.crm.dynamics.com
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$AutomationAccountName,
  [Parameter(Mandatory=$true)][string]$ResourceGroup,
  [Parameter(Mandatory=$true)][string]$EnvironmentUrl,
  [int]$IntervalHours = 4,
  [string]$RunbookName = 'Sync-AppRegistrations',
  [switch]$EnableSchedule,
  [string]$SubscriptionId
)
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$scriptPath = Join-Path $PSScriptRoot 'Sync-AppRegistrations.ps1'
if (-not (Test-Path $scriptPath)) { throw "Sync-AppRegistrations.ps1 not found next to this script." }

if ($SubscriptionId) { az account set --subscription $SubscriptionId | Out-Null }
if (-not (az extension show --name automation 2>$null)) { az extension add --name automation --only-show-errors | Out-Null }
$sub = az account show --query id -o tsv

Write-Host "Importing runbook '$RunbookName' ..." -ForegroundColor Cyan
$exists = az automation runbook show --automation-account-name $AutomationAccountName --resource-group $ResourceGroup --name $RunbookName --query "name" -o tsv 2>$null
if (-not $exists) {
  $loc = az automation account show --name $AutomationAccountName --resource-group $ResourceGroup --query location -o tsv
  az automation runbook create --automation-account-name $AutomationAccountName --resource-group $ResourceGroup --name $RunbookName --type PowerShell --location $loc | Out-Null
}
az automation runbook replace-content --automation-account-name $AutomationAccountName --resource-group $ResourceGroup --name $RunbookName --content "@$scriptPath" | Out-Null
az automation runbook publish --automation-account-name $AutomationAccountName --resource-group $ResourceGroup --name $RunbookName | Out-Null
Write-Host "  Runbook published." -ForegroundColor Green

# Schedule
$scheduleName = "AppReg-Sync-Every${IntervalHours}h"
Write-Host "Creating schedule '$scheduleName' (every $IntervalHours h) ..." -ForegroundColor Cyan
$start = (Get-Date).AddHours(1).ToString("yyyy-MM-ddTHH:00:00zzz")
$already = az automation schedule show --automation-account-name $AutomationAccountName --resource-group $ResourceGroup --name $scheduleName --query "name" -o tsv 2>$null
if (-not $already) {
  az automation schedule create --automation-account-name $AutomationAccountName --resource-group $ResourceGroup --name $scheduleName `
     --frequency Hour --interval $IntervalHours --start-time "$start" `
     --description "Delta sync of Entra app registrations every $IntervalHours hours" | Out-Null
}
$enabled = $EnableSchedule.IsPresent.ToString().ToLower()
az automation schedule update --automation-account-name $AutomationAccountName --resource-group $ResourceGroup --name $scheduleName --is-enabled $enabled | Out-Null
Write-Host "  Schedule is-enabled=$enabled." -ForegroundColor Green

# Link schedule -> runbook (job schedule) via ARM, passing -OrgUrl
Write-Host "Linking schedule to runbook ..." -ForegroundColor Cyan
$guid = [guid]::NewGuid().ToString()
$uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/jobSchedules/$guid`?api-version=2023-11-01"
$body = @{ properties = @{ schedule = @{ name = $scheduleName }; runbook = @{ name = $RunbookName }; parameters = @{ OrgUrl = $EnvironmentUrl } } } | ConvertTo-Json -Depth 6
$tmp = New-TemporaryFile; $body | Set-Content $tmp -Encoding utf8
az rest --method put --uri $uri --headers "Content-Type=application/json" --body "@$tmp" | Out-Null
Remove-Item $tmp -Force
Write-Host "  Linked. OrgUrl=$EnvironmentUrl" -ForegroundColor Green

Write-Host ""
Write-Host "Deployed. Recommended validation before enabling the schedule:" -ForegroundColor Cyan
Write-Host "  Run a bounded test (via ARM REST, since CLI --parameters is unreliable):" -ForegroundColor Gray
Write-Host "    PUT .../automationAccounts/$AutomationAccountName/jobs/<guid>?api-version=2023-11-01" -ForegroundColor Gray
Write-Host "    body: { properties: { runbook: { name: '$RunbookName' }, parameters: { OrgUrl: '$EnvironmentUrl', MaxApps: '50' } } }" -ForegroundColor Gray
