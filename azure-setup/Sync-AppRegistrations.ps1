<#
.SYNOPSIS
  Syncs Microsoft Entra app registrations into Dataverse.
  Runs in Azure Automation using the account's system-assigned managed identity.

.DESCRIPTION
  Two modes:
    * Delta (default): Microsoft Graph /applications/delta. Persists deltaLink in the
      Sync State table so each run only pulls created/updated/deleted apps.
    * ResyncExisting (-ResyncExisting): re-reads ONLY the app object-IDs already present
      in Dataverse (scoped, no tenant-wide enumeration). Useful for targeted re-syncs
      and backfills. Honors the same manifest-hash change detection.

.NOTES
  MI needs Graph Application.Read.All + Directory.Read.All and to be a Dataverse application user.
#>
param(
  [Parameter(Mandatory=$true)]
  [string]$OrgUrl,             # e.g. https://yourorg.crm.dynamics.com  (no trailing slash)
  [int]$MaxApps = 0,            # 0 = all; >0 bounds the run (useful for tests)
  [switch]$Reset,              # ignore stored deltaLink, do a full resync (delta mode)
  [switch]$ResyncExisting,     # re-read only apps already in Dataverse
  [switch]$Force              # ignore manifest hash; always rewrite (with -ResyncExisting)
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$api = "$OrgUrl/api/data/v9.2"

# ---------------- Auth (managed identity) ----------------
Import-Module Az.Accounts -ErrorAction Stop
Connect-AzAccount -Identity | Out-Null

$script:tokenTime = Get-Date
$script:graphToken = $null
$script:dvToken = $null
function Get-PlainToken($res){
  $t = Get-AzAccessToken -ResourceUrl $res
  if ($t.Token -is [System.Security.SecureString]) {
    return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($t.Token))
  }
  return $t.Token
}
function Refresh-Tokens {
  $script:graphToken = Get-PlainToken "https://graph.microsoft.com/"
  $script:dvToken    = Get-PlainToken $OrgUrl
  $script:tokenTime  = Get-Date
}
function Ensure-Tokens { if ((Get-Date) - $script:tokenTime -gt [TimeSpan]::FromMinutes(45)) { Refresh-Tokens } }
Refresh-Tokens
Write-Output "Authenticated via managed identity."

# ---------------- Graph helper (paging + throttling) ----------------
function Invoke-GraphGet($url){
  for($i=0;$i -lt 8;$i++){
    Ensure-Tokens
    try {
      return Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $script:graphToken" } -Method Get
    } catch {
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      if ($code -eq 429 -or $code -eq 503) {
        $ra = 10; try { $ra = [int]$_.Exception.Response.Headers['Retry-After'] } catch {}
        Start-Sleep -Seconds ([Math]::Max($ra,5)); continue
      }
      if ($code -eq 401) { Refresh-Tokens; continue }
      throw
    }
  }
  throw "Graph GET failed after retries: $url"
}

# ---------------- Dataverse helper ----------------
function Invoke-Dv($method,$path,$body,$extraHeaders){
  for($i=0;$i -lt 6;$i++){
    Ensure-Tokens
    $h = @{ Authorization="Bearer $script:dvToken"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json"; "Content-Type"="application/json; charset=utf-8" }
    if ($extraHeaders) { $extraHeaders.GetEnumerator() | ForEach-Object { $h[$_.Key]=$_.Value } }
    try {
      if ($body) { return Invoke-RestMethod -Uri "$api/$path" -Headers $h -Method $method -Body $body }
      else       { return Invoke-RestMethod -Uri "$api/$path" -Headers $h -Method $method }
    } catch {
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      if ($code -eq 429 -or $code -eq 503) { Start-Sleep -Seconds 5; continue }
      if ($code -eq 401) { Refresh-Tokens; continue }
      throw
    }
  }
  throw "Dataverse $method failed after retries: $path"
}

# ---------------- Owner Power Platform premium license cache ----------------
# Standalone premium SKUs / service plans that grant Power Platform premium rights.
$script:premiumSkuPatterns = @(
  'POWERAPPS_PER_USER','POWERAPPS_PER_APP','POWERAPPS_PORTALS',
  'POWERAUTOMATE','FLOW_PER_USER','POWERAUTOMATE_PER_USER',
  'DYN365_ENTERPRISE','DYN365_ENTERPRISE_PLAN','Dynamics_365'
)
$script:premiumPlanPatterns = @(
  'POWERAPPS_PER_USER','Flow_PowerApps_PerUser','FLOW_PER_USER',
  'POWERAPPS_DYN_P2','FLOW_DYN_P2','DYN365_CDS_P2','POWERAPPS_DYN_APPS','FLOW_DYN_APPS'
)
$script:licCache = @{}
function Test-OwnerPremium($userId){
  if (-not $userId) { return $false }
  if ($script:licCache.ContainsKey($userId)) { return $script:licCache[$userId] }
  $isPrem = $false
  try {
    $ld = Invoke-GraphGet "https://graph.microsoft.com/v1.0/users/$userId/licenseDetails"
    foreach($l in $ld.value){
      foreach($p in $script:premiumSkuPatterns){ if ($l.skuPartNumber -like "*$p*"){ $isPrem=$true; break } }
      if ($isPrem){ break }
      foreach($sp in $l.servicePlans){
        if ($sp.provisioningStatus -ne 'Success'){ continue }
        foreach($p in $script:premiumPlanPatterns){ if ($sp.servicePlanName -like "*$p*"){ $isPrem=$true; break } }
        if ($isPrem){ break }
      }
      if ($isPrem){ break }
    }
  } catch { }
  $script:licCache[$userId] = $isPrem
  return $isPrem
}

# ---------------- Resource (API) permission-name cache ----------------
$script:resCache = @{}
function Get-ResourceInfo($appId){
  if ($script:resCache.ContainsKey($appId)) { return $script:resCache[$appId] }
  $info = @{ name = $appId; scopes = @{}; roles = @{} }
  try {
    $sp = Invoke-GraphGet "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$appId')?`$select=displayName,oauth2PermissionScopes,appRoles"
    $info.name = $sp.displayName
    foreach($s in $sp.oauth2PermissionScopes){ $info.scopes[$s.id] = $s.value }
    foreach($r in $sp.appRoles){ $info.roles[$r.id] = $r.value }
  } catch { }
  $script:resCache[$appId] = $info
  return $info
}

# ================= Per-app processor =================
# Returns: 'updated' | 'skipped' | 'error'
function Sync-OneApp($app,[bool]$force){
  $oid = $app.id
  try {
    # Manifest = full application object JSON; hash to detect change
    $manifest = ($app | ConvertTo-Json -Depth 40 -Compress)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($manifest))).Replace('-','')

    $cur = $null
    try { $cur = Invoke-Dv GET "appreg_appregistrations(appreg_objectid='$oid')?`$select=appreg_appregistrationid,appreg_manifesthash" } catch {}
    if (-not $force -and $cur -and $cur.appreg_manifesthash -eq $hash) { return 'skipped' }

    # Credentials (secrets + certs)
    $creds = @()
    foreach($pc in $app.passwordCredentials){ $creds += @{ type=1; keyId=$pc.keyId; name=$pc.displayName; start=$pc.startDateTime; end=$pc.endDateTime } }
    foreach($kc in $app.keyCredentials){
      $creds += @{ type=2; keyId=$kc.keyId; name=$kc.displayName; start=$kc.startDateTime; end=$kc.endDateTime; cn=$kc.displayName; thumb=$kc.customKeyIdentifier }
    }
    # FICs
    $fics = @()
    try { $fics = (Invoke-GraphGet "https://graph.microsoft.com/v1.0/applications/$oid/federatedIdentityCredentials").value } catch {}
    foreach($f in $fics){ $creds += @{ type=3; keyId=$f.id; name=$f.name; ficsubject=$f.subject; ficissuer=$f.issuer; ficaud=($f.audiences -join ', '); ficjson=($f | ConvertTo-Json -Depth 10 -Compress) } }

    # Earliest expiry
    $earliest = $null
    foreach($c in $creds){ if($c.end){ $d=[datetime]$c.end; if(-not $earliest -or $d -lt $earliest){$earliest=$d} } }

    # Owners  (NOTE: no $select - it nulls type-specific fields on the directoryObject nav)
    $owners = @()
    try { $owners = (Invoke-GraphGet "https://graph.microsoft.com/v1.0/applications/$oid/owners?`$top=100").value } catch {}
    $primaryEmail = $null
    if ($owners.Count -gt 0){ $primaryEmail = if($owners[0].mail){$owners[0].mail}else{$owners[0].userPrincipalName} }

    # Permissions (requiredResourceAccess)
    $perms = @()
    foreach($rra in $app.requiredResourceAccess){
      $ri = Get-ResourceInfo $rra.resourceAppId
      foreach($ra in $rra.resourceAccess){
        $ptype = if($ra.type -eq 'Role'){2}else{1}   # Role=Application, Scope=Delegated
        $pname = if($ptype -eq 2){ $ri.roles[$ra.id] } else { $ri.scopes[$ra.id] }
        if(-not $pname){ $pname = $ra.id }
        $perms += @{ resource=$ri.name; resourceAppId=$rra.resourceAppId; permission=$pname; ptype=$ptype }
      }
    }

    # Upsert parent (by alternate key)
    $now = (Get-Date).ToUniversalTime().ToString("o")
    $pbody = @{
      appreg_objectid = $oid
      appreg_name = $app.displayName
      appreg_appid = $app.appId
      appreg_signinaudience = $app.signInAudience
      appreg_publisherdomain = $app.publisherDomain
      appreg_manifest = $manifest
      appreg_manifesthash = $hash
      appreg_ownerless = ($owners.Count -eq 0)
      appreg_ownercount = $owners.Count
      appreg_businessowneremail = $primaryEmail
      appreg_lastsyncedon = $now
      appreg_lastchangedon = $now
    }
    if ($app.createdDateTime){ $pbody.appreg_appcreatedon = $app.createdDateTime }
    if ($earliest){ $pbody.appreg_earliestcredexpiry = $earliest.ToUniversalTime().ToString("o") }
    $pjson = ($pbody | ConvertTo-Json -Depth 10)
    Invoke-Dv PATCH "appreg_appregistrations(appreg_objectid='$oid')" $pjson @{ "Prefer"="return=representation" } | Out-Null

    $parentId = (Invoke-Dv GET "appreg_appregistrations(appreg_objectid='$oid')?`$select=appreg_appregistrationid").appreg_appregistrationid
    $bind = "/appreg_appregistrations($parentId)"

    # Rebuild children: delete existing then insert
    foreach($set in @("appreg_appcredentials","appreg_appowners","appreg_apppermissions")){
      $idProp = ($set.TrimEnd('s')) + "id"
      $kids = (Invoke-Dv GET "$set`?`$select=$idProp&`$filter=_appreg_appregistrationid_value eq $parentId").value
      foreach($k in $kids){ try { Invoke-Dv DELETE "$set($($k.$idProp))" $null $null } catch {} }
    }
    foreach($c in $creds){
      $cname = $c.name; if (-not $cname) { $cname = $c.keyId }
      $b = @{ "appreg_AppRegistrationId@odata.bind"=$bind; appreg_credtype=$c.type; appreg_keyid=$c.keyId; appreg_name=$cname }
      if($c.start){$b.appreg_startdate=$c.start}; if($c.end){$b.appreg_enddate=$c.end}
      if($c.end){ $b.appreg_daystoexpiry=[int]([datetime]$c.end - (Get-Date).ToUniversalTime()).TotalDays }
      if($c.cn){$b.appreg_certcn=$c.cn}; if($c.thumb){$b.appreg_certthumbprint=$c.thumb}
      if($c.ficsubject){$b.appreg_ficsubject=$c.ficsubject}; if($c.ficissuer){$b.appreg_ficissuer=$c.ficissuer}
      if($c.ficaud){$b.appreg_ficaudiences=$c.ficaud}; if($c.ficjson){$b.appreg_ficjson=$c.ficjson}
      try { Invoke-Dv POST "appreg_appcredentials" ($b|ConvertTo-Json -Depth 10) $null | Out-Null } catch { }
    }
    foreach($o in $owners){
      $isUser = ($o.'@odata.type' -eq '#microsoft.graph.user')
      $prem = if ($isUser) { Test-OwnerPremium $o.id } else { $false }
      $b = @{ "appreg_AppRegistrationId@odata.bind"=$bind; appreg_name=$o.displayName; appreg_upn=$o.userPrincipalName; appreg_ownerobjectid=$o.id; appreg_email=$o.mail; appreg_pppremium=$prem }
      if (-not $b.appreg_name) { $b.appreg_name = $o.id }
      try { Invoke-Dv POST "appreg_appowners" ($b|ConvertTo-Json -Depth 10) $null | Out-Null } catch { }
    }
    foreach($p in $perms){
      $b = @{ "appreg_AppRegistrationId@odata.bind"=$bind; appreg_name=$p.permission; appreg_resourcename=$p.resource; appreg_resourceappid=$p.resourceAppId; appreg_permission=$p.permission; appreg_permissiontype=$p.ptype; appreg_isgranted=$false }
      try { Invoke-Dv POST "appreg_apppermissions" ($b|ConvertTo-Json -Depth 10) $null | Out-Null } catch { }
    }
    return 'updated'
  } catch {
    Write-Warning "App $oid failed: $($_.Exception.Message)"
    return 'error'
  }
}

# ================= State (delta link) =================
$stateName = if ($ResyncExisting) { "applications-delta" } else { "applications-delta" }
$state = (Invoke-Dv GET "appreg_syncstates?`$select=appreg_syncstateid,appreg_deltalink&`$filter=appreg_name eq 'applications-delta'").value
$stateId = $null; $deltaLink = $null
if ($state -and $state.Count -gt 0){ $stateId = $state[0].appreg_syncstateid; $deltaLink = $state[0].appreg_deltalink }

$processed = 0; $skipped = 0; $deleted = 0; $errors = 0; $newDelta = $null; $stop = $false

if ($ResyncExisting) {
  # ---------- Scoped re-sync of apps already in Dataverse ----------
  Write-Output ("Mode: ResyncExisting (Force={0})" -f [bool]$Force)
  $objIds = @()
  $next = "appreg_appregistrations?`$select=appreg_objectid&`$top=5000"
  while($next){
    $r = Invoke-Dv GET $next
    $objIds += $r.value.appreg_objectid
    $next = $null
    if ($r.'@odata.nextLink'){ $next = ($r.'@odata.nextLink' -replace [regex]::Escape("$api/"),'') }
  }
  Write-Output "Existing apps in Dataverse: $($objIds.Count)"
  foreach($oid in $objIds){
    if ($MaxApps -gt 0 -and ($processed+$skipped) -ge $MaxApps) { $stop=$true; break }
    try {
      $app = Invoke-GraphGet "https://graph.microsoft.com/v1.0/applications/$oid"
    } catch {
      # App no longer exists in Entra -> tombstone
      try {
        $ex = (Invoke-Dv GET "appreg_appregistrations(appreg_objectid='$oid')?`$select=appreg_appregistrationid").appreg_appregistrationid
        if ($ex){ Invoke-Dv DELETE "appreg_appregistrations($ex)" $null $null; $deleted++ }
      } catch {}
      continue
    }
    switch (Sync-OneApp $app ([bool]$Force)) {
      'updated' { $processed++ }
      'skipped' { $skipped++ }
      'error'   { $errors++ }
    }
    if (($processed+$skipped) % 25 -eq 0){ Write-Output "  processed=$processed skipped=$skipped deleted=$deleted errors=$errors" }
  }
}
else {
  # ---------- Graph delta ----------
  $startUrl = if ($deltaLink -and -not $Reset) { $deltaLink } else { "https://graph.microsoft.com/v1.0/applications/delta" }
  Write-Output ("Mode: Delta - {0}" -f ($(if($deltaLink -and -not $Reset){'incremental (stored deltaLink)'}else{'FULL baseline'})))
  $url = $startUrl
  while($url -and -not $stop){
    $page = Invoke-GraphGet $url
    foreach($app in $page.value){
      if ($MaxApps -gt 0 -and ($processed+$skipped) -ge $MaxApps) { $stop=$true; break }
      if ($app.'@removed'){
        $oid = $app.id
        try {
          $ex = (Invoke-Dv GET "appreg_appregistrations(appreg_objectid='$oid')?`$select=appreg_appregistrationid").appreg_appregistrationid
          if ($ex){ Invoke-Dv DELETE "appreg_appregistrations($ex)" $null $null; $deleted++ }
        } catch {}
        continue
      }
      switch (Sync-OneApp $app $false) {
        'updated' { $processed++ }
        'skipped' { $skipped++ }
        'error'   { $errors++ }
      }
      if (($processed+$skipped) % 50 -eq 0){ Write-Output "  processed=$processed skipped=$skipped deleted=$deleted errors=$errors" }
    }
    if ($stop) { break }
    if ($page.'@odata.nextLink'){ $url = $page.'@odata.nextLink' }
    elseif ($page.'@odata.deltaLink'){ $newDelta = $page.'@odata.deltaLink'; $url = $null }
    else { $url = $null }
  }
}

# ================= Persist sync state =================
$mode = if ($ResyncExisting) { "ResyncExisting" } else { "Delta" }
$status = "Success"; if ($errors -gt 0){ $status = "CompletedWithErrors($errors)" }; if ($stop){ $status = "Bounded(MaxApps=$MaxApps)" }
$details = "mode=$mode processed=$processed skipped=$skipped deleted=$deleted errors=$errors"
$sbody = @{
  appreg_name = $stateName
  appreg_lastrunon = (Get-Date).ToUniversalTime().ToString("o")
  appreg_lastrunstatus = $status
  appreg_appsprocessed = $processed
  appreg_lastrundetails = $details
}
# Only advance the stored deltaLink on a complete delta pass (never in resync/bounded)
if ($newDelta -and -not $stop -and -not $ResyncExisting){ $sbody.appreg_deltalink = $newDelta }
$sjson = ($sbody | ConvertTo-Json -Depth 10)
if ($stateId){ Invoke-Dv PATCH "appreg_syncstates($stateId)" $sjson $null | Out-Null }
else { Invoke-Dv POST "appreg_syncstates" $sjson $null | Out-Null }

Write-Output "DONE. $details status=$status"
