#requires -Version 5.1
<#
.SYNOPSIS
  Starts the Sync-AppRegistrations runbook with parameters and (optionally) waits for it.

.DESCRIPTION
  Starts the job via the Azure Resource Manager REST API rather than
  `az automation runbook start --parameters`, because the experimental CLI does not
  reliably pass parameters into the job. Use this for bounded test runs and manual
  re-syncs.

.PARAMETER AutomationAccountName
  Automation account hosting the runbook.

.PARAMETER ResourceGroup
  Resource group of the Automation account.

.PARAMETER EnvironmentUrl
  Dataverse org URL passed as -OrgUrl to the runbook.

.PARAMETER MaxApps
  Bound the run to N apps (0 = all). Handy for a first, controlled test (e.g. 50).

.PARAMETER ResyncExisting
  Re-read only the object-IDs already present in Dataverse (scoped, no tenant enumeration).

.PARAMETER Force
  With -ResyncExisting, rewrite every record regardless of manifest hash (backfills).

.PARAMETER Reset
  Delta mode only: ignore the stored deltaLink and do a full baseline.

.PARAMETER Wait
  Poll until the job completes and print the output stream.

.EXAMPLE
  # Bounded first test of 50 apps
  ./Start-SyncJob.ps1 -AutomationAccountName MyAutomationAccount -ResourceGroup my-rg `
     -EnvironmentUrl https://yourorg.crm.dynamics.com -MaxApps 50 -Wait
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$AutomationAccountName,
  [Parameter(Mandatory=$true)][string]$ResourceGroup,
  [Parameter(Mandatory=$true)][string]$EnvironmentUrl,
  [int]$MaxApps = 0,
  [switch]$ResyncExisting,
  [switch]$Force,
  [switch]$Reset,
  [string]$RunbookName = 'Sync-AppRegistrations',
  [switch]$Wait,
  [string]$SubscriptionId
)
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
if ($SubscriptionId) { az account set --subscription $SubscriptionId | Out-Null }
$sub = az account show --query id -o tsv

$params = @{ OrgUrl = $EnvironmentUrl }
if ($MaxApps -gt 0)          { $params.MaxApps = "$MaxApps" }
if ($ResyncExisting)         { $params.ResyncExisting = "true" }
if ($Force)                  { $params.Force = "true" }
if ($Reset)                  { $params.Reset = "true" }

$jobId = [guid]::NewGuid().ToString()
$base = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/jobs/$jobId"
$body = @{ properties = @{ runbook = @{ name = $RunbookName }; parameters = $params } } | ConvertTo-Json -Depth 6
$tmp = New-TemporaryFile; $body | Set-Content $tmp -Encoding utf8
az rest --method put --uri "$base`?api-version=2023-11-01" --headers "Content-Type=application/json" --body "@$tmp" --query "properties.status" -o tsv | Out-Null
Remove-Item $tmp -Force
Write-Host "Started job $jobId (params: $($params.Keys -join ', '))" -ForegroundColor Green

if ($Wait) {
  do {
    Start-Sleep -Seconds 20
    $status = az rest --method get --uri "$base`?api-version=2023-11-01" --query "properties.status" -o tsv
    Write-Host "  status: $status"
  } while ($status -in @('New','Activating','Running','Queued'))
  Write-Host "=== output ===" -ForegroundColor Cyan
  az rest --method get --uri "$base/output?api-version=2023-11-01" 2>$null | Where-Object { $_ -notmatch 'Not a json' -and $_.Trim() -ne '' }
}
