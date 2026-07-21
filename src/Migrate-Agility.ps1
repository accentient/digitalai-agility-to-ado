##################################################################################################
# Script to migrate work items from digital.ai Agility (formerly VersionOne) into Azure DevOps.
#
#   Epic (top level)   -> Epic
#   Epic (nested)      -> Feature      ADO has only two portfolio levels, so nested Epics cannot
#                                      stay Epics without breaking backlog ordering.
#   Story              -> Product Backlog Item
#   Defect             -> Bug
#   Task               -> Task           parented to its Story or Defect
#   Issue              -> Impediment     with Affects links to the work items it blocks
#
# Agility is only ever read from. Every Agility call goes through InvokeAgilityGet, which hard
# codes -Method Get, so this script has no code path that can modify anything in Agility.
#
# Each created work item is tagged agility:<Number> so reruns skip what already exists. Types are
# migrated in dependency order, so a Story can find the Epic it belongs to.
#
# Edit the Migrate calls in Main to control what runs. Config and mappings are read from
# appsettings.json and mappings.json next to this script's parent folder.
#
# Every Migrate call writes its own log to logs/Migrate-Agility-<yyyyMMdd-HHmmss>.log: a faithful
# copy of the console, plus the full detail behind each failure.
##################################################################################################

$script:configPath = Join-Path $PSScriptRoot ".." "appsettings.json"
$script:mappingsPath = Join-Path $PSScriptRoot ".." "mappings.json"
# Resolved rather than left as src\..\logs: this is the one path the operator has to find again
# after a run, so it gets printed, and a printed path should be one they can paste.
$script:logDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".." "logs"))
$script:logPath = $null
$script:logWriter = $null
$script:totalFailed = 0
$script:TitleLimit = 255

# Stands in for an ADO id in the tag map during a dry run.
#
# A real run creates in dependency order and adds each new id to the tag map, so by the time Issues
# are written the Stories they block are in it and the links resolve. A dry run writes nothing, so
# without this the map only ever holds items from EARLIER runs, and every link to something the
# same run would create reports as "NOT IN ADO". That is a false negative, and the kind this
# project has been bitten by: a dry run that understates what a real run does is still a dry run
# that lies. Never sent to ADO - only the dry run path ever puts it in the map.
$script:DryRunPendingId = 'would-be-created-by-this-run'

function Main
{
  # clear-host throws when the host has no console handle, as in CI or any redirected run.
  try { clear-host } catch { }

  Write-Host "Migrate-Agility starting" -ForegroundColor Cyan
  Write-Host

  # Futz with these. -DryRun writes nothing, to either system.
  # CreateAreaPaths -DryRun                                         # list the area nodes needed
  # CreateAreaPaths                                                 # create them; run after adding a scope
  # MaterializeOwners -DryRun -Types Epic                          # list owners that would be added to the org
  # MaterializeOwners -Types Epic                                  # add them as free Stakeholders (needs admin PAT)
  # MaterializeOwners                                              # all types' owners, before the full migration
  # DeleteAllTasks -DryRun                                         # count the Tasks that would be deleted
  # DeleteAllTasks                                                 # PERMANENTLY delete every Task, then re-run Tasks
  # Migrate -DryRun -IncludeClosed -Types Story,Defect,Issue
  # Migrate -DryRun -IncludeClosed -Types Task -Scope "Scope:2463"  # Task has NEVER been dry run
  # Migrate -DryRun -IncludeClosed -Types Story,Defect,Issue -Scope "Scope:2463"  # one scope
  # Migrate -IncludeClosed -Types Story,Defect,Issue                # the real thing, 8,673 items
  # Migrate -DryRun -IncludeClosed                                  # all five types, ~52,000 items
  # Migrate -IncludeClosed -Types Task                              # 43,436 Tasks on their own
  # Migrate -Types Task                                             # 2,275 open Tasks only
  # Migrate -DryRun -IncludeClosed -Scope "Scope:16163"             # the EDU scope (Scope:16163), 466 items
  # Migrate -DryRun -IncludeClosed -Scope "Scope:16163"

  # Migrate -Types Epic -IncludeClosed
  # Migrate -IncludeClosed 

  # DeleteAllTasks
  # Migrate -Types Task -IncludeClosed  

}

# The whole run: read Agility, resolve links, write Azure DevOps.
#
# -Scope narrows to one configured scope. Without it every configured scope migrates, because Epic
# parents cross scope boundaries and only a whole-set run resolves them all.
#
# -Types selects which Agility asset types to migrate. The order below is dependency order: Epics
# must exist before Stories and Defects can be parented to them. Reruns are safe, so re-including
# Epic just skips the 858 already there.
function Migrate([switch]$DryRun, [string]$Scope, [switch]$IncludeClosed, [string[]]$Types = @('Epic','Story','Defect','Task','Issue'))
{
  # Inner functions read these, and each call starts a fresh run.
  $script:DryRun = [bool]$DryRun
  $script:IncludeClosed = [bool]$IncludeClosed
  $script:created = 0
  $script:skipped = 0
  $script:failed = 0
  $script:warnings = 0
  # Raw values a value map has never seen (id, type, map, raw). Not written to their field, recorded
  # here so a new Team or strategic theme surfaces in the summary instead of vanishing.
  $script:fieldWarnings = @()

  # Probe ADO for whether each owner identity is assignable, and cache the verdict per person, so the
  # migration can try each owner and promote an assignable one rather than giving up on a departed
  # first owner. Off outside a run (unit tests resolve the first candidate without touching ADO).
  $script:ProbeAssignability = $true
  $script:assignableCache = @{}

  # Before anything that can fail, so a bad config or a missing token lands in the log too.
  StartLog
  $script:runStarted = Get-Date
  WriteLogDetail "Migrate-Agility log, started $($script:runStarted.ToString('yyyy-MM-dd HH:mm:ss'))"
  WriteLogDetail "Switches: DryRun=$($script:DryRun) IncludeClosed=$($script:IncludeClosed) Types=$($Types -join ',') Scope=$(if ($Scope) { $Scope } else { 'all configured' })"
  WriteLogDetail ""

  $script:config = GetConfig $script:configPath
  $script:mappings = GetConfig $script:mappingsPath

  $scopes = $script:config.Agility.Scopes
  if ($Scope)
  {
    $scopes = $scopes | Where-Object { $_.Scope -eq $Scope }
    if (-not $scopes) { throw "Scope '$Scope' is not in appsettings.json. Configured: $(($script:config.Agility.Scopes | ForEach-Object { $_.Scope }) -join ', ')" }
  }

  # Say what is about to happen before touching credentials or the network, so a failure in either
  # lands under a banner instead of on a blank screen.
  WriteLog "Migrating $($Types -join ', ') from $($script:config.Agility.BaseUrl)"
  WriteLog "Into $($script:config.AzureDevOps.OrganizationUrl) project $($script:config.AzureDevOps.Project)"
  foreach ($s in $scopes) { WriteLog "  $($s.Scope) -> area path $(FormatAreaPath $s.AreaPath)" }
  if ($script:DryRun) { WriteLog "DRY RUN - nothing will be written to Azure DevOps" Yellow }
  if ($script:IncludeClosed) { WriteLog "Including closed items" }
  WriteLog

  WriteLog "Resolving credentials..."
  $script:agilityHeaders = BuildAgilityHeaders
  $script:adoHeaders = BuildAdoHeaders
  WriteLog "  Agility token and Azure DevOps PAT resolved"
  WriteLog

  # Fail before the first create, not on the first transition after it, and not on a silent drop
  # that never fails at all.
  AssertStatesExist $Types
  AssertFieldsExist $Types

  # One tag map for the whole run, shared by every type. This is what lets a Story find the Epic
  # it belongs to, whether that Epic was migrated in this run or an earlier one.
  $existing = GetMigratedIdMap
  WriteLog "Found $($existing.Count) previously migrated items in Azure DevOps"
  WriteLog

  # Bridges Agility oids to Numbers, because links are expressed in oids but the tag map is keyed
  # by Number. Accumulates across types so a Story can resolve its Epic.
  $script:numberByOid = @{}

  # Dependency order, not the caller's order. Epics first so Stories and Defects can parent to
  # them; Tasks after both, since a Task parents to a Story or a Defect; Issues last, because the
  # Affects links they carry point at all three.
  foreach ($type in @('Epic','Story','Defect','Task','Issue'))
  {
    if ($Types -notcontains $type) { continue }

    if ($type -eq 'Epic') { MigrateEpics $scopes $existing }
    else { MigrateWorkitems $type $scopes $existing }
  }

  WriteSummary
}

# Creates the Azure DevOps area nodes the configured scopes and their Themes need.
#
# Run this once after adding a scope or a ThemeAreaPaths entry, before migrating. ADO rejects an
# unknown area path outright with TF401347 rather than dropping it silently, so a missing node is
# loud, but it is loud once per item: a single absent leaf fails every Story that uses that Theme.
#
# What it creates is DERIVED from the live Agility data, not a hard coded list, because
# ThemeAreaPaths is a global name -> leaf map while the leaf hangs off each scope's own area path.
# Only the data says which scope actually uses which Theme, and creating every leaf under every
# scope would invent nodes nobody asked for.
#
# Idempotent: an existing node is left alone, so this is safe to rerun. -DryRun lists without
# creating.
function CreateAreaPaths([switch]$DryRun)
{
  $script:DryRun = [bool]$DryRun
  # Themes on closed items count: the Theme list measured off open Stories alone is missing 13 of
  # the 17, which is exactly how ~1,236 items came to have no mapping.
  $script:IncludeClosed = $true
  $script:created = 0
  $script:skipped = 0
  $script:failed = 0
  $script:warnings = 0

  StartLog
  $script:runStarted = Get-Date
  WriteLogDetail "CreateAreaPaths log, started $($script:runStarted.ToString('yyyy-MM-dd HH:mm:ss'))"
  WriteLogDetail ""

  $script:config = GetConfig $script:configPath
  $script:mappings = GetConfig $script:mappingsPath

  WriteLog "Creating area paths in $($script:config.AzureDevOps.OrganizationUrl) project $($script:config.AzureDevOps.Project)"
  if ($script:DryRun) { WriteLog "DRY RUN - nothing will be written to Azure DevOps" Yellow }
  WriteLog

  WriteLog "Resolving credentials..."
  $script:agilityHeaders = BuildAgilityHeaders
  $script:adoHeaders = BuildAdoHeaders
  WriteLog

  $have = GetAreaPaths
  WriteLog "Found $($have.Count) existing area nodes"
  WriteLog

  foreach ($s in $script:config.Agility.Scopes)
  {
    WriteLog "--- $($s.Scope) -> $(FormatAreaPath $s.AreaPath) ---" Cyan

    # The scope's own node first: a Theme leaf cannot hang off a parent that does not exist.
    EnsureAreaPath $s.AreaPath $have

    # Only Story and Defect carry a Theme, so only they can need a leaf. Epic, Task and Issue have
    # no Theme and land on the scope's own area path.
    $themes = @{}
    foreach ($type in @('Story','Defect'))
    {
      foreach ($a in (GetAgilityAssets $type $s.Scope))
      {
        if ($a.Theme) { $themes[$a.Theme] = ($themes[$a.Theme] + 1) }
      }
    }

    foreach ($theme in ($themes.Keys | Sort-Object))
    {
      $leaf = $script:mappings.ThemeAreaPaths.PSObject.Properties[$theme]
      if (-not $leaf)
      {
        WriteLog "  WARN    Theme '$theme' ($($themes[$theme]) items) has no ThemeAreaPaths entry, those items will sit at $(FormatAreaPath $s.AreaPath)" Yellow
        $script:warnings++
        continue
      }

      $path = if ($s.AreaPath) { "$($s.AreaPath)\$($leaf.Value)" } else { $leaf.Value }
      EnsureAreaPath $path $have $themes[$theme]
    }

    WriteLog
  }

  WriteSummary
}

# One area node, created only if it is missing. $have is the set of paths already in ADO, updated in
# place so a later leaf sees a parent this run just created.
function EnsureAreaPath([string]$areaPath, $have, [int]$itemCount = 0)
{
  if (-not $areaPath) { return }

  $count = if ($itemCount) { " ($itemCount items)" } else { "" }

  if ($have.ContainsKey($areaPath.ToLowerInvariant()))
  {
    WriteLog "  EXISTS  $(FormatAreaPath $areaPath)$count"
    $script:skipped++
    return
  }

  if ($script:DryRun)
  {
    WriteLog "  WOULD   $(FormatAreaPath $areaPath)$count"
    $have[$areaPath.ToLowerInvariant()] = $true
    $script:created++
    return
  }

  # The API takes the PARENT path in the url and the new node's name in the body, so split them.
  $parts = $areaPath.Split('\')
  $name = $parts[-1]
  $parent = if ($parts.Count -gt 1) { ($parts[0..($parts.Count - 2)] -join '\') } else { "" }

  $url = "{0}/{1}/_apis/wit/classificationnodes/areas/{2}?api-version=7.1" -f `
    $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'),
    [uri]::EscapeDataString($script:config.AzureDevOps.Project),
    (($parent.Split('\') | Where-Object { $_ } | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')

  try
  {
    InvokeAdoRequest $url "Post" @{ name = $name } "application/json" | Out-Null
    WriteLog "  CREATE  $(FormatAreaPath $areaPath)$count" Green
    $have[$areaPath.ToLowerInvariant()] = $true
    $script:created++
  }
  catch
  {
    WriteLog "  FAIL    $(FormatAreaPath $areaPath) - $(ReadAdoError $_)" Red
    WriteErrorDetail $_ "area path $areaPath"
    $script:failed++
  }
}

# Every area path already in the project, keyed lower case because ADO treats node names as case
# insensitive and would 409 on a case-only difference.
function GetAreaPaths
{
  $url = "{0}/{1}/_apis/wit/classificationnodes/Areas?`$depth=10&api-version=7.1" -f `
    $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'),
    [uri]::EscapeDataString($script:config.AzureDevOps.Project)

  $root = InvokeAdoRequest $url "Get" $null $null
  $paths = @{}

  # Iterative rather than recursive, and guarded: a leaf's children property is absent rather than
  # empty, and @($null) is a one element array, so a naive walk enqueues null forever.
  $queue = [System.Collections.Queue]::new()
  $queue.Enqueue(@{ Node = $root; Path = "" })

  while ($queue.Count -gt 0)
  {
    $current = $queue.Dequeue()
    $node = $current.Node

    # The root node is the project itself and is not part of the path the config stores.
    if ($current.Path) { $paths[$current.Path.ToLowerInvariant()] = $true }

    if (-not $node.PSObject.Properties['children'] -or -not $node.children) { continue }

    foreach ($child in @($node.children | Where-Object { $_ }))
    {
      $childPath = if ($current.Path) { "$($current.Path)\$($child.name)" } else { $child.name }
      $queue.Enqueue(@{ Node = $child; Path = $childPath })
    }
  }

  return $paths
}

##################################################################################################
# MaterializeOwners - add Agility owners to the ADO org as free Stakeholders, so they are assignable
##################################################################################################

# Why this exists: ADO's `System.AssignedTo` only accepts identities that are MATERIALIZED members
# of the organization, while the web people-picker searches the whole Entra directory. So a real
# person like dana.reyes@example.com shows in the picker and assigns in the UI (the UI adds them to the
# org on save), but a plain REST write is rejected as "not in the list of supported values". This
# pre-pass does what the UI does, once, up front: it adds each recoverable owner to the org as a
# Stakeholder (free, unlimited, and Stakeholders CAN be assignees). After it runs, the migration's
# existing assignability probe assigns them by email with no further change.
#
# It CANNOT rescue an owner who was removed from Entra (departed): the entitlement call fails for
# them, which is exactly how the run reports who is genuinely unrecoverable. Those stay unassigned
# with the owner recorded in Custom.DigitalAIOwners, which is correct.
#
# It needs a DIFFERENT token from the migration: the Member Entitlement Management (write) scope,
# owned by a Project Collection Administrator. The work-item PAT returns 401 here. Idempotent: an
# owner already in the org is reported EXISTS, so it is safe to rerun. -DryRun lists without adding.
function MaterializeOwners([switch]$DryRun, [string[]]$Types = @('Epic', 'Story', 'Defect', 'Task', 'Issue'))
{
  $script:DryRun = [bool]$DryRun
  # Closed items' owners count too: an owner only on closed work still needs to exist to be assigned.
  $script:IncludeClosed = $true
  $script:created = 0
  $script:skipped = 0
  $script:failed = 0
  $script:warnings = 0
  $script:fieldWarnings = @()

  StartLog
  $script:runStarted = Get-Date
  WriteLogDetail "MaterializeOwners log, started $($script:runStarted.ToString('yyyy-MM-dd HH:mm:ss'))"
  WriteLogDetail "Types=$($Types -join ',')"
  WriteLogDetail ""

  $script:config = GetConfig $script:configPath
  $script:mappings = GetConfig $script:mappingsPath

  WriteLog "Adding Agility owners to $($script:config.AzureDevOps.OrganizationUrl) as free Stakeholders, so they can be assigned"
  if ($script:DryRun) { WriteLog "DRY RUN - no one will be added to the organization" Yellow }
  WriteLog

  WriteLog "Resolving credentials..."
  $script:agilityHeaders = BuildAgilityHeaders
  # The admin PAT (Member Entitlement Management write + PCA), NOT the work-item PAT.
  $script:adoHeaders = BuildAdoAdminHeaders
  WriteLog

  WriteLog "Reading owners for $($Types -join ', ') across $($script:config.Agility.Scopes.Count) scopes (closed included)..."
  $owners = GetDistinctOwners $Types
  WriteLog "Found $($owners.Count) distinct owner emails"
  WriteLog

  # Busiest owners first, so the most impactful adds are at the top of the log.
  foreach ($owner in ($owners | Sort-Object { -$_.Count }))
  {
    MaterializeOwner $owner
  }

  WriteLog
  WriteLog "ADDED = new org member (now assignable). EXISTS = already a member. FAIL = could not be" Cyan
  WriteLog "added, i.e. removed from Entra or a permissions issue; those stay unassigned by design." Cyan
  WriteSummary
}

# One owner, added to the org as a Stakeholder unless already present. The entitlement endpoint
# returns HTTP 200 EVEN ON FAILURE, with the real verdict in operationResult, so EntitleStakeholder
# reads that rather than trusting the status code.
function MaterializeOwner($owner)
{
  $label = "$($owner.Name) <$($owner.Email)> ($($owner.Count) items)"

  if ($script:DryRun)
  {
    WriteLog "  WOULD   add $label"
    $script:created++
    return
  }

  $result = EntitleStakeholder $owner.Email
  switch ($result.Status)
  {
    'added'  { WriteLog "  ADDED   $label" Green; $script:created++ }
    'exists' { WriteLog "  EXISTS  $label"; $script:skipped++ }
    default
    {
      WriteLog "  FAIL    $label - $($result.Detail)" Yellow
      WriteLogDetail "  entitlement failed for $($owner.Email): $($result.Detail)"
      $script:failed++
    }
  }
}

# The distinct email-bearing owners across the given types and all configured scopes, each with a
# count of how many items name them. Keyed by lower case email, so the same person on 40 items is one
# entry. Owners with NO email (Vendor, ITUS Student Worker) are skipped: materialization is by
# principalName, so there is nothing to add them by.
function GetDistinctOwners($agilityTypes)
{
  $owners = @{}

  foreach ($type in $agilityTypes)
  {
    # Issue has the singular Owner; every other type has multi value Owners.
    $ownerAttr = if ($type -eq 'Issue') { 'Owner' } else { 'Owners' }
    $selection = "Number,$ownerAttr.Name,$ownerAttr.Email"

    foreach ($s in $script:config.Agility.Scopes)
    {
      $where = "Scope='$($s.Scope)'"
      $where += if ($script:IncludeClosed) { ";AssetState!='Dead'" } else { ";AssetState!='Closed'" }

      $start = 0
      while ($true)
      {
        $url = "{0}/rest-1.v1/Data/{1}?sel={2}&where={3}&page=500,{4}" -f `
          $script:config.Agility.BaseUrl.TrimEnd('/'),
          $type,
          [uri]::EscapeDataString($selection),
          [uri]::EscapeDataString($where),
          $start

        $response = InvokeAgilityGet $url
        $assets = @($response.Assets)
        if ($assets.Count -eq 0) { break }

        foreach ($a in $assets)
        {
          $names  = @(GetAttributeValuesAligned $a.Attributes "$ownerAttr.Name")
          $emails = @(GetAttributeValuesAligned $a.Attributes "$ownerAttr.Email")
          for ($i = 0; $i -lt $names.Count; $i++)
          {
            $email = if ($i -lt $emails.Count) { $emails[$i] } else { $null }
            if (-not $email) { continue }

            $key = $email.ToLowerInvariant()
            if (-not $owners.ContainsKey($key))
            {
              $owners[$key] = [pscustomobject]@{ Name = $names[$i]; Email = $email; Count = 0 }
            }
            $owners[$key].Count++
          }
        }

        if ($assets.Count -lt 500) { break }
        $start += 500
      }
    }
  }

  return @($owners.Values)
}

# Adds one user to the org as a Stakeholder (free). Returns { Status = added | exists | failed;
# Detail }. The Member Entitlement Management endpoint returns HTTP 200 with an error body on
# failure, so the verdict is operationResult.isSuccess, not the status code.
function EntitleStakeholder([string]$email)
{
  $orgName = ($script:config.AzureDevOps.OrganizationUrl.TrimEnd('/') -split '/')[-1]
  $url = "https://vsaex.dev.azure.com/$orgName/_apis/userentitlements?api-version=7.1"

  # Stakeholder is free and unlimited, and a Stakeholder can be an assignee. Do NOT use 'express'
  # (Basic): only the first 5 Basic seats are free.
  $body = @{
    accessLevel = @{ licensingSource = 'account'; accountLicenseType = 'stakeholder' }
    user        = @{ principalName = $email; subjectKind = 'user' }
  }

  try
  {
    $response = InvokeAdoRequest $url "Post" $body "application/json"

    $op = $response.operationResult
    if ($op -and $op.PSObject.Properties['isSuccess'] -and -not $op.isSuccess)
    {
      $detail = (@($op.errors) | ForEach-Object { $_.value }) -join '; '
      if (-not $detail) { $detail = "the entitlement API reported failure with no message" }
      # An already-entitled user is a success for our purpose, not a failure.
      if ($detail -match 'already') { return [pscustomobject]@{ Status = 'exists'; Detail = $detail } }
      return [pscustomobject]@{ Status = 'failed'; Detail = $detail }
    }

    return [pscustomobject]@{ Status = 'added'; Detail = $op.userId }
  }
  catch { return [pscustomobject]@{ Status = 'failed'; Detail = (ReadAdoError $_) } }
}

##################################################################################################
# DeleteAllTasks - permanently delete every Task work item, to re-migrate them cleanly
##################################################################################################

# Deletes ONLY Task work items in the project, so a broken Task run can be redone. It exists because
# a failed Task is still IN ADO (created, then a later patch failed), counted FAIL, and GetMigratedIdMap
# would SKIP it on a rerun - leaving it broken forever. Removing the Tasks makes the rerun re-create
# them. Epics, Features, PBIs, Bugs and Impediments are NOT touched.
#
# destroy=true is PERMANENT: the Tasks do not go to the recycle bin and cannot be recovered. That is
# the intent (a clean slate for 40k+ Tasks would otherwise flood the bin). -DryRun reports the count
# without deleting. The WHERE clause is hard pinned to System.WorkItemType = 'Task'; a test asserts it.
function DeleteAllTasks([switch]$DryRun)
{
  $script:DryRun = [bool]$DryRun
  $deleted = 0
  $failed = 0

  StartLog
  $script:runStarted = Get-Date
  WriteLogDetail "DeleteAllTasks log, started $($script:runStarted.ToString('yyyy-MM-dd HH:mm:ss'))"
  WriteLogDetail ""

  $script:config = GetConfig $script:configPath

  WriteLog "Deleting ALL Task work items in $($script:config.AzureDevOps.OrganizationUrl) project $($script:config.AzureDevOps.Project)"
  if ($script:DryRun) { WriteLog "DRY RUN - nothing will be deleted" Yellow }
  else { WriteLog "PERMANENT (destroy=true): these Tasks CANNOT be recovered from the recycle bin" Red }
  WriteLog

  WriteLog "Resolving credentials..."
  $script:adoHeaders = BuildAdoHeaders
  WriteLog

  $org = $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/')
  $ids = GetAllTaskIds
  WriteLog "Found $($ids.Count) Task work items"
  WriteLog

  if ($script:DryRun)
  {
    WriteLog "  WOULD delete $($ids.Count) Tasks (destroy, permanent). First ids: $((@($ids) | Select-Object -First 10) -join ', ')"
  }
  else
  {
    $i = 0
    foreach ($id in $ids)
    {
      $i++
      $url = "$org/_apis/wit/workitems/$id`?destroy=true&api-version=7.1"
      try
      {
        InvokeAdoRequest $url "Delete" $null $null | Out-Null
        $deleted++
      }
      catch
      {
        WriteLog "  FAIL    #$id could not be deleted - $(ReadAdoError $_)" Red
        WriteErrorDetail $_ "delete Task #$id"
        $failed++
      }

      # Progress without a line per item: 40k lines would bury the log.
      if ($i % 500 -eq 0) { WriteLog "  deleted $i / $($ids.Count)..." }
    }
  }

  WriteLog
  WriteLog "----------------------------------------"
  WriteLog "$(if ($script:DryRun) { 'Would delete:' } else { 'Deleted: ' })  $(if ($script:DryRun) { $ids.Count } else { $deleted })"
  WriteLog "Failed:   $failed"
  WriteLog "----------------------------------------"
  if ($script:logPath)
  {
    $elapsed = (Get-Date) - $script:runStarted
    WriteLog "Log: $script:logPath" Cyan
    WriteLogDetail "Finished $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) after $([int]$elapsed.TotalMinutes)m $($elapsed.Seconds)s"
  }
}

# Every Task id in the project, walked with a System.Id watermark so it survives past the 20,000 row
# WIQL cap (the same reason GetMigratedTagMap pages). $top keeps each query small and steady.
function GetAllTaskIds
{
  $org = $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/')
  $project = $script:config.AzureDevOps.Project
  $pageSize = 1000
  $ids = @()
  $lastId = 0

  while ($true)
  {
    $wiql = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$project' AND [System.WorkItemType] = 'Task' AND [System.Id] > $lastId ORDER BY [System.Id]" }
    $url = "{0}/{1}/_apis/wit/wiql?`$top={2}&api-version=7.1" -f $org, [uri]::EscapeDataString($project), $pageSize

    $response = InvokeAdoRequest $url "Post" $wiql "application/json"
    $batch = @($response.workItems | ForEach-Object { $_.id })
    if ($batch.Count -eq 0) { break }

    $ids += $batch
    $lastId = $batch[-1]
    if ($batch.Count -lt $pageSize) { break }
  }

  return $ids
}

# Epics need their hierarchy resolved before anything is written, because the Epic/Feature split
# and the flattening depend on the whole set. Every other type just parents to its Super.
function MigrateEpics($scopes, $existing)
{
  WriteLog "--- Epic ---" Cyan

  $assets = @()
  foreach ($s in $scopes)
  {
    $batch = GetAgilityAssets 'Epic' $s.Scope
    # The area path comes from the scope the Epic was read from, so carry it on the asset.
    foreach ($a in $batch) { $a | Add-Member -NotePropertyName AreaPath -NotePropertyValue $s.AreaPath -Force }
    WriteLog "Read $($batch.Count) Epics from $($s.Scope)"
    $assets += $batch
  }
  WriteLog "Read $($assets.Count) Epics from Agility in total"

  $epics = ResolveEpicHierarchy $assets $script:mappings
  foreach ($epic in $epics) { $script:numberByOid[$epic.Oid] = $epic.Number }
  WriteLog

  # Epics before Features, so a Feature always has its parent id available when it is created.
  foreach ($epic in ($epics | Sort-Object { $_.Depth }))
  {
    MigrateItem $epic $existing
  }
  WriteLog
}

# Story, Defect, Issue. No hierarchy to resolve: each one parents to the Epic in its Super, which
# is already in ADO, so a single pass in any order works.
function MigrateWorkitems([string]$agilityType, $scopes, $existing)
{
  WriteLog "--- $agilityType ---" Cyan

  $items = @()
  foreach ($s in $scopes)
  {
    $batch = GetAgilityAssets $agilityType $s.Scope
    foreach ($a in $batch)
    {
      $a | Add-Member -NotePropertyName AreaPath -NotePropertyValue (ResolveAreaPath $s.AreaPath $a.Theme) -Force
      $a | Add-Member -NotePropertyName AdoType -NotePropertyValue $script:mappings.WorkItemTypes.$agilityType -Force
      # Only Epics are ever flattened, and only Epics carry a true parent worth recording.
      $a | Add-Member -NotePropertyName ParentOid -NotePropertyValue $a.SuperOid -Force
      $a | Add-Member -NotePropertyName TrueParentOid -NotePropertyValue $null -Force
      $a | Add-Member -NotePropertyName Flattened -NotePropertyValue $false -Force
    }
    WriteLog "Read $($batch.Count) $($agilityType)s from $($s.Scope)"
    $items += $batch
  }
  WriteLog "Read $($items.Count) $($agilityType)s from Agility in total"
  WriteLog

  # Bridge the parent oid to the parent's Number before migrating anything.
  #
  # ResolveMigratedId turns a parent oid into the agility:<Number> tag that finds it in ADO, and it
  # can only do that through numberByOid. That map is filled from the items read in this run, so an
  # Epic migrated by an EARLIER run is not in it: the lookup misses and the Story is created with no
  # parent, silently. That is the normal case here, since the Epics are already migrated.
  #
  # Super.Number gives us the Epic's Number from the Story itself, so the link resolves without
  # loading the Epics at all. 4,526 of 7,568 Stories and 323 of 704 Defects have a Super.
  foreach ($item in $items)
  {
    $script:numberByOid[$item.Oid] = $item.Number
    if ($item.SuperOid -and $item.ParentNumber) { $script:numberByOid[$item.SuperOid] = $item.ParentNumber }
  }

  foreach ($item in $items)
  {
    MigrateItem $item $existing
  }
  WriteLog
}

##################################################################################################
# Logging
#
# Console and log are written by the same function, so they cannot drift apart: if a line reached
# the operator it is in the file, and vice versa. The log is a faithful copy rather than a
# reformatted one, deliberately - no per line timestamp prefix, because the summary greps in the
# README anchor on the item text ("^\s*FAIL", "WOULD\s+Bug") and a prefix would break every one of
# them. Timing lives in the header and footer instead.
##################################################################################################

# One log per Migrate call, named for the moment it started. Never throws: a run that cannot open
# its log is still a run worth making, so this warns and carries on with the console only.
function StartLog
{
  StopLog

  try
  {
    if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Path $script:logDir -Force | Out-Null }

    $script:logPath = Join-Path $script:logDir ("Migrate-Agility-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

    # AutoFlush so a crash, a throttling timeout, or a Ctrl-C still leaves a complete log. A log
    # that only survives a clean finish is missing exactly when it is wanted.
    $script:logWriter = [System.IO.StreamWriter]::new($script:logPath, $true)
    $script:logWriter.AutoFlush = $true
  }
  catch
  {
    $script:logPath = $null
    $script:logWriter = $null
    Write-Host "WARN    no log file could be opened in $script:logDir, continuing with console only: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

function StopLog
{
  if ($script:logWriter)
  {
    try { $script:logWriter.Dispose() } catch { }
  }

  $script:logWriter = $null
}

# The one call the whole script uses for progress. Mirrors the Write-Host it replaced, so a bare
# WriteLog is still a blank spacer line.
function WriteLog([string]$message = "", [string]$color)
{
  if ($color) { Write-Host $message -ForegroundColor $color }
  else { Write-Host $message }

  AppendLog $message
}

# File only. For detail that belongs in the record but would drown a console printing 8,000 items.
function WriteLogDetail([string]$message)
{
  AppendLog $message
}

function AppendLog([string]$message)
{
  if (-not $script:logWriter) { return }

  # A logging fault must never take down a migration that is otherwise succeeding. Drop the writer
  # and say so once, rather than throwing on every subsequent line.
  try { $script:logWriter.WriteLine($message) }
  catch
  {
    $script:logWriter = $null
    Write-Host "WARN    logging to $script:logPath stopped: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

# The console gets one readable line per failure; the log gets what is actually needed to diagnose
# it once the run is over and the error record is gone. ReadAdoError deliberately returns only the
# human message, so without this the HTTP status, the raw body, and the stack are lost.
function WriteErrorDetail($errorRecord, [string]$context)
{
  if (-not $script:logWriter) { return }

  WriteLogDetail "          ---- error detail: $context ----"
  WriteLogDetail "          Exception: $($errorRecord.Exception.GetType().FullName)"
  WriteLogDetail "          Message:   $($errorRecord.Exception.Message)"

  $status = $errorRecord.Exception.Response.StatusCode.value__
  if ($status) { WriteLogDetail "          HTTP:      $status" }

  # The ADO error blob, unparsed. ReadAdoError pulls one field out of this; the rest often names
  # the offending field and rule, which is the part worth keeping.
  if ($errorRecord.ErrorDetails.Message) { WriteLogDetail "          Body:      $($errorRecord.ErrorDetails.Message)" }

  if ($errorRecord.ScriptStackTrace)
  {
    WriteLogDetail "          Stack:"
    foreach ($line in ($errorRecord.ScriptStackTrace -split "`r?`n")) { WriteLogDetail "            $line" }
  }

  WriteLogDetail "          ---- end error detail ----"
}

##################################################################################################
# Configuration and secrets
##################################################################################################

function GetConfig([string]$path)
{
  if (-not (Test-Path $path))
  {
    throw "Config file not found: $path. Copy appsettings.sample.json to appsettings.json and fill it in."
  }

  return Get-Content $path -Raw | ConvertFrom-Json
}

# Resolves a secret from the environment first, then Windows Credential Manager. The environment
# wins so a pipeline can inject the token without a credential store being present.
#
# This is the one function with a param block rather than inline params, because a suppression
# attribute has to attach to one. The analyzer sees "credential" in the parameter name and assumes
# it holds a secret. It does not: it is the NAME of a credential in Windows Credential Manager,
# such as "ADO-YourOrg-PAT". The secret itself never lands in a parameter, it comes back
# from Get-StoredCredential as a SecureString below.
function GetSecret
{
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'credentialTarget',
    Justification = 'credentialTarget names a stored credential, it is not the secret.')]
  param
  (
    [string]$envVar,
    [string]$credentialTarget
  )

  $fromEnv = [Environment]::GetEnvironmentVariable($envVar)
  if ($fromEnv) { return $fromEnv.Trim() }

  # Import explicitly. Get-Command does not autoload CredentialManager, so testing for the command
  # first reports the module as missing even when it is installed.
  if (-not (Get-Module CredentialManager))
  {
    try { Import-Module CredentialManager -ErrorAction Stop }
    catch
    {
      throw "$envVar is not set and the CredentialManager module could not be loaded. Either set the $envVar environment variable, or run: Install-Module CredentialManager -Scope CurrentUser"
    }
  }

  $credential = Get-StoredCredential -Target $credentialTarget
  if (-not $credential)
  {
    throw "$envVar is not set and no stored credential was found for target '$credentialTarget'."
  }

  return ([System.Net.NetworkCredential]::new("", $credential.Password).Password).Trim()
}

function BuildAgilityHeaders
{
  $token = GetSecret "AGILITY_ACCESS_TOKEN" $script:config.Agility.CredentialTarget

  return @{
    Authorization = "Bearer $token"
    Accept        = "application/json"
  }
}

function BuildAdoHeaders
{
  $pat = GetSecret "ADO_PAT" $script:config.AzureDevOps.CredentialTarget
  $basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":" + $pat))

  return @{ Authorization = "Basic $basicAuth" }
}

# A SEPARATE, higher privilege token for MaterializeOwners only: adding users to the org needs the
# Member Entitlement Management (write) scope and a Project Collection Administrator owner, neither of
# which the work-item PAT has (it 401s on the entitlement API). Resolved from ADO_ADMIN_PAT or the
# optional AdminCredentialTarget in appsettings.json; falls back to the regular ADO PAT, which will
# 401 clearly if it is under scoped rather than doing anything unexpected.
function BuildAdoAdminHeaders
{
  $target = if ($script:config.AzureDevOps.PSObject.Properties['AdminCredentialTarget'] -and $script:config.AzureDevOps.AdminCredentialTarget) `
              { $script:config.AzureDevOps.AdminCredentialTarget }
            else { $script:config.AzureDevOps.CredentialTarget }

  $pat = GetSecret "ADO_ADMIN_PAT" $target
  $basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":" + $pat))

  return @{ Authorization = "Basic $basicAuth" }
}

##################################################################################################
# Agility - read only
##################################################################################################

# The single door to Agility. -Method Get is hard coded here on purpose. Do not add a method
# parameter to this function, and do not call Invoke-RestMethod against Agility anywhere else.
function InvokeAgilityGet([string]$url)
{
  return InvokeWithRetry {
    Invoke-RestMethod -Uri $url -Method Get -Headers $script:agilityHeaders -ErrorAction Stop
  }
}

# Attributes are per asset type, and asking for one a type does not have is an HTTP 400 "Unknown
# token" that fails the whole page rather than one field. So each type gets its own selection.
#
# Epic has no Estimate: Swag is its estimate. Issue has Owner (singular), not Owners, and has no
# Estimate, Priority, Timebox, or Super at all.
function GetSelection([string]$agilityType)
{
  # CreatedBy.Name/Email is on every asset type (a BaseAsset attribute) and becomes the assignee when
  # an item has no owner, so it rides in the common list rather than each type's. CreateDate,
  # ChangeDateUTC and ChangedBy feed the two-point revision history, also on every type.
  $common = "Name,Number,Description,Scope,AssetState,Team.Name,Order,CreatedBy.Name,CreatedBy.Email," +
            "CreateDate,ChangeDateUTC,ChangedBy.Name,ChangedBy.Email"

  switch ($agilityType)
  {
    'Epic'
    {
      # Value is the Agility business value and Swag is the Epic estimate. Both are real, and both
      # are nearly empty: Value on 2 of 858, Swag on 10. They are selected anyway because the cost
      # is a token and the alternative is losing the few that exist.
      return "$common,Swag,Value,Status.Name,Priority.Name,Super,Owners.Name,Owners.Email," +
             "PlannedStart,PlannedEnd,ClosedDate,Category.Name,Custom_FiscalYear.Name,Custom_Mandate.Name,StrategicThemes.Name"
    }
    'Story'
    {
      # Super.Number, not just Super: the Epic is usually not loaded in the same run, so its oid
      # alone cannot be turned into the agility:<Number> tag that finds it in ADO.
      return "$common,Estimate,Status.Name,Priority.Name,Super,Super.Number,Owners.Name,Owners.Email," +
             "Parent.Name,Timebox.Name,ClosedDate,Category.Name"
    }
    'Defect'
    {
      # No Category here: Defect has no such attribute, and asking for it is a 400 that fails the
      # whole read. Its nearest equivalents, Type and DeliveryCategory, are empty on all 704
      # Defects, so there is nothing to map. Source is the one that carries data (23 of 704).
      return "$common,Estimate,Status.Name,Priority.Name,Super,Super.Number,Owners.Name,Owners.Email," +
             "Parent.Name,Timebox.Name,ClosedDate,Resolution,ResolutionReason.Name,Environment,FoundInBuild,Source.Name"
    }
    'Issue'
    {
      # Issue is a BaseAsset, not a Workitem: no Super, no Estimate, no Timebox, and Owner is
      # singular. It does have a Priority attribute, but it is empty on all 388, so it is left out
      # for lack of data rather than lack of a field.
      #
      # BlockedPrimaryWorkitems and BlockedEpics are the Stories, Defects and Epics this Issue
      # blocks, and .Number is what turns them into agility:<Number> tag lookups. Issues migrate
      # last, so everything they point at is already in ADO.
      return "$common,Owner.Name,Owner.Email,Category.Name,TargetDate,ClosedDate," +
             "Resolution,ResolutionReason.Name,BlockedPrimaryWorkitems.Number,BlockedEpics.Number"
    }
    'Task'
    {
      # Task has NO Priority: selecting it is a 400 that kills the whole page.
      #
      # Parent is the Story or Defect this Task belongs to, NOT the Theme it is for Story and
      # Defect. Parent.Number is what links it. Task.Super exists but is read only and unused here.
      #
      # Team and Timebox are read only on Task (inherited from the parent Story), but they still
      # select and still carry data, so the tags and the iteration path work the same way.
      return "$common,Estimate,DetailEstimate,ToDo,Status.Name,Owners.Name,Owners.Email," +
             "Parent,Parent.Number,Parent.Name,Parent.Parent.Name,Timebox.Name,ClosedDate,Category.Name"
    }
  }

  throw "No selection defined for Agility type '$agilityType'."
}

function GetAgilityAssets([string]$agilityType, [string]$agilityScope)
{
  $selection = GetSelection $agilityType

  # Agility AssetState: 64 Active, 128 Closed, 200 Dead. The Dead epics in the scopes are
  # placeholder templates ("IT - Registration Checklist - <insert semester>"), so they are excluded
  # either way. Dropping the filter entirely would migrate them, which is why -IncludeClosed still
  # filters rather than passing no where clause at all.
  $where = "Scope='$agilityScope'"
  $where += if ($script:IncludeClosed) { ";AssetState!='Dead'" } else { ";AssetState!='Closed'" }

  $pageSize = 50
  $start = 0
  $all = @()

  while ($true)
  {
    $url = "{0}/rest-1.v1/Data/{1}?sel={2}&where={3}&page={4},{5}" -f `
      $script:config.Agility.BaseUrl.TrimEnd('/'),
      $agilityType,
      [uri]::EscapeDataString($selection),
      [uri]::EscapeDataString($where),
      $pageSize,
      $start

    $response = InvokeAgilityGet $url
    $batch = ConvertFromAgilityAssets $response $agilityType

    if ($batch.Count -eq 0) { break }

    $all += $batch
    if ($batch.Count -lt $pageSize) { break }

    $start += $pageSize
  }

  return $all
}

# Parses the rest-1.v1 JSON shape into flat objects. This is the ONLY place that knows the wire
# format, so if the real instance differs this is the only function to correct. The documented
# shape is an Assets array, each with an id and an Attributes dictionary keyed by attribute name,
# each attribute holding a value.
function ConvertFromAgilityAssets($response, [string]$agilityType = 'Epic')
{
  $results = @()
  if (-not $response -or -not $response.Assets) { return $results }

  foreach ($asset in $response.Assets)
  {
    $attributes = $asset.Attributes

    # Epic keeps its estimate in Swag; Story and Defect use Estimate; Task uses ToDo, which is the
    # remaining hours and lands in ADO's Remaining Work; Issue has none of them. Asking for an
    # attribute the type does not have is a 400, so the selection differs and so does this.
    $estimate = switch ($agilityType)
                {
                  'Epic'  { GetAttributeValue $attributes "Swag" }
                  'Task'  { GetAttributeValue $attributes "ToDo" }
                  'Issue' { $null }
                  default { GetAttributeValue $attributes "Estimate" }
                }

    # The parent axis is per type, and getting it wrong is silent rather than loud.
    #
    # Story and Defect have two: Super is the Epic (which becomes the ADO parent link) and Parent
    # is the Theme (which becomes the area path). Task reuses the SAME attribute name for a
    # different thing: Task.Parent is the Story or Defect it belongs to, and Task has no Theme at
    # all. Reading Parent.Name into Theme for a Task would push a Story's name through the area
    # path lookup and drop the real parent on the floor, with no error either time.
    $isTask = ($agilityType -eq 'Task')

    $superOid     = if ($isTask) { GetRelationOid $attributes "Parent" }
                    else        { GetRelationOid $attributes "Super" }

    $parentNumber = if ($isTask) { GetAttributeValue $attributes "Parent.Number" }
                    else        { GetAttributeValue $attributes "Super.Number" }

    # A Task's theme is one hop further up: Task.Parent is the Story/Defect, whose Parent is the
    # Theme. Parent.Parent.Name lands the Task in the same area leaf as the Story it belongs to.
    $theme        = if ($isTask) { GetAttributeValue $attributes "Parent.Parent.Name" }
                    else        { GetAttributeValue $attributes "Parent.Name" }

    # The work items this Issue blocks. Stories and Defects arrive in one attribute and Epics in
    # another, but they are the same relationship and become the same link, so they merge here.
    # Both are multi value: one Issue blocks up to 12 items.
    $blocked = @()
    $blocked += @(GetAttributeValues $attributes "BlockedPrimaryWorkitems.Number")
    $blocked += @(GetAttributeValues $attributes "BlockedEpics.Number")
    $blockedNumbers = @($blocked | Where-Object { $_ })

    # Issue has Owner (singular), every other type has Owners (multi value).
    #
    # Aligned, not filtered: these two lists are read off one relation and index i must mean the
    # same owner in both. See GetAttributeValuesAligned for what stripping the nulls costs.
    #
    # The outer @() is load bearing. An if used as an expression emits its result to the output
    # stream, which unrolls a one element array back to a scalar, so a single owner would arrive as
    # a bare string and OwnerEmails[0] would be its first character, not the address. That reads as
    # an unknown identity, and every single owner item would migrate unassigned.
    $ownerNames  = @(if ($agilityType -eq 'Issue') { GetAttributeValuesAligned $attributes "Owner.Name" }
                     else { GetAttributeValuesAligned $attributes "Owners.Name" })
    $ownerEmails = @(if ($agilityType -eq 'Issue') { GetAttributeValuesAligned $attributes "Owner.Email" }
                     else { GetAttributeValuesAligned $attributes "Owners.Email" })

    $results += [pscustomobject]@{
      AgilityType = $agilityType
      Oid         = NormalizeOid $asset.id
      Number      = GetAttributeValue $attributes "Number"
      Name        = GetAttributeValue $attributes "Name"
      Description = GetAttributeValue $attributes "Description"
      Estimate    = $estimate
      Status      = GetAttributeValue $attributes "Status.Name"
      Priority    = GetAttributeValue $attributes "Priority.Name"
      SuperOid    = NormalizeOid $superOid

      # The parent's own Number, read straight off this item: the Epic for a Story or Defect, the
      # Story or Defect for a Task. Epics do not select it (their whole set is resolved together by
      # oid), so it is null there.
      ParentNumber = $parentNumber

      # Issue only: the Agility numbers of the work items this Issue blocks.
      BlockedNumbers = $blockedNumbers

      AssetState  = GetAttributeValue $attributes "AssetState"

      # Owners is multi value and ADO's AssignedTo holds one person, so keep the whole list. The
      # first becomes the assignee and the rest become tags, so no owner is silently dropped.
      OwnerNames   = $ownerNames
      OwnerEmails  = $ownerEmails

      PlannedStart = GetAttributeValue $attributes "PlannedStart"
      PlannedEnd   = GetAttributeValue $attributes "PlannedEnd"
      TargetDate   = GetAttributeValue $attributes "TargetDate"
      ClosedDate   = GetAttributeValue $attributes "ClosedDate"
      Order        = GetAttributeValue $attributes "Order"

      # Story.Parent and Defect.Parent are the Agility Theme, which supplies the area path leaf.
      # Resolved above, because Task.Parent is a work item and must not land here.
      # Epic.StrategicThemes is a different thing entirely and only ever becomes a tag.
      Theme          = $theme
      # StrategicThemes is multi value (an Epic can carry several); keep the whole list for the
      # DevLabs multi-value field. StrategicTheme (singular, first only) is retained for any caller
      # that still wants a scalar.
      StrategicTheme  = GetAttributeValue  $attributes "StrategicThemes.Name"
      StrategicThemes = GetAttributeValues $attributes "StrategicThemes.Name"

      # Agility's business value. Epic only: Story.Value and Defect have it in the schema but it is
      # empty on every one of them, so only Epic's sel= list asks.
      BusinessValue = GetAttributeValue $attributes "Value"

      Timebox      = GetAttributeValue $attributes "Timebox.Name"

      # Defect and Issue both have one. Only the type's sel= list decides whether it arrives.
      Resolution       = GetAttributeValue $attributes "Resolution"
      ResolutionReason = GetAttributeValue $attributes "ResolutionReason.Name"

      Environment  = GetAttributeValue $attributes "Environment"
      FoundInBuild = GetAttributeValue $attributes "FoundInBuild"

      # Category on Epic, Story, and Issue. Defect has no Category and reports Source instead, so
      # both are read here and whichever the type does not have simply stays null.
      Category     = GetAttributeValue $attributes "Category.Name"
      Source       = GetAttributeValue $attributes "Source.Name"
      Team         = GetAttributeValue $attributes "Team.Name"
      FiscalYear   = GetAttributeValue $attributes "Custom_FiscalYear.Name"
      Mandate      = GetAttributeValue $attributes "Custom_Mandate.Name"

      # The Agility creator, used as the assignee when the item has no owner. Often current staff and
      # therefore assignable where a departed owner would not be. See ResolveAssignee.
      CreatedByName  = GetAttributeValue $attributes "CreatedBy.Name"
      CreatedByEmail = GetAttributeValue $attributes "CreatedBy.Email"

      # The two-point revision history: creation (CreatedBy above + CreateDate) and last modification
      # (ChangedBy + ChangeDateUTC). This instance's hist-1.v1 endpoint is 404, so these two moments
      # are the only history it exposes. ChangeDateUTC is already UTC; FormatDate handles it.
      CreateDate     = GetAttributeValue $attributes "CreateDate"
      ChangedByName  = GetAttributeValue $attributes "ChangedBy.Name"
      ChangedByEmail = GetAttributeValue $attributes "ChangedBy.Email"
      ChangeDate     = GetAttributeValue $attributes "ChangeDateUTC"
    }
  }

  return $results
}

# Attribute values arrive as { "name": "...", "value": ... }. Multi value attributes hold an
# array. Empty relations hold $null.
function GetAttributeValue($attributes, [string]$name)
{
  if (-not $attributes) { return $null }

  $attribute = $attributes.PSObject.Properties[$name]
  if (-not $attribute) { return $null }

  $value = $attribute.Value.value
  if ($null -eq $value) { return $null }

  if ($value -is [array])
  {
    if ($value.Count -eq 0) { return $null }
    $value = $value[0]
  }

  # A relation value is an object carrying idref rather than a scalar.
  if ($value -is [psobject] -and $value.PSObject.Properties['idref'])
  {
    return $value.idref
  }

  return $value
}

function GetRelationOid($attributes, [string]$name)
{
  return GetAttributeValue $attributes $name
}

# Same as GetAttributeValue but keeps every entry of a multi value attribute rather than the first.
# Owners needs this: 10 of the epics have more than one owner.
function GetAttributeValues($attributes, [string]$name)
{
  if (-not $attributes) { return @() }

  $attribute = $attributes.PSObject.Properties[$name]
  if (-not $attribute) { return @() }

  $value = $attribute.Value.value
  if ($null -eq $value) { return @() }

  return @($value | Where-Object { $_ })
}

# The same list with the empty slots KEPT, so index i means the same thing in two lists read off the
# same relation.
#
# Agility null pads: Owners.Name ["Jordan Blake","Jamie Nolan","Vendor"] comes back beside
# Owners.Email ["jordan.blake@example.com","jamie.nolan@example.com",null], because Vendor has no email.
# GetAttributeValues drops that null, which is right for a tag list and wrong here: it shortens the
# email list and slides every later owner up a slot. 1,338 items have an owner with no email. On any
# of them whose FIRST owner is the one missing it, the item is assigned to the SECOND owner's email
# while BuildTags skips the FIRST owner's name, so the assignee gets an owner tag as well and the
# real first owner is dropped with no record at all. That is the "no owner is silently dropped" rule
# again, and stripping nulls is what breaks it.
#
# Read Owners.Name and Owners.Email through THIS, never GetAttributeValues.
function GetAttributeValuesAligned($attributes, [string]$name)
{
  if (-not $attributes) { return @() }

  $attribute = $attributes.PSObject.Properties[$name]
  if (-not $attribute) { return @() }

  $value = $attribute.Value.value
  if ($null -eq $value) { return @() }

  # @() around a lone scalar, and no Where-Object: the empty slots are the point.
  return @($value)
}

# Agility oids can carry a moment suffix, as in Epic:1234:5678. Strip it so the same asset read at
# different moments compares equal.
function NormalizeOid($oid)
{
  if (-not $oid) { return $null }

  $parts = ([string]$oid).Split(':')
  if ($parts.Count -ge 2) { return "{0}:{1}" -f $parts[0], $parts[1] }

  return [string]$oid
}

##################################################################################################
# Hierarchy
##################################################################################################

# Assigns an ADO work item type and parent to each Agility Epic.
#
# ADO accepts an Epic parented to an Epic and then silently breaks the backlog: ordering is
# disabled and intermediate items vanish from sprint backlogs. So this is resolved here, before
# anything is written, rather than relying on ADO to reject it.
#
#   depth 1 (no Epic parent) -> Epic, no parent
#   depth 2                  -> Feature, parented to the root Epic
#   depth 3 or deeper        -> Feature, flattened onto the root Epic, with a warning
#
# Every Epic below the root becomes a Feature under the root, so no Epic-Epic or Feature-Feature
# link is ever created.
#
# Flattening at depth 3 or deeper discards the real parent, so TrueParentOid carries it. The
# caller records it as a Related link and a description note, which keeps the original structure
# recoverable from ADO instead of losing it.
function ResolveEpicHierarchy($assets, $mappings)
{
  $byOid = @{}
  foreach ($asset in $assets) { $byOid[$asset.Oid] = $asset }

  $results = @()

  foreach ($asset in $assets)
  {
    $depth = 1
    $root = $asset
    $cursor = $asset
    $guard = 0

    # Walk up to the topmost Epic that is inside this scope.
    while ($cursor.SuperOid -and $byOid.ContainsKey($cursor.SuperOid))
    {
      $cursor = $byOid[$cursor.SuperOid]
      $root = $cursor
      $depth++

      $guard++
      if ($guard -gt 100) { throw "Cycle detected in Agility Epic hierarchy at $($asset.Number)." }
    }

    if ($depth -eq 1)
    {
      $type = $mappings.WorkItemTypes.Epic
      $parentOid = $null
    }
    else
    {
      $type = $mappings.WorkItemTypes.NestedEpic
      $parentOid = $root.Oid
    }

    # Copy the asset and overlay what the hierarchy decided, so every Agility field parsed above
    # survives without being listed again here.
    $resolved = $asset.PSObject.Copy()
    $resolved | Add-Member -NotePropertyName AdoType       -NotePropertyValue $type            -Force
    $resolved | Add-Member -NotePropertyName ParentOid     -NotePropertyValue $parentOid       -Force
    $resolved | Add-Member -NotePropertyName TrueParentOid -NotePropertyValue $asset.SuperOid  -Force
    $resolved | Add-Member -NotePropertyName Depth         -NotePropertyValue $depth           -Force
    $resolved | Add-Member -NotePropertyName Flattened     -NotePropertyValue ($depth -ge 3)   -Force

    $results += $resolved
  }

  return $results
}

##################################################################################################
# Azure DevOps
##################################################################################################

function InvokeAdoRequest([string]$url, [string]$method, $body, [string]$contentType)
{
  return InvokeWithRetry {
    if ($body)
    {
      Invoke-RestMethod -Uri $url -Method $method -Headers $script:adoHeaders `
        -Body ($body | ConvertTo-Json -Depth 10 -AsArray:($body -is [array])) `
        -ContentType $contentType -ErrorAction Stop
    }
    else
    {
      Invoke-RestMethod -Uri $url -Method $method -Headers $script:adoHeaders -ErrorAction Stop
    }
  }
}

# One WIQL query up front for everything in the project, rather than a query per item. A query per
# item would be N round trips and would invite throttling on a real migration.
#
# The obvious query, [System.Tags] CONTAINS 'agility:', silently returns **zero rows**. WIQL
# matches System.Tags a whole tag at a time: CONTAINS 'agility:E-06527' finds that one item, but
# 'agility:' and even 'agility' match nothing, and there is no prefix or wildcard form
# (CONTAINS WORDS 'agility*' also returns nothing, and IS NOT EMPTY is rejected outright for Tags).
#
# It fails as an empty result, not an error, which is the dangerous part: the map came back empty,
# so nothing was ever recognised as already migrated. That silently broke the two things this map
# exists for. Reruns would duplicate every item instead of skipping it, and a Story could never
# find an Epic migrated by an earlier run, so it would be created with no parent.
#
# So the filtering happens on the client. Every work item in the project is read and its tags are
# matched here. That is more rows than the tagged subset, but this is a migration target project,
# and a correct answer beats a cheap wrong one.
#
# The walk is PAGED, and that is not optional either. WIQL caps a flat query at 20,000 rows and
# fails the whole query with VS402337 rather than truncating, so one unfiltered SELECT stops working
# the moment the project passes 20,000 items. It holds 858 today and roughly 9,500 once Stories,
# Defects and Issues land, but Tasks alone would take it past 50,000 - and the failure would land
# on exactly the function whose last silent breakage would have duplicated every work item.
#
# WIQL has no OFFSET and no paging of its own. What it does have is $top on the endpoint, so this
# walks a System.Id watermark: each page asks for ids above the highest one it has seen, ordered,
# capped below the limit. A watermark rather than an offset because it stays correct even if items
# are created while the walk runs. Verified against the live project: with a deliberately small
# page size it returns the same 858 ids as the unpaged query, over 3 pages, no gaps, no repeats.
# Keyed by the bare Agility Number ("E-01234"), not by the tag text. Both of the two things that
# can identify a migrated item resolve to the same key, so callers never care which one matched.
function GetMigratedIdMap([int]$wiqlPageSize = 19000)
{
  $map = @{}
  $lastId = 0

  while ($true)
  {
    $wiql = @{
      query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '{0}' AND [System.Id] > {1} ORDER BY [System.Id]" -f `
        $script:config.AzureDevOps.Project, $lastId
    }

    $url = "{0}/{1}/_apis/wit/wiql?`$top={2}&api-version=7.1" -f `
      $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'),
      [uri]::EscapeDataString($script:config.AzureDevOps.Project),
      $wiqlPageSize

    $response = InvokeAdoRequest $url "Post" $wiql "application/json"
    $ids = @($response.workItems | ForEach-Object { $_.id })
    if ($ids.Count -eq 0) { break }

    AddNumbersForIds $map $ids

    # ORDER BY means the last id is the highest, so it is the next watermark.
    $lastId = $ids[-1]
    if ($ids.Count -lt $wiqlPageSize) { break }
  }

  return $map
}

# Reads a page of ids and folds their Agility Numbers into the map. Work item detail comes back in
# batches of 200 at most, whatever the WIQL page size is, so this is a second level of batching and
# not a duplicate of the one above.
#
# TWO sources, and both are needed:
#
#   Custom.DigitalAIWorkItemID  is where the Number lives now.
#   agility:<Number> tag        is where it lived for the 858 Epics and Features migrated before
#                               the field existed. They cannot be matched any other way.
#
# Dropping the tag read would make those 858 look unmigrated, and a rerun would duplicate every one
# of them silently. That is the same failure this map already caused once. It can go once the 858
# carry the field; until then, both.
function AddNumbersForIds($map, $ids)
{
  $idField = $script:mappings.RequiredFields.AgilityId

  for ($i = 0; $i -lt $ids.Count; $i += 200)
  {
    $batch = $ids[$i..([Math]::Min($i + 199, $ids.Count - 1))]
    $batchUrl = "{0}/_apis/wit/workitems?ids={1}&fields=System.Id,System.Tags,{2}&api-version=7.1" -f `
      $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'),
      ($batch -join ','),
      $idField

    $details = InvokeAdoRequest $batchUrl "Get" $null $null

    foreach ($item in $details.value)
    {
      # The field wins: it is the current source of truth, and an item carrying both must not
      # depend on which one is read last.
      $number = $item.fields.$idField
      if ($number)
      {
        $map[([string]$number).Trim()] = $item.id
        continue
      }

      $tags = $item.fields.'System.Tags'
      if (-not $tags) { continue }

      foreach ($tag in ($tags -split ';'))
      {
        $trimmed = $tag.Trim()
        if ($trimmed -like 'agility:*') { $map[$trimmed.Substring(8)] = $item.id }
      }
    }
  }
}

# The ADO ids for the work items an Issue blocks, and the Agility numbers that had no ADO item to
# point at.
#
# This resolves straight off the Number, with no numberByOid hop, because BlockedPrimaryWorkitems
# and BlockedEpics already carry .Number. Issues migrate last, so every Story, Defect and Epic they
# block is already in the tag map, whether from this run or an earlier one.
#
# Anything unresolved is a blocked item outside the configured scopes, the same situation as an item
# whose parent Epic lives in a scope that is not configured. It keeps its number as a tag rather than
# vanishing.
function ResolveBlockedIds($item, $existing)
{
  $ids = @()
  $pending = @()
  $unresolved = @()

  foreach ($number in @($item.BlockedNumbers))
  {
    if (-not $number) { continue }

    if (-not $existing.ContainsKey($number)) { $unresolved += $number; continue }

    # Pending is a dry run thing only: the item is not in ADO yet, but this same run would create
    # it before reaching here, so the link WOULD be made. Reporting it as a miss would understate
    # the real run.
    if ($existing[$number] -eq $script:DryRunPendingId) { $pending += $number }
    else { $ids += $existing[$number] }
  }

  return [pscustomobject]@{
    Ids        = @($ids | Select-Object -Unique)
    Pending    = @($pending | Select-Object -Unique)
    Unresolved = @($unresolved | Select-Object -Unique)
  }
}

# Maps an Agility oid to the ADO id it was migrated as, or $null if it is not in ADO yet. Both
# the hierarchy parent and the true parent resolve through here.
function ResolveMigratedId($oid, $existing)
{
  if (-not $oid) { return $null }

  $number = $script:numberByOid[$oid]
  if (-not $number) { return $null }

  if ($existing.ContainsKey($number)) { return $existing[$number] }

  return $null
}

function MigrateItem($epic, $existing)
{
  # The map is keyed by the bare Agility Number, whether it came from the custom field or from a
  # legacy agility:<Number> tag.
  $key = $epic.Number

  if ($existing.ContainsKey($key))
  {
    WriteLog "  SKIP    $($epic.Number) $($epic.Name) - already migrated as #$($existing[$key])"
    $script:skipped++
    return
  }

  if ($epic.Flattened)
  {
    WriteLog "  WARN    $($epic.Number) is nested $($epic.Depth) levels deep, flattening onto its root Epic" Yellow
    $script:warnings++
  }

  if ($epic.OwnerNames.Count -gt 1)
  {
    # Report the ACTUAL assignee, not owner zero. Assignment tries each owner and promotes the first
    # ADO accepts, so owner zero is often NOT who gets assigned (a departed first owner is skipped).
    # The others go to the owners field, not tags.
    $assignee = ResolveAssignee $epic
    $ownersField = $script:mappings.CustomFields.Owners.Field
    $action = if ($assignee) { "assigning $assignee" } else { "no owner is an assignable identity, leaving it unassigned" }
    WriteLog "  WARN    $($epic.Number) has $($epic.OwnerNames.Count) owners; $action, recording the rest in $ownersField" Yellow
    $script:warnings++
  }

  $parentId = ResolveMigratedId $epic.ParentOid $existing
  $trueParentId = ResolveMigratedId $epic.TrueParentOid $existing

  # An item can know its Agility parent and still not link to it, when that parent was never
  # migrated: its Epic lives in a scope not listed in appsettings.json, so it is not in ADO. The
  # link is dropped; the number is not.
  $parentNumber = if ($epic.ParentOid) { $script:numberByOid[$epic.ParentOid] } else { $null }
  $parentUnresolved = [bool]($epic.ParentOid -and -not $parentId)
  $epic | Add-Member -NotePropertyName ParentUnresolved -NotePropertyValue $parentUnresolved -Force
  $epic | Add-Member -NotePropertyName ParentNumberForTag -NotePropertyValue $parentNumber -Force

  if ($parentUnresolved)
  {
    WriteLog "  WARN    $($epic.Number) parent $parentNumber is not in Azure DevOps, keeping it as a tag and creating this unparented" Yellow
    $script:warnings++
  }

  # Issue only. Resolved before the dry run branch so both paths report and tag the same thing.
  $blocked = ResolveBlockedIds $epic $existing
  $epic | Add-Member -NotePropertyName BlockedUnresolved -NotePropertyValue $blocked.Unresolved -Force

  if ($blocked.Unresolved.Count -gt 0)
  {
    WriteLog "  WARN    $($epic.Number) blocks $($blocked.Unresolved -join ', '), which are not in Azure DevOps, keeping them as tags" Yellow
    $script:warnings++
  }

  if ($script:DryRun)
  {
    # Report the real link, not just the Agility number.
    #
    # This used to print "parent E-01330" whenever the item had a Super, whether or not that Epic
    # was actually in ADO. It reads as "the hierarchy resolved" and does not mean that: the link
    # comes from ResolveMigratedId, and it is null for an Epic that was never migrated. A dry run
    # that overstates what a real run will do is worse than one that says nothing.
    $parentText = if (-not $epic.ParentOid)                     { "no parent" }
                  elseif ($parentId -eq $script:DryRunPendingId) { "parent $parentNumber -> created earlier in this run" }
                  elseif ($parentId)                             { "parent $parentNumber -> #$parentId" }
                  else                                           { "parent $parentNumber NOT IN ADO, would be unparented" }
    $relatedText = if ($epic.Flattened -and $epic.TrueParentOid) { " related->$($script:numberByOid[$epic.TrueParentOid])" } else { "" }

    # Same rule as the parent text: report the link that would actually be made, not the intent.
    $blocksText = ""
    if ($blocked.Ids.Count -gt 0)        { $blocksText += " affects->#$($blocked.Ids -join ',#')" }
    if ($blocked.Pending.Count -gt 0)    { $blocksText += " affects $($blocked.Pending -join ',') created earlier in this run" }
    if ($blocked.Unresolved.Count -gt 0) { $blocksText += " affects $($blocked.Unresolved -join ',') NOT IN ADO" }

    $titleText = BuildTitle $epic
    if (IsTitleTruncated $epic) { $titleText += " [TITLE TRUNCATED from $($epic.Name.Length) chars, full text kept in description]" }

    $resolved = ResolveAssignee $epic
    $assignee = if ($resolved) { " assignee=$resolved" } else { "" }

    WriteLog "  WOULD   $($epic.AdoType.PadRight(8)) $($epic.Number) $titleText [$parentText$relatedText$blocksText] area=$(FormatAreaPath $epic.AreaPath) state=$(MapState $epic) priority=$(MapPriority $epic.Priority)$assignee"

    # Ask ADO whether it would actually accept these fields. Nothing is persisted.
    $problem = ValidateAdoWorkItem $epic

    # Mirror the fallback in the real path. Without this the dry run reports a failure for an item
    # that a real run would create unassigned, which is worse than saying nothing.
    if ($problem -and $resolved -and (IsIdentityProblem $problem))
    {
      $retry = ValidateAdoWorkItem (AsUnassignable $epic)

      if (-not $retry)
      {
        WriteLog "  WARN    $($epic.Number) owner '$resolved' is not an Azure DevOps identity, would be created unassigned" Yellow
        $script:warnings++
        $existing[$key] = $script:DryRunPendingId
        $script:created++
        return
      }

      $problem = $retry
    }

    if ($problem)
    {
      WriteLog "  INVALID $($epic.Number) would be REJECTED by Azure DevOps: $problem" Red
      WriteErrorDetail $script:lastValidationError "$($epic.AgilityType) $($epic.Number) -> $($epic.AdoType) (validateOnly)"
      $script:failed++
      return
    }

    # Mirrors the real path's $existing[$key] = $id. Without it, an item this run would create is
    # invisible to every later item that links to it, and the dry run reports links a real run
    # would make as misses. An INVALID item deliberately does not get one: a real run would not
    # create it either, so nothing should link to it.
    $existing[$key] = $script:DryRunPendingId
    $script:created++
    return
  }

  try
  {
    # Revision 1: the item, created backdated to its Agility creator and create date (inside
    # NewAdoWorkItem, under bypassRules). No System.AssignedTo here, so there is nothing for an
    # identity to reject: the create no longer needs the old unassigned retry.
    $id = NewAdoWorkItem $epic $parentId $trueParentId $blocked.Ids
    $existing[$key] = $id

    # Revision 2: the state transition, backdated and attributed to the last changer. Only when the
    # mapped state differs from the create-time default, so an item that never left its default state
    # gets no empty second revision.
    $adoState = MapState $epic
    if ($adoState -ne (GetStateMap $epic).DefaultState)
    {
      SetAdoState $id $adoState $epic
    }

    # Revision 3: the assignee, rule checked so a departed identity is rejected here rather than
    # stored. On rejection the item stays unassigned, and the owner we could not assign is written
    # back into the owners field (the create had excluded it as the would-be assignee).
    try
    {
      SetAdoAssignee $id $epic
    }
    catch
    {
      if (IsIdentityProblem (ReadAdoError $_))
      {
        $resolved = ResolveAssignee $epic
        WriteLog "  WARN    $($epic.Number) owner '$resolved' is not an Azure DevOps identity, leaving it unassigned" Yellow
        $script:warnings++
        SetOwnersField $id (BuildOwnersField (AsUnassignable $epic))
      }
      else { throw }
    }

    # The Closed Date is written inside SetAdoState (the closing transition), not here: it must be set
    # BEFORE the rule-checked assignee patch above, or that patch rejects a closed item with an empty
    # Closed Date. bypassRules never auto-stamps a fake date, so there is nothing left to correct.

    WriteLog "  CREATE  $($epic.AdoType.PadRight(8)) $($epic.Number) $($epic.Name) -> #$id" Green
    $script:created++
  }
  catch
  {
    WriteLog "  FAIL    $($epic.Number) $($epic.Name) - $(ReadAdoError $_)" Red
    WriteErrorDetail $_ "$($epic.AgilityType) $($epic.Number) -> $($epic.AdoType)"
    $script:failed++
  }
}

# Asks ADO to validate the payload without persisting it, via validateOnly=true. This is what
# makes a dry run mean something: without it a dry run only proves we can read Agility, and the
# first real create is the first time ADO ever sees a field value.
#
# This validates the create only, which is what a dry run can honestly check. Three things a real
# run does are therefore not covered here:
#   - relations, because a dry run has no real parent id to point at
#   - the state transition, which needs a real work item to transition
#   - the close date, which needs a real transitioned work item to correct
# The states themselves are checked once per run by AssertStatesExist, which is where a bad
# mappings.json entry surfaces.
function ValidateAdoWorkItem($epic)
{
  $patch = BuildFieldPatch $epic

  # The real create omits System.AssignedTo (it is a separate rule-checked patch, because the create
  # itself is now bypassRules). Add it back HERE, on the rule-checked validateOnly, so the dry run
  # still catches an identity ADO would reject and its AsUnassignable retry still means something.
  $assigneeOp = BuildAssigneeOp $epic
  if ($assigneeOp) { $patch += $assigneeOp }

  $url = "{0}/{1}/_apis/wit/workitems/`${2}?validateOnly=true&api-version=7.1" -f `
    $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'),
    [uri]::EscapeDataString($script:config.AzureDevOps.Project),
    [uri]::EscapeDataString($epic.AdoType)

  try
  {
    InvokeAdoRequest $url "Post" $patch "application/json-patch+json" | Out-Null
    $script:lastValidationError = $null
    return $null
  }
  catch
  {
    # Keep the whole record, not just the message. Most rejections here are the expected unknown
    # identity, which the caller retries and must not log a stack trace for; only the ones that
    # survive the retry are worth the detail, and by then the record is out of scope.
    $script:lastValidationError = $_
    return (ReadAdoError $_)
  }
}

# ADO errors arrive as a JSON blob. Pull the message out, because the raw blob buries the one
# useful line in twelve lines of type names and event ids.
function ReadAdoError($errorRecord)
{
  $raw = $errorRecord.ErrorDetails.Message
  if (-not $raw) { return $errorRecord.Exception.Message }

  try
  {
    $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($parsed.message) { return $parsed.message }
  }
  catch { }

  return $raw
}

# ADO reports an unusable assignee as an "unknown identity" on System.AssignedTo. Many of the
# Agility owners are not identities in the ADO organization.
function IsIdentityProblem([string]$message)
{
  return ($message -match 'unknown identity' -or $message -match 'AssignedTo' -or $message -match 'Assigned To')
}

# Is this identity one ADO will actually accept for System.AssignedTo? Cached per run, because there
# are only ~104 distinct owners across the whole migration, so each person is probed at most once.
#
# ProbeAssignability gates the network call: OFF by default (and in unit tests), so resolution just
# returns the first candidate without touching ADO; Migrate turns it ON. A verdict already in the
# cache is used either way, so a test can seed a rejection with no network. A non-identity error does
# NOT mark the identity unassignable - only a genuine identity rejection does.
#
# This is what lets the migration try each owner and PROMOTE an assignable one instead of giving up
# after a departed first owner. A truly departed / non-member identity still cannot be assigned by
# the work item API (casey.ford@example.com, jordan.blake@example.com are rejected by email AND name);
# the UI can only "assign" them by adding them to the org, which needs a seat, not an API call.
function IsAssignableIdentity([string]$who)
{
  if (-not $who) { return $false }
  if ($null -eq $script:assignableCache) { $script:assignableCache = @{} }
  if ($script:assignableCache.ContainsKey($who)) { return $script:assignableCache[$who] }
  if (-not $script:ProbeAssignability) { return $true }

  $patch = @(
    @{ op = "add"; path = "/fields/System.Title";      value = "identity probe" }
    @{ op = "add"; path = "/fields/System.AssignedTo"; value = $who }
  )
  # Always probe as $Epic: assignability is a property of the identity, not the work item type, so
  # one probe per person serves every type and maximises cache hits.
  $url = "{0}/{1}/_apis/wit/workitems/`$Epic?validateOnly=true&api-version=7.1" -f `
    $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'),
    [uri]::EscapeDataString($script:config.AzureDevOps.Project)

  $ok = $true
  try { InvokeAdoRequest $url "Post" $patch "application/json-patch+json" | Out-Null }
  catch { if (IsIdentityProblem (ReadAdoError $_)) { $ok = $false } }

  $script:assignableCache[$who] = $ok
  return $ok
}

# The ordered assignee candidates for an item: every owner's EMAIL first (in owner order, most likely
# to be a real ADO identity), then every owner's NAME as a fallback, then the Agility creator. Each
# candidate carries the owner index it came from (-1 for the creator, who owns no slot), so whoever is
# chosen can be excluded from the owners field. Pure - no network. Empty when Unassignable.
#
# Emails before names preserves the old "prefer the owner with an email" behaviour: on 283 items a
# non-person (Vendor, ITUS Student Worker) with no email sits ahead of a real identity, and its
# name-only candidate now sorts AFTER every email, so the real identity still wins.
function ResolveAssigneeCandidates($item)
{
  if ($item.PSObject.Properties['Unassignable'] -and $item.Unassignable) { return @() }

  $candidates = @()
  $emails = @($item.OwnerEmails)
  $names  = @($item.OwnerNames)

  for ($i = 0; $i -lt $emails.Count; $i++) { if ($emails[$i]) { $candidates += [pscustomobject]@{ Index = $i; Identity = $emails[$i] } } }
  for ($i = 0; $i -lt $names.Count;  $i++) { if ($names[$i])  { $candidates += [pscustomobject]@{ Index = $i; Identity = $names[$i] } } }

  if ($item.PSObject.Properties['CreatedByEmail'] -and $item.CreatedByEmail) { $candidates += [pscustomobject]@{ Index = -1; Identity = $item.CreatedByEmail } }
  if ($item.PSObject.Properties['CreatedByName']  -and $item.CreatedByName)  { $candidates += [pscustomobject]@{ Index = -1; Identity = $item.CreatedByName } }

  return $candidates
}

# The first candidate ADO will actually accept, or $null. This is where "try each owner, promote an
# assignable one" happens: a departed first owner is skipped for the next assignable owner, and only
# when none is assignable does the item go unassigned.
function ResolveAssignedCandidate($item)
{
  foreach ($c in @(ResolveAssigneeCandidates $item))
  {
    if (IsAssignableIdentity $c.Identity) { return $c }
  }
  return $null
}

# WHICH owner becomes the assignee, as an index into the aligned owner lists, or -1 for nobody (or for
# the creator, who is not an owner). The owners field excludes this index, so the assignee is not
# listed among the "other" owners.
function ResolveAssigneeIndex($item)
{
  $c = ResolveAssignedCandidate $item
  if ($c) { return $c.Index }
  return -1
}

# The assignee ADO will be asked to accept, or null for nobody. Already known assignable (unless
# ProbeAssignability is off), so the assignment patch does not expect a rejection.
function ResolveAssignee($item)
{
  $c = ResolveAssignedCandidate $item
  if ($c) { return $c.Identity }
  return $null
}

# The item as it would be created with nobody assigned, for the identity retry. The owners stay on
# it so BuildAgilityDetails and the owners field can record every one of them.
function AsUnassignable($item)
{
  $copy = $item.PSObject.Copy()
  $copy | Add-Member -NotePropertyName Unassignable -NotePropertyValue $true -Force
  return $copy
}

# The owners that are NOT the assignee, comma separated, for Custom.DigitalAIOwners. The assignee
# (System.AssignedTo) is skipped by the same index BuildFieldPatch assigns on, so the two never
# disagree. When nobody was assignable (index -1) every owner is listed, because none of them is the
# assignee: this is the ~23,000 item case and the only record of who owned those items. Names, not
# emails, because a person reads this field. Returns "" when there is no owner left to list.
function BuildOwnersField($item)
{
  $assigneeIndex = ResolveAssigneeIndex $item
  $names = @($item.OwnerNames)
  $extras = @()
  for ($i = 0; $i -lt $names.Count; $i++)
  {
    if ($i -eq $assigneeIndex) { continue }
    if ($names[$i]) { $extras += $names[$i] }
  }
  return ($extras -join ', ')
}

# A raw Agility value mapped through a named value map in mappings.json. Trim, then CASE SENSITIVE
# exact match (ConvertFrom-Json property access is case insensitive, and the user wants exact), so
# "AV - Kanban" and "av - kanban" are not the same key. A value not in the map is deliberately NOT
# written: it is recorded in $script:fieldWarnings (id, type, map, raw) so a value the map has never
# seen surfaces in the run summary instead of being silently dropped or silently passed through.
function MapFieldValue([string]$mapName, [string]$raw, $item)
{
  if (-not $raw) { return $null }

  $key = "$raw".Trim()
  $map = $script:mappings.$mapName
  if ($map)
  {
    foreach ($prop in $map.PSObject.Properties)
    {
      if ($prop.Name -ceq $key) { return $prop.Value }
    }
  }

  if ($null -eq $script:fieldWarnings) { $script:fieldWarnings = @() }
  $script:fieldWarnings += [pscustomobject]@{
    Id = $item.Number; Type = $item.AgilityType; Map = $mapName; Raw = $raw
  }
  return $null
}

# The Custom.DigitalAI* field definition (Field + AdoTypes) for a logical name, or $null if the name
# is unknown. Paired with TypeHasCustomField so a field is written and asserted for exactly the ADO
# types it exists on.
function CustomFieldDef([string]$name)
{
  if (-not $script:mappings.CustomFields) { return $null }
  $prop = $script:mappings.CustomFields.PSObject.Properties[$name]
  if ($prop) { return $prop.Value }
  return $null
}

function TypeHasCustomField($def, [string]$adoType)
{
  return ($def -and (@($def.AdoTypes) -contains $adoType))
}

# The AssignedTo op, or $null when there is no assignee. Split out of BuildFieldPatch so it can be
# applied as a SEPARATE rule-checked patch after the bypassRules create, and validated on its own in
# the dry run. Email first, display name when Agility has no email; the identity rejection (a departed
# owner) is handled by SetAdoAssignee, not here.
function BuildAssigneeOp($epic)
{
  $assignee = ResolveAssignee $epic
  if (-not $assignee) { return $null }
  return @{ op = "add"; path = "/fields/System.AssignedTo"; value = $assignee }
}

# The identity string for a history person (creator or last changer): email first, then display name,
# or $null. UNLIKE ResolveAssignee, a departed identity is fine here, because these fields are written
# under bypassRules (which accepts System.CreatedBy/ChangedBy for identities ADO would reject on
# AssignedTo, verified live on jordan.blake@example.com). So no assignability filtering.
function ResolveHistoryPerson([string]$email, [string]$name)
{
  if ($email) { return $email }
  if ($name)  { return $name }
  return $null
}

# The backdated header ops for revision 1: the item is created as if by its Agility creator on its
# Agility create date. CreatedBy/ChangedBy get the creator and CreatedDate/ChangedDate get the create
# date, so revision 1 is self-consistent at the create moment; a later revision (SetAdoState) moves
# ChangedBy/ChangedDate forward to the last-modified moment. These require bypassRules to write.
#
# Returns an empty array when there is no creator or no parseable create date, so an item with no
# history data simply gets ADO's own create stamp rather than a half-backdated one.
function BuildHistoryHeaderOps($epic)
{
  $creator = ResolveHistoryPerson $epic.CreatedByEmail $epic.CreatedByName
  $created = FormatDate $epic.CreateDate
  if (-not $creator -or -not $created) { return @() }

  return @(
    @{ op = "add"; path = "/fields/System.CreatedBy";   value = $creator }
    @{ op = "add"; path = "/fields/System.CreatedDate"; value = $created }
    @{ op = "add"; path = "/fields/System.ChangedBy";   value = $creator }
    @{ op = "add"; path = "/fields/System.ChangedDate"; value = $created }
  )
}

# Every field the work item gets, with no relations. Shared by the real create and the dry run
# validation on purpose: if they built different payloads, the dry run would be validating
# something other than what actually gets written.
# Strategic themes for an item, resolved once and shared by the field write and the description.
# Each raw theme is corrected through StrategicThemeValueMap (spelling fix plus duplicate
# consolidation, unmapped values recorded as field warnings), then deduped. Returns:
#   All        - every mapped, deduped theme, in order
#   Kept       - the leading themes whose joined length fits the DevLabs control's 255 char field
#   Overflowed - true when Kept is shorter than All, i.e. the field cannot hold them all
#
# When it overflowed, ADO would reject the whole create (TF401324, as E-04968's 315-char list did),
# so the field takes what fits and BuildDescription lists ALL of them under "Strategic Themes".
# Returns empties for a type without the field, so callers need no type check of their own here.
function ResolveThemeWrite($epic)
{
  $empty = [pscustomobject]@{ All = @(); Kept = @(); Overflowed = $false }

  $themeDef = CustomFieldDef 'StrategicTheme'
  if (-not (TypeHasCustomField $themeDef $epic.AdoType)) { return $empty }

  $all = @()
  foreach ($raw in @($epic.StrategicThemes))
  {
    $mapped = MapFieldValue 'StrategicThemeValueMap' $raw $epic
    if ($mapped -and $all -notcontains $mapped) { $all += $mapped }
  }
  if ($all.Count -eq 0) { return $empty }

  $kept = @()
  foreach ($t in $all)
  {
    if ((($kept + $t) -join '; ').Length -le 255) { $kept += $t }
  }

  $overflowed = ($kept.Count -lt $all.Count)
  if ($overflowed)
  {
    if ($null -eq $script:fieldWarnings) { $script:fieldWarnings = @() }
    $script:fieldWarnings += [pscustomobject]@{
      Id = $epic.Number; Type = $epic.AgilityType
      Map = "StrategicTheme over 255 chars, full list in the description"; Raw = ($all -join '; ')
    }
  }

  return [pscustomobject]@{ All = $all; Kept = $kept; Overflowed = $overflowed }
}

function BuildFieldPatch($epic)
{
  $patch = @()

  # Resolve the strategic themes ONCE, up front: the field write and the description both need them,
  # and the description shows the FULL list when the field cannot hold it (below).
  $themeInfo = ResolveThemeWrite $epic

  $patch += @{ op = "add"; path = "/fields/System.Title"; value = (BuildTitle $epic) }
  $patch += @{ op = "add"; path = "/fields/System.Description"; value = (BuildDescription $epic $themeInfo) }

  # The Agility Number and its raw Status go in real fields, not tags. Both are on all six types,
  # and AssertFieldsExist proves that before the first create rather than trusting it: ADO accepts
  # a write to a field a type does not have and drops the value without a word.
  $patch += @{ op = "add"; path = "/fields/$($script:mappings.RequiredFields.AgilityId)"; value = $epic.Number }

  # The RAW Agility status, not the mapped ADO state. That is the point of keeping it: MapState
  # collapses 393 finished Epics with no Status, and junk values like "Systems" and "Vendor", onto
  # a handful of ADO states. This is the value before any of that happened.
  $rawStatus = if ($epic.Status) { $epic.Status } else { "" }
  $patch += @{ op = "add"; path = "/fields/$($script:mappings.RequiredFields.AgilityStatus)"; value = $rawStatus }

  # Category and the fiscal year were agility-category: and agility-fy: tags until the user added
  # Custom.DigitalAIWorkItemCategory and Custom.DigitalAIWorkItemFY to every type. Like the raw
  # status, they are written on every item, empty when Agility has no value, so the field always
  # means something and is queryable. FY only ever has a value on Epics and Features: Agility's
  # Custom_FiscalYear attribute exists on Epic alone, so every other type writes it empty.
  $category = if ($epic.Category) { $epic.Category } else { "" }
  $patch += @{ op = "add"; path = "/fields/$($script:mappings.RequiredFields.AgilityCategory)"; value = $category }

  $fiscalYear = if ($epic.FiscalYear) { $epic.FiscalYear } else { "" }
  $patch += @{ op = "add"; path = "/fields/$($script:mappings.RequiredFields.AgilityFY)"; value = $fiscalYear }

  # ---- Custom.DigitalAI* fields that live on only some work item types ----
  # Each is gated on $epic.AdoType so it is written only where the field exists; ADO would silently
  # drop a write to a type without the field, and AssertFieldsExist proves the same set up front.
  $adoType = $epic.AdoType

  # Owners beyond the assignee, comma separated. On every type. Was the "Additional owners" line in
  # the description until the user added Custom.DigitalAIOwners on 2026-07-17.
  $ownersDef = CustomFieldDef 'Owners'
  if (TypeHasCustomField $ownersDef $adoType)
  {
    $owners = BuildOwnersField $epic
    if ($owners) { $patch += @{ op = "add"; path = "/fields/$($ownersDef.Field)"; value = $owners } }
  }

  # Team, normalized through TeamValueMap. Epic ONLY in ADO right now, so a Story/Defect/Task/Issue
  # team, and a nested Agility Epic that becomes a Feature, have no field and are dropped.
  $teamDef = CustomFieldDef 'Team'
  if ((TypeHasCustomField $teamDef $adoType) -and $epic.Team)
  {
    $team = MapFieldValue 'TeamValueMap' $epic.Team $epic
    if ($team) { $patch += @{ op = "add"; path = "/fields/$($teamDef.Field)"; value = $team } }
  }

  # Mandate. Epic ONLY, so a nested Agility Epic (which becomes a Feature) has no field for it.
  $mandateDef = CustomFieldDef 'Mandate'
  if ((TypeHasCustomField $mandateDef $adoType) -and $epic.Mandate)
  {
    $patch += @{ op = "add"; path = "/fields/$($mandateDef.Field)"; value = $epic.Mandate }
  }

  # Strategic theme (Epic and Feature only): the themes that fit the DevLabs control's 255 char field,
  # resolved up front by ResolveThemeWrite. When they overflowed, the full list is in the description
  # under "Strategic Themes" (see BuildDescription), so nothing is lost.
  $themeDef = CustomFieldDef 'StrategicTheme'
  if ((TypeHasCustomField $themeDef $adoType) -and $themeInfo.Kept.Count -gt 0)
  {
    $patch += @{ op = "add"; path = "/fields/$($themeDef.Field)"; value = ($themeInfo.Kept -join '; ') }
  }

  # The Agility ResolutionReason goes to a different field per type: a Defect's to the Bug field, an
  # Issue's to the Impediment field. Each field exists on only that one type, and the raw values
  # already match the dropdown choices exactly (Fixed/Cannot Reproduce/... ; Resolved/No Action), so
  # no value map is needed. A Defect never selected ResolutionReason before 2026-07-17, so those 291
  # values were dropped until now.
  if ($epic.AgilityType -eq 'Defect')
  {
    $bugResDef = CustomFieldDef 'BugResolution'
    if ((TypeHasCustomField $bugResDef $adoType) -and $epic.ResolutionReason)
    {
      $patch += @{ op = "add"; path = "/fields/$($bugResDef.Field)"; value = $epic.ResolutionReason }
    }
  }
  elseif ($epic.AgilityType -eq 'Issue')
  {
    $impResDef = CustomFieldDef 'ImpedimentResolution'
    if ((TypeHasCustomField $impResDef $adoType) -and $epic.ResolutionReason)
    {
      $patch += @{ op = "add"; path = "/fields/$($impResDef.Field)"; value = $epic.ResolutionReason }
    }
  }

  # Tags come after, because BuildTags no longer carries the Number, the Status, the Category or the
  # fiscal year.
  $tags = BuildTags $epic
  if ($tags) { $patch += @{ op = "add"; path = "/fields/System.Tags"; value = $tags } }

  $area = FormatAreaPath $epic.AreaPath
  if ($area) { $patch += @{ op = "add"; path = "/fields/System.AreaPath"; value = $area } }

  # The Agility Timebox is an iteration node created up front from the timeboxes the items
  # reference. A timebox with no node would be rejected, so it is validated in the dry run.
  if ($epic.Timebox)
  {
    $patch += @{ op = "add"; path = "/fields/System.IterationPath"; value = "$($script:config.AzureDevOps.Project)\$($epic.Timebox)" }
  }

  # System.AssignedTo is deliberately NOT here. The create is now a bypassRules create (so it can
  # backdate System.CreatedBy/CreatedDate for the revision history), and bypassRules skips identity
  # validation, so a departed owner would be stored as an unresolvable identity instead of being
  # rejected. The assignee is set afterwards by SetAdoAssignee in a separate, rule-checked patch,
  # which validates the identity exactly as before. BuildAssigneeOp / the dry run use the same logic.

  $start = FormatDate $epic.PlannedStart
  if ($start) { $patch += @{ op = "add"; path = "/fields/Microsoft.VSTS.Scheduling.StartDate"; value = $start } }

  $end = FormatDate $epic.PlannedEnd
  if ($end) { $patch += @{ op = "add"; path = "/fields/Microsoft.VSTS.Scheduling.TargetDate"; value = $end } }

  # Agility Order is a large signed integer. ADO takes it as a double, so relative backlog order
  # survives even though the numbers look odd.
  if ($null -ne $epic.Order)
  {
    $patch += @{ op = "add"; path = "/fields/Microsoft.VSTS.Common.BacklogPriority"; value = [double]$epic.Order }
  }

  $priority = MapPriority $epic.Priority
  if ($null -ne $priority)
  {
    $patch += @{ op = "add"; path = "/fields/Microsoft.VSTS.Common.Priority"; value = $priority }
  }

  # Agility carries the Epic estimate in Swag, the Story/Defect estimate in Estimate, and the Task
  # remaining hours in ToDo, all parsed onto Estimate. Only send the field when there is a value,
  # so unestimated items are left unset rather than forced to zero.
  #
  # The ADO field is NOT the same for every type. Scrum's Task has no Effort field at all, only
  # Remaining Work, so sending Effort to a Task would write nothing. Worth knowing: ADO does not
  # reject it, and neither does validateOnly, so this would have been a silent loss across 43,000
  # items rather than a failure anyone could see.
  if ($null -ne $epic.Estimate)
  {
    $estimateField = if ($epic.AgilityType -eq 'Task') { $script:mappings.Fields.TaskEstimate }
                     else                              { $script:mappings.Fields.Estimate }

    $patch += @{ op = "add"; path = "/fields/$estimateField"; value = $epic.Estimate }
  }

  # Impediment has a real Resolution field and 296 of 388 Issues carry one, so it goes somewhere
  # structured rather than into prose. Bug has no such field, so Defect keeps appending its
  # Resolution to the description instead; the two types differ here on purpose.
  if ($epic.AgilityType -eq 'Issue' -and $epic.Resolution)
  {
    $patch += @{ op = "add"; path = "/fields/$($script:mappings.Fields.Resolution)"; value = $epic.Resolution }
  }

  # Agility's Epic.Value. Epic and Feature have Business Value; Bug does not, and Task and
  # Impediment do not either, so this stays behind an AgilityType check rather than a null check.
  # It will populate 2 items out of 858: the data is nearly all missing in Agility, which is why
  # Business Value looks empty in ADO. That is not a mapping fault.
  if ($epic.AgilityType -eq 'Epic' -and $null -ne $epic.BusinessValue)
  {
    $patch += @{ op = "add"; path = "/fields/$($script:mappings.Fields.BusinessValue)"; value = $epic.BusinessValue }
  }

  # ClosedDate is deliberately absent here. ADO only allows it on a closed state, and this item is
  # created in its default state, so sending it now is rejected outright:
  # "Rule Error for field Closed Date. Error code: InvalidNotEmpty". SetAdoClosedDate handles it
  # after the state transition.

  # Issue.TargetDate is the only date an Issue has, and Impediment has no TargetDate field, so it
  # rides along in the description footer instead. Defect only fields follow.
  if ($epic.Environment)  { $patch += @{ op = "add"; path = "/fields/$($script:mappings.Fields.Environment)"; value = $epic.Environment } }
  if ($epic.FoundInBuild) { $patch += @{ op = "add"; path = "/fields/$($script:mappings.Fields.FoundInBuild)"; value = $epic.FoundInBuild } }

  return $patch
}

function NewAdoWorkItem($epic, $parentId, $trueParentId, $blockedIds)
{
  $patch = BuildFieldPatch $epic

  # Backdate the creation to the Agility creator and create date (revision 1 of the history). This is
  # why the create uses bypassRules below: System.CreatedBy/CreatedDate are read only under normal
  # rules. Empty when there is no history data, leaving ADO's own create stamp.
  $patch += BuildHistoryHeaderOps $epic

  if ($parentId)
  {
    $patch += @{
      op    = "add"
      path  = "/relations/-"
      value = @{
        rel = ($script:mappings.LinkTypes.Parent)
        url = (AdoWorkItemUrl $parentId)
      }
    }
  }

  # Agility's "this Issue blocks that work item" becomes Affects, pointing from the Impediment at
  # each thing it blocks.
  #
  # Not Parent/Child: a single Issue blocks up to 12 items, and hierarchy is a tree topology that
  # allows one parent, so it cannot represent this data at all. Affects is a dependency topology,
  # so it is directional and many to many, which is what the data needs.
  foreach ($blockedId in @($blockedIds))
  {
    $patch += @{
      op    = "add"
      path  = "/relations/-"
      value = @{
        rel        = ($script:mappings.LinkTypes.Blocks)
        url        = (AdoWorkItemUrl $blockedId)
        attributes = @{ comment = "Blocked by Agility $($epic.Number)." }
      }
    }
  }

  # A flattened Epic hangs off the root rather than its real parent, so record the real parent as
  # a Related link. Hierarchy-Reverse would be the honest link type, but it is exactly the same
  # category link that breaks the backlog, so Related is the only lossless option available.
  if ($trueParentId -and $trueParentId -ne $parentId)
  {
    $patch += @{
      op    = "add"
      path  = "/relations/-"
      value = @{
        rel     = ($script:mappings.LinkTypes.Related)
        url     = (AdoWorkItemUrl $trueParentId)
        attributes = @{ comment = "Agility parent of $($epic.Number). Flattened because Azure DevOps has only two portfolio levels." }
      }
    }
  }

  # bypassRules so the backdated System.CreatedBy/CreatedDate/ChangedBy/ChangedDate above are written
  # (they are read only otherwise). Safe here ONLY because System.AssignedTo is NOT in this payload:
  # bypassRules skips identity validation, so a departed owner on the create would be stored as an
  # unresolvable identity. The assignee is set afterwards by SetAdoAssignee, rule checked. A test
  # asserts AssignedTo never appears in a bypassRules payload.
  $url = "{0}/{1}/_apis/wit/workitems/`${2}?bypassRules=true&api-version=7.1" -f `
    $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'),
    [uri]::EscapeDataString($script:config.AzureDevOps.Project),
    [uri]::EscapeDataString($epic.AdoType)

  $response = InvokeAdoRequest $url "Post" $patch "application/json-patch+json"

  return $response.id
}

# Created in the default state first, then moved. This is revision 2 of the item's history: the
# transition, backdated to the Agility last-modified moment and attributed to the last changer, so
# ADO shows "created by X on date, then changed by Y on date".
#
# The two step dance is not optional even without history. ADO restricts System.State on create to
# the Proposed category, and Impediment has none: its states are Open (InProgress) and Closed
# (Completed). Creating an Impediment as Closed fails with "the value 'Closed' is not in the list of
# supported values", so Closed is only reachable as a transition.
#
# bypassRules is needed to write System.ChangedBy/ChangedDate (read only otherwise) and to accept a
# departed last changer. It does not touch System.AssignedTo, so the identity guarantee holds.
function SetAdoState([int]$id, [string]$state, $epic)
{
  if (-not $state) { return }

  $ops = @(@{ op = "add"; path = "/fields/System.State"; value = $state })

  if ($epic)
  {
    $changer = ResolveHistoryPerson $epic.ChangedByEmail $epic.ChangedByName
    if ($changer) { $ops += @{ op = "add"; path = "/fields/System.ChangedBy"; value = $changer } }

    # Backdate the transition's ChangedDate ONLY when the create itself was backdated, i.e. rev 1
    # actually sits at CreateDate. The create is backdated only when BuildHistoryHeaderOps had BOTH a
    # creator and a create date; with an empty CreatedBy it produces nothing, so rev 1 stays at server
    # time (now). Sending a PAST ChangedDate then is earlier than rev 1 - VS402625 "dates must be
    # increasing", which is exactly what failed TK-01316 (empty CreatedBy, real CreateDate). Checking
    # the create date alone was not enough; the creator has to be there too.
    $creator = ResolveHistoryPerson $epic.CreatedByEmail $epic.CreatedByName
    $created = FormatDate $epic.CreateDate
    $changed = FormatDate $epic.ChangeDate
    if ($creator -and $created -and $changed -and $changed -gt $created)
    {
      $ops += @{ op = "add"; path = "/fields/System.ChangedDate"; value = $changed }
    }

    # Set the Closed Date IN this transition when the item lands in a closed state. bypassRules skips
    # the rule that would auto-stamp it, so without this the item sits in a closed state with an EMPTY
    # Closed Date - and the very next RULE-CHECKED patch (the assignee) rejects it with TF401320
    # "Closed Date ... Required, InvalidEmpty". That is what failed 30,928 Tasks. Task's Done REQUIRES
    # a Closed Date, so a closed Task with no Agility date falls back to its last-changed (then
    # created) date, since it cannot be left empty. Other closed types allow an empty Closed Date, so
    # they get one only when Agility actually has it (an empty one is the correct "no real date" state,
    # and bypass never auto-stamps a fake one).
    if (IsClosedAdoState $epic $state)
    {
      $closed = FormatDate $epic.ClosedDate
      if (-not $closed -and $epic.AgilityType -eq 'Task')
      {
        $closed = FormatDate $epic.ChangeDate
        if (-not $closed) { $closed = FormatDate $epic.CreateDate }
      }
      if ($closed) { $ops += @{ op = "add"; path = "/fields/$($script:mappings.Fields.ClosedDate)"; value = $closed } }
    }
  }

  $bypass = if ($epic) { "bypassRules=true&" } else { "" }
  $url = "{0}/_apis/wit/workitems/{1}?{2}api-version=7.1" -f `
    $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'), $id, $bypass

  InvokeAdoRequest $url "Patch" $ops "application/json-patch+json" | Out-Null
}

# Revision 3: the assignee, in a SEPARATE rule-checked patch (no bypassRules), so a departed identity
# is rejected here rather than stored as an unresolvable one. The caller catches that rejection and
# leaves the item unassigned. Does nothing when there is nobody to assign.
function SetAdoAssignee([int]$id, $epic)
{
  $op = BuildAssigneeOp $epic
  if (-not $op) { return }

  $url = "{0}/_apis/wit/workitems/{1}?api-version=7.1" -f `
    $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'), $id

  InvokeAdoRequest $url "Patch" @($op) "application/json-patch+json" | Out-Null
}

# Rewrites Custom.DigitalAIOwners after an assignee was rejected: the create excluded the would-be
# assignee from the owners field, so once the item is left unassigned every owner must go back,
# including the one ADO would not accept.
function SetOwnersField([int]$id, [string]$owners)
{
  if (-not $owners) { return }

  $field = $script:mappings.CustomFields.Owners.Field
  $url = "{0}/_apis/wit/workitems/{1}?api-version=7.1" -f `
    $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'), $id

  InvokeAdoRequest $url "Patch" @(@{ op = "add"; path = "/fields/$field"; value = $owners }) "application/json-patch+json" | Out-Null
}

# The Agility Number is stamped as both a tag and a description footer. The tag drives
# idempotency, the footer survives for a human reading the item later.
#
# A flattened Epic also names its real Agility parent, so the original structure is readable even
# by someone who never looks at the Related link.
function BuildDescription($epic, $themeInfo)
{
  $description = if ($epic.Description) { $epic.Description } else { "" }

  # The title was cut to fit ADO's 255 character cap, so keep the original in full here.
  if (IsTitleTruncated $epic)
  {
    $description = "<p><b>Full Agility title:</b> " + [System.Net.WebUtility]::HtmlEncode($epic.Name) + "</p>" + $description
  }

  # ADO's Bug has no Resolution field, and 543 Defects have one. Repro Steps and Acceptance
  # Criteria are both real fields but neither means "how it was resolved", so putting it there
  # would mislead the next reader. The description keeps it truthfully.
  #
  # Issue is excluded because Impediment DOES have a Resolution field, so its 296 go there instead
  # of here. Without this check they would land in both places.
  if ($epic.Resolution -and $epic.AgilityType -ne 'Issue')
  {
    $description += "<hr /><p><b>Resolution:</b> " + $epic.Resolution + "</p>"
  }

  # Impediment has no TargetDate field, so an Issue's target date rides in the footer.
  $target = FormatDate $epic.TargetDate
  if ($target)
  {
    $description += "<hr /><p><b>Agility target date:</b> " + ([datetime]$epic.TargetDate).ToString('yyyy-MM-dd') + "</p>"
  }

  # When the strategic themes overflowed the 255 char field, list ALL of them here so nothing is
  # lost: the field holds what fit, the description holds the complete set. Only on overflow, by
  # request, so a normal item does not repeat its themes in the description.
  if ($themeInfo -and $themeInfo.Overflowed -and @($themeInfo.All).Count -gt 0)
  {
    $description += "<hr /><p><b>Strategic Themes:</b> " + [System.Net.WebUtility]::HtmlEncode(($themeInfo.All -join '; ')) + "</p>"
  }

  # The Agility metadata block, now just the Sprint (Timebox) line: owners, team, mandate, strategic
  # theme and resolution reason became Custom.DigitalAI* fields, and source became a tag again.
  $description += BuildAgilityDetails $epic

  $footer = "<hr /><p><i>Migrated from digital.ai Agility $($epic.Number)"

  if ($epic.Flattened -and $epic.TrueParentOid)
  {
    $parentNumber = $script:numberByOid[$epic.TrueParentOid]
    if ($parentNumber)
    {
      $footer += ". Agility parent: $parentNumber, flattened to the top level Epic because Azure DevOps has only two portfolio levels"
    }
  }

  return $description + $footer + "</i></p>"
}

# The block of Agility metadata appended to the description by BuildDescription. On 2026-07-17 the
# user moved owners, team, mandate, strategic theme, and resolution reason out of here into
# Custom.DigitalAI* fields, and source back to an agility-source tag, so the ONLY line left is the
# Sprint (the Agility Timebox). The Timebox is also the item's iteration path (System.IterationPath),
# so this line is a human readable echo of that; it is kept because the user has not asked to drop it.
function BuildAgilityDetails($item)
{
  $lines = @()

  if ($item.Timebox) { $lines += "Sprint: $($item.Timebox)" }

  if ($lines.Count -eq 0) { return "" }

  # Encode each line so a value containing markup cannot break the description HTML.
  $encoded = $lines | ForEach-Object { [System.Net.WebUtility]::HtmlEncode($_) }
  return "<hr /><p><b>Agility details</b><br />" + ($encoded -join "<br />") + "</p>"
}

# Tags written now: an unmigrated parent, unmigrated blocked items, and a Defect's Source. Parent
# and blocks are kept because they are worth querying ("show me every item with an unmigrated
# parent"); Source is a tag by the user's request on 2026-07-17 (Defect only, not a field, not in
# the description). Owners, team, mandate, strategic theme and resolution reason became
# Custom.DigitalAI* fields, and sprint is the iteration path plus a description line.
#
# ADO separates tags with semicolons, so any semicolon inside a value is replaced.
function BuildTags($item)
{
  $tags = @()

  # An Agility parent that is not in ADO cannot be linked, so keep the number. Otherwise an item
  # whose Epic lives in a scope that is not configured would land in ADO with nothing to say it ever
  # had a parent.
  if ($item.ParentUnresolved -and $item.ParentNumberForTag) { $tags += "agility-parent:$($item.ParentNumberForTag)" }

  # Same rule for a blocked work item outside the configured scopes: the Affects link cannot be
  # made, so the number stays.
  foreach ($number in @($item.BlockedUnresolved))
  {
    if ($number) { $tags += "agility-blocks:$number" }
  }

  # Source is Defect only (23 of 706 carry one). A tag, not a field, by request.
  if ($item.Source) { $tags += "agility-source:$($item.Source)" }

  return (($tags | ForEach-Object { $_ -replace ';', ',' }) -join '; ')
}

# The Agility Theme (Story.Parent / Defect.Parent) names the area path leaf under the scope's own
# area path. Theme names do not match the ADO node names (Applications vs Apps), so the map in
# mappings.json translates them. A Theme with no entry, or an item with no Theme, stays at the
# scope's area path rather than inventing a node that does not exist.
function ResolveAreaPath([string]$scopeAreaPath, [string]$theme)
{
  if (-not $theme) { return $scopeAreaPath }

  $leaf = $script:mappings.ThemeAreaPaths.PSObject.Properties[$theme]
  if (-not $leaf) { return $scopeAreaPath }

  if (-not $scopeAreaPath) { return $leaf.Value }

  return "$scopeAreaPath\$($leaf.Value)"
}

# ADO rejects a date it cannot parse, so send ISO 8601. Agility returns dates in the instance's
# own format, which is why this is parsed rather than passed through.
#
# The conversion to UTC is the whole point, and its absence was a real bug rather than a rounding
# detail. 'Z' is NOT a format specifier in a .NET custom format string, it is a literal character.
# So the old 'yyyy-MM-ddTHH:mm:ssZ' took a local time, stamped a Z on the end, and told ADO it was
# UTC. Agility's "2023-07-01" became "2023-07-01T00:00:00Z", ADO stored midnight UTC, and Mountain
# users saw **5pm on June 30** (MST) or 6pm (MDT). Every start and target date was off by a day,
# and the 5pm/6pm split was just daylight saving.
#
# Agility sends these as local wall clock time with no zone, so they are read as local and
# converted. A date with no time then lands on midnight local, which is what a date with no time
# should mean. ToUniversalTime treats an Unspecified DateTime as local, which is exactly right
# here; the machine's zone (matching the target instance) is the reference.
function FormatDate($value)
{
  if (-not $value) { return $null }

  try
  {
    $parsed = [datetime]$value

    # Guard against a value that already carries a zone: converting one of those again would shift
    # it a second time.
    if ($parsed.Kind -eq [System.DateTimeKind]::Unspecified)
    {
      $parsed = [datetime]::SpecifyKind($parsed, [System.DateTimeKind]::Local)
    }

    return $parsed.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'")
  }
  catch { return $null }
}

# System.Title is capped at 255 characters in ADO. Agility Name has no such cap, and some Epics
# carry a whole paragraph as their name. Truncate for the title and keep the full text in the
# description, so the create succeeds and nothing is lost.
#
# Newlines and tabs are collapsed to single spaces first. System.Title is a single line field, and
# S-29493's name has a newline in it with pasted UI chrome after it ("Update NVR Servers to Latest
# Version\nDetails History Visualize Delivery Ideas"). ADO accepts it, so this is about the title
# being readable rather than the create succeeding. Only 1 of 9,520 items needs it, but the cost is
# a line, and collapsing runs of whitespace keeps the words: nothing is dropped.
function NormalizeTitle($epic)
{
  $name = if ($epic.Name) { $epic.Name } else { "(untitled) $($epic.Number)" }

  return ($name -replace '\s+', ' ').Trim()
}

function BuildTitle($epic)
{
  $name = NormalizeTitle $epic

  if ($name.Length -le $script:TitleLimit) { return $name }

  return $name.Substring(0, $script:TitleLimit - 3) + "..."
}

# Both this and BuildTitle measure the NORMALIZED name, or they disagree: a name that is over the
# limit only because of its whitespace fits once collapsed, and would otherwise be reported as
# truncated while BuildTitle returned it whole.
function IsTitleTruncated($epic)
{
  return ((NormalizeTitle $epic).Length -gt $script:TitleLimit)
}

# ADO wants an area path rooted at the project, as in "Migration\IT\Operations". The config holds
# only the part below the project, so the project is prefixed here. An empty area path means the
# project root, which ADO fills in by default.
function FormatAreaPath([string]$areaPath)
{
  $project = $script:config.AzureDevOps.Project

  if (-not $areaPath) { return $project }

  return "$project\" + $areaPath.Trim('\')
}

function AdoWorkItemUrl($id)
{
  return "{0}/_apis/wit/workItems/{1}" -f $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'), $id
}

##################################################################################################
# Mapping
##################################################################################################

# AssetState wins over Status. An Epic closed in Agility is finished no matter what its Status
# says, and Status is unreliable on closed items: of the 754 closed Epics, 385 have no Status
# at all and 6 still say "In Progress". Mapping on Status alone would recreate 393 finished Epics
# in Azure DevOps as active work.
# States are per Agility type, because ADO states differ per work item type: Impediment only has
# Open and Closed, while Epic, PBI, and Bug have New/Approved/In Progress/Done/Removed.
function GetStateMap($item)
{
  $spec = $script:mappings.States.PSObject.Properties[$item.AgilityType]
  if (-not $spec) { throw "No state mapping for Agility type '$($item.AgilityType)' in mappings.json." }

  return $spec.Value
}

# Every state a run could produce, checked against ADO once per type before anything is written.
#
# The create payload carries no state, so validateOnly never sees one, and a typo in mappings.json
# would otherwise surface as a failed transition on item one of several thousand, after the create
# had already succeeded. That leaves a half migrated item behind. One call per type up front is
# cheaper than finding out that way.
function AssertStatesExist($agilityTypes)
{
  foreach ($agilityType in $agilityTypes)
  {
    $adoType = $script:mappings.WorkItemTypes.PSObject.Properties[$agilityType].Value

    # An Epic run creates Features for everything below the top level, so both types are in play.
    $adoTypes = @($adoType)
    if ($agilityType -eq 'Epic') { $adoTypes += $script:mappings.WorkItemTypes.NestedEpic }

    $spec = $script:mappings.States.PSObject.Properties[$agilityType].Value
    $wanted = @($spec.DefaultState, $spec.ClosedState) + @($spec.Map.PSObject.Properties.Value) |
      Where-Object { $_ } | Select-Object -Unique

    foreach ($t in $adoTypes | Select-Object -Unique)
    {
      $url = "{0}/{1}/_apis/wit/workitemtypes/{2}/states?api-version=7.1" -f `
        $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'),
        [uri]::EscapeDataString($script:config.AzureDevOps.Project),
        [uri]::EscapeDataString($t)

      $actual = (InvokeAdoRequest $url "Get" $null $null).value.name

      $missing = $wanted | Where-Object { $actual -notcontains $_ }
      if ($missing)
      {
        throw "mappings.json maps Agility '$agilityType' to ADO states that '$t' does not have: $($missing -join ', '). It has: $($actual -join ', ')."
      }
    }
  }
}

# Proves every field this run will write actually exists on every type it will write it to, once,
# before the first create.
#
# This is not belt and braces. ADO does NOT reject a patch that sets a field the work item type
# does not have: it accepts the create and drops the value. validateOnly does not catch it either
# (Effort on a Task and Resolution on a Bug both validate clean, and neither field is on those
# types). So a field missing from one type is invisible from every angle except this one: a clean
# dry run, a green create, and the data quietly gone on thousands of items.
#
# Found the hard way. Custom.DigitalAIWorkItemID was on Product Backlog Item, Bug and Task but not
# on Epic, Feature or Impediment, and nothing anywhere would have said so.
function AssertFieldsExist($agilityTypes)
{
  $adoTypes = @()
  foreach ($agilityType in $agilityTypes)
  {
    $adoTypes += $script:mappings.WorkItemTypes.PSObject.Properties[$agilityType].Value
    if ($agilityType -eq 'Epic') { $adoTypes += $script:mappings.WorkItemTypes.NestedEpic }
  }

  $required = @($script:mappings.RequiredFields.PSObject.Properties.Value)
  $problems = @()

  foreach ($t in ($adoTypes | Select-Object -Unique))
  {
    $url = "{0}/{1}/_apis/wit/workitemtypes/{2}/fields?api-version=7.1" -f `
      $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'),
      [uri]::EscapeDataString($script:config.AzureDevOps.Project),
      [uri]::EscapeDataString($t)

    $actual = (InvokeAdoRequest $url "Get" $null $null).value.referenceName

    # RequiredFields are on every type.
    foreach ($field in $required)
    {
      if ($actual -notcontains $field) { $problems += "$t is missing $field" }
    }

    # Custom.DigitalAI* fields are checked only against the types they are declared on, because they
    # exist on only some (Team/Mandate on Epic, BugResolution on Bug, and so on). A type not in a
    # field's AdoTypes never has that field written to it, so its absence is not a problem.
    if ($script:mappings.CustomFields)
    {
      foreach ($cf in $script:mappings.CustomFields.PSObject.Properties.Value)
      {
        if ((@($cf.AdoTypes) -contains $t) -and ($actual -notcontains $cf.Field))
        {
          $problems += "$t is missing $($cf.Field)"
        }
      }
    }
  }

  if ($problems)
  {
    throw "Azure DevOps is missing fields this migration writes, and it would DROP them silently rather than fail: $($problems -join '; '). Add them to those work item types in the process, then rerun."
  }
}

function MapState($item)
{
  $states = GetStateMap $item

  if (IsAgilityClosed $item) { return $states.ClosedState }

  if (-not $item.Status) { return $states.DefaultState }

  $mapped = $states.Map.PSObject.Properties[$item.Status]
  if ($mapped) { return $mapped.Value }

  return $states.DefaultState
}

# Whether an ADO state is the closed state for the item's type. ADO stamps ClosedDate on entry to
# it, so this is the trigger for correcting that stamp.
#
# Keyed off the mapped ADO state, not IsAgilityClosed: an item whose Status maps to Done (or an
# Issue's to Closed) lands in a closed ADO state even when Agility still shows it active, and ADO
# stamps a migration-day close date onto it with no Agility source. Those are exactly the items the
# old IsAgilityClosed trigger missed.
function IsClosedAdoState($item, [string]$adoState)
{
  return ($adoState -eq (GetStateMap $item).ClosedState)
}

# Whether the item's Agility Status is one we actually understand. An unmapped status falls back to
# the default state, so BuildTags keeps the original rather than losing it.
function IsMappedStatus($item)
{
  if (-not $item.Status) { return $true }

  return [bool](GetStateMap $item).Map.PSObject.Properties[$item.Status]
}

# Agility AssetState 128 is Closed. The value arrives as a number, but compare as text so a string
# response does not silently fall through and mark a closed Epic active.
function IsAgilityClosed($epic)
{
  return ([string]$epic.AssetState -eq '128')
}

function MapPriority([string]$agilityPriority)
{
  if (-not $agilityPriority) { return $script:mappings.Priorities.DefaultPriority }

  $mapped = $script:mappings.Priorities.Map.PSObject.Properties[$agilityPriority]
  if ($mapped) { return $mapped.Value }

  return $script:mappings.Priorities.DefaultPriority
}

##################################################################################################
# Plumbing
##################################################################################################

# Retries 429 and 5xx with exponential backoff. Anything else fails immediately, because retrying
# a 401 or a 400 just wastes time.
function InvokeWithRetry([scriptblock]$action, [int]$attempts = 3)
{
  for ($attempt = 1; $attempt -le $attempts; $attempt++)
  {
    try
    {
      return & $action
    }
    catch
    {
      $status = $_.Exception.Response.StatusCode.value__

      $isTransient = ($status -eq 429) -or ($status -ge 500 -and $status -le 599)
      if (-not $isTransient -or $attempt -eq $attempts) { throw }

      $delay = [Math]::Pow(2, $attempt)
      WriteLog "  RETRY   HTTP $status, attempt $attempt of $attempts, waiting $delay seconds" DarkYellow
      Start-Sleep -Seconds $delay
    }
  }
}

function WriteSummary
{
  WriteLog
  WriteLog "----------------------------------------"
  # A dry run creates nothing, so do not call it "Created".
  WriteLog "$(if ($script:DryRun) { 'Would create:' } else { 'Created: ' })  $script:created"
  WriteLog "Skipped:  $script:skipped"
  WriteLog "Failed:   $script:failed"
  WriteLog "Warnings: $script:warnings"

  # Values a value map (Team, strategic theme) never had an entry for. Grouped by map and value so a
  # single new team does not print a line per item. These were NOT written to their field, so this
  # is real data currently being dropped, and the fix is a new map entry.
  if ($script:fieldWarnings -and $script:fieldWarnings.Count -gt 0)
  {
    WriteLog "Unmapped field values: $($script:fieldWarnings.Count) (not written, add a value-map entry)" Yellow
    $script:fieldWarnings |
      Group-Object Map, Raw |
      Sort-Object Name |
      ForEach-Object {
        $sample = $_.Group[0]
        WriteLog ("  {0}  '{1}'  x{2}  (e.g. {3} {4})" -f $sample.Map, $sample.Raw, $_.Count, $sample.Type, $sample.Id) Yellow
      }
  }

  WriteLog "----------------------------------------"

  # Where the operator finds this again. Printed last on purpose: after several thousand lines it
  # is the one thing they need and the only thing still on screen. It goes into the log as well as
  # the console, so a log pasted into a ticket still says which run it came from.
  if ($script:logPath)
  {
    $elapsed = (Get-Date) - $script:runStarted
    WriteLog "Log: $script:logPath" Cyan
    WriteLogDetail ""
    WriteLogDetail "Finished $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) after $([int]$elapsed.TotalMinutes)m $($elapsed.Seconds)s"
  }

  # Failures are totalled across the whole script and turned into an exit code at the bottom.
  # Exiting here would abort a Main that calls Migrate more than once.
  $script:totalFailed += $script:failed
}

# The tests dot source this file to load the functions without migrating, and set this flag first
# to say so.
#
# The flag has to be explicit. VS Code's F5 dot sources the file too, exactly like the tests do,
# so $MyInvocation.InvocationName cannot tell a test run from a real one. Keying off it made F5
# skip Main and print nothing at all.
if ($global:AgilityEpicsLoadFunctionsOnly)
{
  Write-Host "Functions loaded, Main skipped." -ForegroundColor DarkGray
}
else
{
  # finally, not a plain call: an exception on the way out of Main must still release the log
  # handle. AutoFlush means the content is already safe either way, so this is about the handle.
  try     { Main }
  finally { StopLog }

  # Non zero if any item failed, across every Migrate call Main made.
  if ($script:totalFailed -gt 0) { exit 1 }
}
