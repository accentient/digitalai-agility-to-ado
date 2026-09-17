##################################################################################################
# Script to turn every Successor/Predecessor link in an Azure DevOps project the other way round.
#
#   RepairDependencyDirection -Project 'Training' -DryRun
#   RepairDependencyDirection -Project 'Training'
#
# Why it exists. Until 2026-09-16 the migration wrote Agility's Dependencies (what an item depends
# ON, the upstream work) as ADO SUCCESSORS and its Dependants as PREDECESSORS, so every dependency
# link in a migrated project points the wrong way: an item's finished prerequisites show as its
# successors and its unstarted follow-on work as its predecessors. The migration is fixed for the
# next run; this corrects a project that was already migrated.
#
# Why two passes over the WHOLE project. A link is one shared edge in one graph, and ADO checks
# that graph for cycles on every add. Flipping one item's links while its neighbours' links are
# still reversed closes a loop and is refused (proven on Training #320690: TF201035). So:
#
#   Pass 1  remove every dependency link from every item that has one, under a revision test so a
#           patch cannot land on an item somebody else changed since it was read.
#   Check   re-read the link graph; if any old link remains, STOP. Pass 2 never runs beside leftovers.
#   Pass 2  add every link back the other way, one write per link from the old Successor end, one
#           batched patch per item; a batch ADO refuses as circular is retried link by link so a
#           genuine Agility cycle costs only itself, exactly as in the migration.
#   Verify  re-read the graph and compare it LINK BY LINK to the reversed inventory: nothing
#           missing, nothing extra, nothing still the old way, and every touched item's other
#           relations unchanged. A counter is not evidence; the comparison is.
#
# The inventory is written to logs/ before the first write, so a killed run can be resumed with
# -Resume <that file>: what is already flipped is skipped, what is still old is removed and redone.
#
# It is a SEPARATE, self contained script, like Remove-WorkItems.ps1 and Create-Iterations.ps1: it
# neither loads nor names the other scripts, it has no door to Agility, it never deletes a work
# item, and the only path it ever patches is /relations. Tests assert all of that, which is why the
# plumbing below is duplicated rather than factored into a shared file.
#
# Main ships with -DryRun as its live line. A dry run reads everything and writes nothing.
##################################################################################################

$script:configPath = Join-Path $PSScriptRoot ".." "appsettings.json"
$script:logDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".." "logs"))
$script:logPath = $null
$script:logWriter = $null
$script:totalFailed = 0

function Main
{
  # clear-host throws when the host has no console handle, as in CI or any redirected run.
  try { clear-host } catch { }

  Write-Host "Repair-DependencyDirection starting" -ForegroundColor Cyan
  Write-Host

  # Futz with these. The live line is a dry run and should stay one until you mean it.
  #
  # RepairDependencyDirection -Project 'Training'                              # the real thing, two passes
  # RepairDependencyDirection -Project 'Training' -Resume 'C:\...\DependencyInventory-Training-....json'
  # RepairDependencyDirection -Project 'IT' -DryRun
  #
  # Work items are created by Migrate-Agility.ps1 and removed by Remove-WorkItems.ps1, both of
  # which are air gapped from this script.

  RepairDependencyDirection -Project 'Training' -DryRun
}

##################################################################################################
# Repair
##################################################################################################

$script:SuccessorRel   = 'System.LinkTypes.Dependency-Forward'
$script:PredecessorRel = 'System.LinkTypes.Dependency-Reverse'

function RepairDependencyDirection([string]$Project, [switch]$DryRun, [string]$Resume)
{
  $script:DryRun = [bool]$DryRun
  $removed = 0
  $written = 0
  $refused = @()
  $failed = 0

  StartLog
  $script:runStarted = Get-Date
  WriteLogDetail "RepairDependencyDirection '$Project' log, started $($script:runStarted.ToString('yyyy-MM-dd HH:mm:ss'))"
  WriteLogDetail ""

  $script:config = GetConfig $script:configPath
  if (-not $Project) { throw "A -Project is required; this never defaults to the configured project." }

  WriteLog "Reversing every Successor/Predecessor link in $($script:config.AzureDevOps.OrganizationUrl) project $Project"
  if ($script:DryRun) { WriteLog "DRY RUN - nothing will be written to Azure DevOps" Yellow }
  WriteLog

  WriteLog "Resolving credentials..."
  $script:adoHeaders = BuildAdoHeaders
  WriteLog

  # The inventory: every link as it is now, saved BEFORE anything is written. On a resume, the
  # inventory is the file from the run that was killed, and the current graph is read beside it.
  if ($Resume)
  {
    $old = @(LoadInventory $Resume)
    WriteLog "Resuming from $Resume : $($old.Count) links in the inventory"
  }
  else
  {
    $old = @(ReadLinkInventory $Project)
    $inventoryPath = Join-Path $script:logDir ("DependencyInventory-{0}-{1}.json" -f $Project, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    SaveInventory $old $inventoryPath
    WriteLog "Inventory: $($old.Count) links, saved to $inventoryPath"
  }
  $current = @(ReadLinkInventory $Project)
  $oldKeys = @{}; foreach ($e in $old) { $oldKeys[(EdgeKey $e)] = $true }
  $stillOld = @($current | Where-Object { $oldKeys.ContainsKey((EdgeKey $_)) })
  WriteLog "Current graph: $($current.Count) links, of which $($stillOld.Count) are still the old way round"

  $ids = @(@($old | ForEach-Object { $_.From }) + @($old | ForEach-Object { $_.To }) | Select-Object -Unique)
  $writers = GroupEdgesByWriter $old
  WriteLog "Touches $($ids.Count) work items; pass 2 writes from $($writers.Keys.Count) of them"
  WriteLog

  $before = ReadItemsWithRelations $Project $ids
  $otherBefore = @{}
  foreach ($id in $before.Keys) { $otherBefore[$id] = @(NonDependencyRelationKeys $before[$id].relations) }
  WriteLog "Read $($before.Count) items with their relations"

  if ($script:DryRun)
  {
    $toPatch = @($before.Keys | Where-Object { @(BuildRemoveOps $before[$_]).Count -gt 0 })
    WriteLog "  WOULD remove dependency links from $($toPatch.Count) items, then write $($old.Count) links the other way round from $($writers.Keys.Count) items"
    WriteSummary $Project $old.Count $toPatch.Count $old.Count @() 0
    return
  }

  # The recovery record: every touched item's COMPLETE relation list, on disk before the first
  # write. The revision history recovered the first run's mistakes, but that was luck of the API;
  # this is the deliberate copy.
  $snapshotPath = Join-Path $script:logDir ("RelationSnapshot-{0}-{1}.json" -f $Project, (Get-Date -Format 'yyyyMMdd-HHmmss'))
  SaveRelationSnapshot $before $snapshotPath
  WriteLog "Relation snapshot of $($before.Count) items saved to $snapshotPath"
  WriteLog

  # ---- Pass 1: remove ----------------------------------------------------------------------------
  WriteLog "--- Pass 1: removing dependency links ---" Cyan
  $n = 0
  # The pre-run snapshot only says WHICH items to visit. The indexes come from a fresh read of each
  # item made right before its patch, inside RemoveDependencyLinks - see there for why.
  foreach ($id in ($before.Keys | Sort-Object))
  {
    $item = $before[$id]
    if (-not (HasDependencyLink $item)) { continue }
    # On a resume only an item still holding an OLD link is touched; a fully flipped item is left.
    if ($Resume -and -not (HoldsOldLink $item $oldKeys)) { continue }

    $n++
    $r = RemoveDependencyLinks $Project $id
    if ($r.Ok) { if ($r.Removed -gt 0) { $removed++ } }
    else
    {
      WriteLog "  FAIL    #$id $($r.Message)" Red
      $failed++
      # A patch that took anything but a dependency link means the indexes cannot be trusted. Stop
      # here, with one item to put right from the snapshot, not thousands.
      if ($r.Message -match 'NOT a dependency link')
      {
        WriteLog "  HALT    pass 1 stopped at #${id}: a patch removed a relation it must not touch. Restore it from $snapshotPath before resuming." Red
        break
      }
    }
    if ($n % 500 -eq 0) { WriteLog "  removed from $n items..." }
  }
  WriteLog "Removed dependency links from $removed items, $failed failed"
  AfterPass 'removed'

  # ---- Check: nothing old may remain before pass 2 ------------------------------------------------
  $current = @(ReadLinkInventory $Project)
  $stillOld = @($current | Where-Object { $oldKeys.ContainsKey((EdgeKey $_)) })
  if ($failed -gt 0 -or $stillOld.Count -gt 0)
  {
    WriteLog
    WriteLog "STOP: $($stillOld.Count) old links remain and $failed items failed in pass 1. Pass 2 will not run beside leftovers." Red
    WriteLog "      Fix the failures, then rerun with -Resume and the inventory file above." Red
    WriteSummary $Project $old.Count $removed 0 @() ($failed + $stillOld.Count)
    $script:totalFailed += ($failed + $stillOld.Count)
    return
  }
  WriteLog "Checked: 0 old links remain"
  WriteLog

  # ---- Pass 2: add flipped -----------------------------------------------------------------------
  WriteLog "--- Pass 2: writing links the other way round ---" Cyan
  $expected = @(FlipEdges $old)
  $todo = @(EdgesToWrite $expected $current)
  $todoByWriter = GroupEdgesByWriter @($todo | ForEach-Object { [pscustomobject]@{ From = $_.To; To = $_.From } })
  # $todo is in FLIPPED orientation (From = new predecessor side). The write happens from the
  # OLD source item as a Predecessor link, so group by the old source, which is $_.To here.
  $n = 0
  foreach ($writer in ($todoByWriter.Keys | Sort-Object))
  {
    $n++
    # Same rule as pass 1: the revision comes from a read of this item made right now, not from a
    # batch read made earlier.
    $item = InvokeAdoRequest (WorkItemReadUrl $Project $writer) "Get" $null $null
    $number = if ($item -and $item.fields -and $item.fields.'Custom.DigitalAIID') { $item.fields.'Custom.DigitalAIID' } else { "#$writer" }
    $rev = if ($item) { [int]$item.rev } else { 0 }
    $r = AddFlippedLinks $writer $rev @($todoByWriter[$writer]) $number
    $written += $r.Written
    foreach ($t in @($r.Refused)) { $refused += [pscustomobject]@{ From = $writer; To = $t } }
    if ($r.Failed) { $failed++ }
    if ($n % 500 -eq 0) { WriteLog "  written from $n items..." }
  }
  WriteLog "Wrote $written links, $($refused.Count) refused as circular, $failed items failed"
  AfterPass 'added'

  # ---- Verify ------------------------------------------------------------------------------------
  WriteLog
  WriteLog "--- Verify ---" Cyan
  $after = @(ReadLinkInventory $Project)
  $v = VerifyFlip $old $after $refused
  WriteLog "Graph: $($after.Count) links now; expected $($old.Count - $refused.Count) (inventory $($old.Count) minus $($refused.Count) refused)"
  WriteLog "  missing $($v.Missing.Count), extra $($v.Extra.Count), still old way $($v.Unflipped.Count)"
  foreach ($m in @($v.Missing   | Select-Object -First 20)) { WriteLog "  MISSING   $m" Red }
  foreach ($m in @($v.Extra     | Select-Object -First 20)) { WriteLog "  EXTRA     $m" Red }
  foreach ($m in @($v.Unflipped | Select-Object -First 20)) { WriteLog "  UNFLIPPED $m" Red }
  foreach ($m in @($v.Refused)) { WriteLog "  REFUSED   $m (a cycle Agility allows and Azure DevOps does not)" Yellow }

  $afterItems = ReadItemsWithRelations $Project $ids
  $otherAfter = @{}
  foreach ($id in $afterItems.Keys) { $otherAfter[$id] = @(NonDependencyRelationKeys $afterItems[$id].relations) }
  $changed = @(CompareOtherRelations $otherBefore $otherAfter)
  foreach ($c in $changed) { WriteLog "  FAIL    $c" Red }
  WriteLog "Other relations on the $($ids.Count) touched items: $(if ($changed.Count -eq 0) { 'unchanged' } else { "$($changed.Count) CHANGED" })"

  $problems = $failed + $v.Missing.Count + $v.Extra.Count + $v.Unflipped.Count + $changed.Count
  WriteSummary $Project $old.Count $removed $written $refused $problems
  $script:totalFailed += $problems
}

function WriteSummary([string]$project, [int]$links, [int]$removed, [int]$written, $refused, [int]$problems)
{
  WriteLog
  WriteLog "----------------------------------------"
  WriteLog "Project:            $project"
  WriteLog "Links in inventory: $links"
  WriteLog "$(if ($script:DryRun) { 'Would remove from:' } else { 'Removed from:     ' }) $removed items"
  WriteLog "$(if ($script:DryRun) { 'Would write:      ' } else { 'Written:          ' }) $written links"
  WriteLog "Refused (cyclic):   $(@($refused).Count)"
  WriteLog "Problems:           $problems"
  WriteLog "----------------------------------------"
  if ($script:logPath)
  {
    $elapsed = (Get-Date) - $script:runStarted
    WriteLog "Log: $script:logPath" Cyan
    WriteLogDetail "Finished $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) after $([Math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
  }
}

# A seam between the passes. Does nothing but record the moment; the tests hook it to move their
# fake graph from one state to the next.
function AfterPass([string]$name)
{
  WriteLogDetail "---- pass complete: $name, $((Get-Date).ToString('HH:mm:ss')) ----"
}

##################################################################################################
# Inventory
##################################################################################################

# Every dependency link in the project, each exactly once, as From -> To where From holds the
# Successor end (ADO's way of saying "From comes before To"). Read from BOTH ends and the two counts
# must agree, or the store is inconsistent and nothing is touched.
function ReadLinkInventory([string]$project)
{
  $forward = @(ParseLinkRows (RunLinkQuery $project $script:SuccessorRel))
  $reverse = @(ParseLinkRows (RunLinkQuery $project $script:PredecessorRel))

  if ($forward.Count -ne $reverse.Count)
  {
    throw "The link store is inconsistent: the Successor side has $($forward.Count) links but the Predecessor side has $($reverse.Count). Nothing was touched."
  }

  return $forward
}

# One WIQL link query, scoped to the project at both ends. The 20,000 row cap is far above the
# ~4,400 links a project holds; the count is checked against both ends anyway.
function RunLinkQuery([string]$project, [string]$rel)
{
  $wiql = @{ query = "SELECT [System.Id] FROM WorkItemLinks WHERE ([Source].[System.TeamProject] = '$project') AND ([System.Links.LinkType] = '$rel') AND ([Target].[System.TeamProject] = '$project') MODE (MustContain)" }
  $url = "{0}/{1}/_apis/wit/wiql?`$top=19999&api-version=7.0" -f $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'), [uri]::EscapeDataString($project)

  return (InvokeAdoRequest $url "Post" $wiql "application/json").workItemRelations
}

# A link query returns a row per source item (no rel) and a row per link (with rel). Only the
# latter are links. Duplicates are dropped, ids are forced to Int32 so hashtable keys match.
function ParseLinkRows($rows)
{
  $seen = @{}
  $edges = @()
  foreach ($row in @($rows | Where-Object { $_ }))
  {
    if (-not $row.rel -or -not $row.source -or -not $row.target) { continue }
    $edge = [pscustomobject]@{ From = [int]$row.source.id; To = [int]$row.target.id }
    $key = EdgeKey $edge
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $edges += $edge
  }
  return $edges
}

function EdgeKey($edge) { return "$($edge.From)>$($edge.To)" }

function SaveInventory($edges, [string]$path)
{
  $dir = Split-Path $path -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  @($edges | ForEach-Object { @{ From = [int]$_.From; To = [int]$_.To } }) | ConvertTo-Json -AsArray | Set-Content -Path $path -Encoding UTF8
}

# Every touched item's id, revision and complete relation list, as read before the first write.
function SaveRelationSnapshot($items, [string]$path)
{
  $dir = Split-Path $path -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $rows = @()
  foreach ($id in ($items.Keys | Sort-Object))
  {
    $wi = $items[$id]
    $rels = @()
    if ($wi.PSObject.Properties['relations'] -and $wi.relations)
    {
      foreach ($r in @($wi.relations | Where-Object { $_ })) { $rels += @{ rel = $r.rel; url = $r.url; attributes = $r.attributes } }
    }
    $rows += @{ Id = [int]$id; Rev = [int]$wi.rev; Relations = $rels }
  }
  $rows | ConvertTo-Json -Depth 8 -AsArray | Set-Content -Path $path -Encoding UTF8
}

function LoadInventory([string]$path)
{
  if (-not (Test-Path $path)) { throw "Inventory file not found: $path" }
  $raw = Get-Content $path -Raw | ConvertFrom-Json
  return @($raw | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ From = [int]$_.From; To = [int]$_.To } })
}

# The items at either end, with their relations, 200 per call. $expand cannot be combined with a
# field list, so every field comes back; Custom.DigitalAIID is read off it for the link comments.
function ReadItemsWithRelations([string]$project, $ids)
{
  $items = @{}
  $list = @($ids | ForEach-Object { [int]$_ })
  for ($i = 0; $i -lt $list.Count; $i += 200)
  {
    $chunk = $list[$i..([Math]::Min($i + 199, $list.Count - 1))]
    $url = "{0}/{1}/_apis/wit/workitemsbatch?api-version=7.1" -f $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'), [uri]::EscapeDataString($project)
    $response = InvokeAdoRequest $url "Post" @{ ids = $chunk; '$expand' = 'relations' } "application/json"
    foreach ($wi in @($response.value | Where-Object { $_ })) { $items[[int]$wi.id] = $wi }
  }
  return $items
}

##################################################################################################
# Pass 1
##################################################################################################

function IsDependencyRel([string]$rel) { return ($rel -eq $script:SuccessorRel -or $rel -eq $script:PredecessorRel) }

function TargetIdOf($relation) { return [int](($relation.url -split '/')[-1]) }

# The remove patch for one item: a test on its revision, then every dependency relation by index,
# highest first so the earlier indexes stay valid as ADO applies the ops in order. Nothing for an
# item with no dependency relation.
function BuildRemoveOps($item)
{
  $relations = @()
  if ($item.PSObject.Properties['relations'] -and $item.relations) { $relations = @($item.relations) }

  $indexes = @()
  for ($i = 0; $i -lt $relations.Count; $i++)
  {
    $r = $relations[$i]
    if ($r -and (IsDependencyRel $r.rel)) { $indexes += $i }
  }
  if ($indexes.Count -eq 0) { return @() }

  $ops = @(@{ op = 'test'; path = '/rev'; value = [int]$item.rev })
  foreach ($i in ($indexes | Sort-Object -Descending)) { $ops += @{ op = 'remove'; path = "/relations/$i" } }
  return $ops
}

# Removes one item's dependency links, from a read taken RIGHT NOW, and proves what the patch did.
#
# Why the read has to be fresh, and why the revision test is not enough on its own. Removing a link
# from item A also removes its mirror from item B, and B's revision does NOT move when that happens.
# So an index for B taken from a read made before A was patched is stale, the revision test on B
# still passes, and the remove lands on whatever relation now sits at that index. On the first live
# run (Training, 2026-09-16) that cost 804 items an out-of-range rejection, which is atomic and
# harmless, and 326 items a removal of the WRONG relation, which is not. Reading the same item
# immediately before its own patch closes that window; the response is then checked against that
# read so a wrong removal is reported the moment it happens rather than found in a later audit.
function RemoveDependencyLinks([string]$project, [int]$id)
{
  $fresh = InvokeAdoRequest (WorkItemReadUrl $project $id) "Get" $null $null
  $ops = @(BuildRemoveOps $fresh)
  if ($ops.Count -eq 0) { return [pscustomobject]@{ Ok = $true; Removed = 0; Message = "" } }

  $expectedOther = @(NonDependencyRelationKeys $fresh.relations)
  $toRemove = @($ops | Where-Object { $_.op -eq 'remove' }).Count

  try
  {
    $response = InvokeAdoRequest (WorkItemUrl $project $id) "Patch" $ops "application/json-patch+json"
  }
  catch
  {
    WriteErrorDetail $_ "remove links from #$id"
    return [pscustomobject]@{ Ok = $false; Removed = 0; Message = "could not have its links removed - $(ReadAdoError $_)" }
  }

  # The worse finding first: a relation that was not a dependency link is gone. Then the lesser one:
  # a dependency link is still there.
  $actualOther = @(NonDependencyRelationKeys $response.relations)
  $lost = @($expectedOther | Where-Object { $actualOther -notcontains $_ })
  if ($lost.Count -gt 0)
  {
    return [pscustomobject]@{ Ok = $false; Removed = $toRemove; Message = "the patch removed a relation that is NOT a dependency link: $($lost -join ', ')" }
  }

  $left = @($response.relations | Where-Object { $_ -and (IsDependencyRel $_.rel) })
  if ($left.Count -gt 0)
  {
    return [pscustomobject]@{ Ok = $false; Removed = $toRemove; Message = "still has $($left.Count) dependency relations after the remove" }
  }

  return [pscustomobject]@{ Ok = $true; Removed = $toRemove; Message = "" }
}

# Whether an item carries any dependency relation at all.
function HasDependencyLink($item)
{
  if (-not $item.PSObject.Properties['relations'] -or -not $item.relations) { return $false }
  return (@($item.relations | Where-Object { $_ -and (IsDependencyRel $_.rel) }).Count -gt 0)
}

# Whether an item still carries a link in the OLD orientation. A Successor relation X -> Y is the
# edge X>Y; a Predecessor relation X -> Y is the edge Y>X.
function HoldsOldLink($item, $oldKeys)
{
  foreach ($r in @($item.relations | Where-Object { $_ -and (IsDependencyRel $_.rel) }))
  {
    $t = TargetIdOf $r
    $key = if ($r.rel -eq $script:SuccessorRel) { "$([int]$item.id)>$t" } else { "$t>$([int]$item.id)" }
    if ($oldKeys.ContainsKey($key)) { return $true }
  }
  return $false
}

# "rel|url" for every relation that is NOT a dependency link. Compared as a set before and after,
# so the repair can prove it touched nothing else on the item.
function NonDependencyRelationKeys($relations)
{
  return @(@($relations | Where-Object { $_ -and $_.rel -and -not (IsDependencyRel $_.rel) }) | ForEach-Object { "$($_.rel)|$($_.url)" })
}

##################################################################################################
# Pass 2
##################################################################################################

# The inventory reversed: old From>To (From before To) becomes To>From.
function FlipEdges($edges)
{
  return @($edges | ForEach-Object { [pscustomobject]@{ From = [int]$_.To; To = [int]$_.From } })
}

# Old source -> the targets it had Successor links to. Each link is written once, from this end.
function GroupEdgesByWriter($edges)
{
  $groups = @{}
  foreach ($e in @($edges | Where-Object { $_ }))
  {
    $from = [int]$e.From
    if (-not $groups.ContainsKey($from)) { $groups[$from] = @() }
    $groups[$from] += [int]$e.To
  }
  return $groups
}

# The expected links that are not in the graph yet. On a first run that is all of them; on a
# resume it is whatever the killed run had not reached.
function EdgesToWrite($expected, $present)
{
  $have = @{}
  foreach ($e in @($present | Where-Object { $_ })) { $have[(EdgeKey $e)] = $true }
  return @($expected | Where-Object { -not $have.ContainsKey((EdgeKey $_)) })
}

# The add patch for one item: a revision test, then a PREDECESSOR link to each target. Old: this
# item had a Successor link to the target (ADO: item before target). Agility meant the item depends
# on the target, so the target comes first: a Predecessor link, which ADO shows from the target's
# side as a Successor back to this item.
function BuildAddOps([int]$id, [int]$rev, $targets, [string]$number)
{
  $ops = @(@{ op = 'test'; path = '/rev'; value = $rev })
  foreach ($t in @($targets))
  {
    $ops += @{
      op    = 'add'
      path  = '/relations/-'
      value = @{
        rel        = $script:PredecessorRel
        url        = (WorkItemApiUrl ([int]$t))
        attributes = @{ comment = "Agility dependency of $number." }
      }
    }
  }
  return $ops
}

# ADO reports a link that would close a cycle as HTTP 500 with TF201035. It is permanent, not
# transient, and it must cost only the one link.
function IsCircularLinkProblem($errorRecord)
{
  $text = "$($errorRecord.ErrorDetails.Message) $($errorRecord.Exception.Message)"
  return ($text -match 'TF201035' -or $text -match 'circular relationship')
}

# Writes one item's flipped links: one batched patch, and only when ADO refuses the batch as
# circular, one patch per link so the cyclic one is isolated and the rest land. Any other rejection
# (a failed revision test, a 4xx) is a failure to report, never something to retry link by link.
function AddFlippedLinks([int]$id, [int]$rev, $targets, [string]$number)
{
  $result = [pscustomobject]@{ Written = 0; Refused = @(); Failed = $false }
  $list = @($targets)
  if ($list.Count -eq 0) { return $result }

  try
  {
    InvokeAdoRequest (WorkItemUrl $script:config.AzureDevOps.Project $id) "Patch" @(BuildAddOps $id $rev $list $number) "application/json-patch+json" | Out-Null
    $result.Written = $list.Count
    return $result
  }
  catch
  {
    if (-not (IsCircularLinkProblem $_))
    {
      WriteLog "  FAIL    #$id ($number) links could not be written - $(ReadAdoError $_)" Red
      WriteErrorDetail $_ "write links from #$id"
      $result.Failed = $true
      return $result
    }
  }

  # The batch closed a cycle somewhere. Each link alone; the revision moves on with every success.
  $currentRev = $rev
  foreach ($t in $list)
  {
    try
    {
      $response = InvokeAdoRequest (WorkItemUrl $script:config.AzureDevOps.Project $id) "Patch" @(BuildAddOps $id $currentRev @($t) $number) "application/json-patch+json"
      if ($response -and $response.PSObject.Properties['rev'] -and $response.rev) { $currentRev = [int]$response.rev }
      $result.Written++
    }
    catch
    {
      if (IsCircularLinkProblem $_)
      {
        WriteLog "  WARN    #$id ($number) link to #$t was not written - it would close a dependency cycle, which Agility allows and Azure DevOps does not" Yellow
        $result.Refused += [int]$t
      }
      else
      {
        WriteLog "  FAIL    #$id ($number) link to #$t could not be written - $(ReadAdoError $_)" Red
        WriteErrorDetail $_ "write link #$id -> #$t"
        $result.Failed = $true
      }
    }
  }
  return $result
}

##################################################################################################
# Verify
##################################################################################################

# The new graph against the reversed inventory, link by link. Every old From>To must now exist as
# To>From; a link ADO refused as circular is expected to be absent; anything else present is extra;
# an old link still present is reported on its own so it is not mistaken for one missing plus one
# extra.
function VerifyFlip($old, $new, $refused)
{
  $expected = @{}
  foreach ($e in @($old | Where-Object { $_ })) { $expected["$([int]$e.To)>$([int]$e.From)"] = $true }
  $refusedKeys = @{}
  foreach ($e in @($refused | Where-Object { $_ })) { $refusedKeys["$([int]$e.From)>$([int]$e.To)"] = $true }
  $oldKeys = @{}
  foreach ($e in @($old | Where-Object { $_ })) { $oldKeys[(EdgeKey $e)] = $true }
  $newKeys = @{}
  foreach ($e in @($new | Where-Object { $_ })) { $newKeys[(EdgeKey $e)] = $true }

  $unflipped = @($newKeys.Keys | Where-Object { $oldKeys.ContainsKey($_) -and -not $expected.ContainsKey($_) } | Sort-Object)
  $extra     = @($newKeys.Keys | Where-Object { -not $expected.ContainsKey($_) -and -not $oldKeys.ContainsKey($_) } | Sort-Object)
  # An expected link is missing only when NEITHER orientation is present: one still the old way is
  # reported as unflipped above, not counted twice. A refused pair is expected to be absent.
  $missing   = @($expected.Keys | Where-Object { -not $newKeys.ContainsKey($_) } | Where-Object {
                 $parts = $_ -split '>'; $oldWay = "$($parts[1])>$($parts[0])"
                 -not $refusedKeys.ContainsKey($oldWay) -and -not $newKeys.ContainsKey($oldWay) } | Sort-Object)

  return [pscustomobject]@{
    Ok        = ($unflipped.Count -eq 0 -and $extra.Count -eq 0 -and $missing.Count -eq 0)
    Missing   = $missing
    Extra     = $extra
    Unflipped = $unflipped
    Refused   = @($refusedKeys.Keys | Sort-Object)
  }
}

# One message per touched item whose non-dependency relations differ as a SET before and after.
function CompareOtherRelations($before, $after)
{
  $messages = @()
  foreach ($id in ($before.Keys | Sort-Object))
  {
    $b = @($before[$id] | Sort-Object)
    $a = @($after[$id] | Sort-Object)
    if (($b -join "`n") -ne ($a -join "`n"))
    {
      $messages += "#$id non-dependency relations changed: before $($b.Count), after $($a.Count)"
    }
  }
  return $messages
}

##################################################################################################
# URLs
##################################################################################################

function WorkItemUrl([string]$project, [int]$id)
{
  return "{0}/{1}/_apis/wit/workitems/{2}?api-version=7.1" -f $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'), [uri]::EscapeDataString($project), $id
}

# One item with its relations, read on its own. The batch read is for the snapshot; this is for the
# moment before a patch, when the indexes have to be current.
function WorkItemReadUrl([string]$project, [int]$id)
{
  return "{0}/{1}/_apis/wit/workitems/{2}?`$expand=relations&api-version=7.1" -f $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'), [uri]::EscapeDataString($project), $id
}

# The url ADO expects inside a relation: org level, no project, no query string.
function WorkItemApiUrl([int]$id)
{
  return "{0}/_apis/wit/workItems/{1}" -f $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'), $id
}

##################################################################################################
# Logging
##################################################################################################

# One log per call, named for the moment it started. Never throws.
function StartLog
{
  StopLog

  try
  {
    if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Path $script:logDir -Force | Out-Null }

    $script:logPath = Join-Path $script:logDir ("Repair-DependencyDirection-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

    # AutoFlush so a crash, a throttling timeout, or a Ctrl-C still leaves a complete log.
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

# The one call the whole script uses for progress. A bare WriteLog is a blank spacer line.
function WriteLog([string]$message = "", [string]$color)
{
  if ($color) { Write-Host $message -ForegroundColor $color }
  else { Write-Host $message }

  AppendLog $message
}

# File only.
function WriteLogDetail([string]$message)
{
  AppendLog $message
}

function AppendLog([string]$message)
{
  if (-not $script:logWriter) { return }

  try { $script:logWriter.WriteLine($message) }
  catch
  {
    $script:logWriter = $null
    Write-Host "WARN    logging to $script:logPath stopped: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

# The console gets one readable line per failure; the log gets what is needed to diagnose it.
function WriteErrorDetail($errorRecord, [string]$context)
{
  if (-not $script:logWriter) { return }

  WriteLogDetail "          ---- error detail: $context ----"
  WriteLogDetail "          Exception: $($errorRecord.Exception.GetType().FullName)"
  WriteLogDetail "          Message:   $($errorRecord.Exception.Message)"

  $status = $errorRecord.Exception.Response.StatusCode.value__
  if ($status) { WriteLogDetail "          HTTP:      $status" }

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

# Resolves a secret from the environment first, then Windows Credential Manager.
#
# This is the one function with a param block rather than inline params, because a suppression
# attribute has to attach to one. The analyzer sees "credential" in the parameter name and assumes
# it holds a secret. It does not: it is the NAME of a credential in Windows Credential Manager.
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

function BuildAdoHeaders
{
  $pat = GetSecret "ADO_PAT" $script:config.AzureDevOps.CredentialTarget
  $basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":" + $pat))

  return @{ Authorization = "Basic $basicAuth" }
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

##################################################################################################
# Plumbing
##################################################################################################

$script:MaxRetryDelaySeconds = 120

# Is this failure worth trying again? No response at all (timeout, dropped connection) is
# transient. 429 and 5xx are transient, EXCEPT the circular link rejection, which ADO returns as a
# 500 and which is refused every time.
function IsTransientFailure($errorRecord)
{
  $response = $errorRecord.Exception.Response
  if (-not $response) { return -not (IsCircularLinkProblem $errorRecord) }

  $status = $response.StatusCode.value__
  if ($null -eq $status) { return $true }

  if (IsCircularLinkProblem $errorRecord) { return $false }

  return (($status -eq 429) -or ($status -ge 500 -and $status -le 599))
}

# How long to wait before the next attempt. Honours Retry-After, falls back to exponential backoff,
# never exceeds MaxRetryDelaySeconds, and survives a failure that has no Response at all.
function ResolveRetryDelay($errorRecord, [int]$attempt)
{
  $backoff = [int][Math]::Pow(2, $attempt)

  $response = $errorRecord.Exception.Response
  if (-not $response) { return [Math]::Min($backoff, $script:MaxRetryDelaySeconds) }

  $header = $response.Headers['Retry-After']
  if ($header -is [array]) { $header = @($header)[0] }

  if ($null -ne $header)
  {
    $seconds = 0
    if ([int]::TryParse("$header", [ref]$seconds) -and $seconds -gt 0)
    {
      return [Math]::Min($seconds, $script:MaxRetryDelaySeconds)
    }
  }

  return [Math]::Min($backoff, $script:MaxRetryDelaySeconds)
}

function InvokeWithRetry([scriptblock]$action, [int]$attempts = 3, [int]$fixedDelay = -1)
{
  for ($attempt = 1; $attempt -le $attempts; $attempt++)
  {
    try
    {
      return & $action
    }
    catch
    {
      if (-not (IsTransientFailure $_) -or $attempt -eq $attempts) { throw }

      $delay = if ($fixedDelay -ge 0) { $fixedDelay } else { ResolveRetryDelay $_ $attempt }
      $status = $_.Exception.Response.StatusCode.value__
      $what = if ($status) { "HTTP $status" } else { "no response ($($_.Exception.Message))" }
      WriteLog "  RETRY   $what, attempt $attempt of $attempts, waiting $delay seconds" DarkYellow
      if ($delay -gt 0) { Start-Sleep -Seconds $delay }
    }
  }
}

# The tests dot source this file to load the functions without touching anything, and set this
# flag first to say so. Explicit, and this script's own.
if ($global:RepairDependencyDirectionLoadFunctionsOnly)
{
  Write-Host "Functions loaded, Main skipped." -ForegroundColor DarkGray
}
else
{
  try     { Main }
  finally { StopLog }

  if ($script:totalFailed -gt 0) { exit 1 }
}
