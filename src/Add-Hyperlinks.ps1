##################################################################################################
# Script to add a hyperlink on a migrated Azure DevOps work item that opens its source record in
# digital.ai Agility.
#
#   AddHyperlinks -Project 'Training' -Ids 321956, 355420 -DryRun
#   AddHyperlinks -Project 'Training' -Ids 321956, 355420
#   AddHyperlinks -Project 'Training' -All
#
# Every migrated item carries its Agility Number (S-40245, TK-141988, E-09415, D-02525, I-01687) in
# Custom.DigitalAIID, and Agility resolves a Number on its own:
#
#   <Agility BaseUrl>/assetdetail.v1?Number=S-40245
#
# redirects to the right page for the asset whatever its type (story.mvc, Task.mvc, Epic.mvc,
# defect.mvc, Issue.mvc), and is a 404 for a Number that does not exist. Verified live 2026-09-17 on
# all five Agility types. So the link is BUILT from what is already on the work item, and this
# script never calls Agility at all: it has no token for it and no door to it.
#
# The link is a Hyperlink relation, which is what the Links tab shows, with the Number as its
# comment. Whoever follows it needs their own Agility login; the link carries no credential.
#
# IDEMPOTENT. An item that already carries the link is reported EXISTS and left alone, so this can
# be run and re-run. It only ever ADDS one relation: it removes nothing, edits no field, and every
# patch is checked against the item as it was read - the link must be there, every relation that
# was there before must still be there, and nothing else may have appeared.
#
# An item with no Custom.DigitalAIID was not migrated and is skipped. -Project is required and
# never defaults to the configured one, and an item that turns out to live in another project is
# refused rather than linked.
#
# The patch is rule checked (no bypassRules) and carries no ChangedDate, so it adds one revision
# dated the day it runs, the same way the migration note does.
#
# It is a SEPARATE, self contained script, like Remove-WorkItems.ps1 and Create-Iterations.ps1: it
# neither loads nor names the other scripts, it never deletes anything, and the only path it ever
# patches is /relations. Tests assert all of that, which is why the plumbing below is duplicated
# rather than factored into a shared file.
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

  Write-Host "Add-Hyperlinks starting" -ForegroundColor Cyan
  Write-Host

  # Futz with these. The live line is a dry run and should stay one until you mean it.
  #
  # AddHyperlinks -Project 'Training' -Ids 321956, 355420, 316278, 316770, 325315, 370095    # the six samples, for real
  # AddHyperlinks -Project 'Training' -All -DryRun                                           # every migrated item in the project
  # AddHyperlinks -Project 'Training' -All
  #
  # Work items are created by Migrate-Agility.ps1 and removed by Remove-WorkItems.ps1, both of
  # which are air gapped from this script.

  AddHyperlinks -Project 'Training' -Ids 321956, 355420, 316278, 316770, 325315, 370095 -DryRun
}

##################################################################################################
# Add
##################################################################################################

$script:HyperlinkRel = 'Hyperlink'

# The ADO field holding the Agility Number. It is what the migration's own idempotency runs on.
$script:AgilityNumberField = 'Custom.DigitalAIID'

# Adds the link back to Agility on the given items, or with -All on every migrated item in the
# project. One of the two is required: nothing here defaults to a whole project.
function AddHyperlinks([string]$Project, [int[]]$Ids, [switch]$All, [switch]$DryRun)
{
  $script:DryRun = [bool]$DryRun
  $added = 0
  $existing = 0
  $skipped = 0
  $failed = 0

  StartLog
  $script:runStarted = Get-Date
  WriteLogDetail "AddHyperlinks '$Project' log, started $($script:runStarted.ToString('yyyy-MM-dd HH:mm:ss'))"
  WriteLogDetail ""

  $script:config = GetConfig $script:configPath

  if (-not $Project) { throw "A -Project is required; this never defaults to the configured project." }
  # An unset -Ids is $null, and @($null) is a one element array, so the nulls are filtered first.
  $targets = @($Ids | Where-Object { $_ })
  if (-not $All -and $targets.Count -eq 0) { throw "Pass -Ids, or -All for every migrated item in the project." }
  if ($All -and $targets.Count -gt 0) { throw "Pass -Ids or -All, not both." }

  WriteLog "Adding Agility hyperlinks in $($script:config.AzureDevOps.OrganizationUrl) project $Project"
  WriteLog "Links point at $((BuildAgilityUrl 'NUMBER') -replace 'NUMBER$', '<Number>')"
  if ($script:DryRun) { WriteLog "DRY RUN - nothing will be written to Azure DevOps" Yellow }
  WriteLog

  WriteLog "Resolving credentials..."
  $script:adoHeaders = BuildAdoHeaders
  WriteLog

  if ($All)
  {
    $targets = @(GetAllWorkItemIds $Project)
    WriteLog "Found $($targets.Count) work items in $Project"
    WriteLog
  }

  # 200 at a time, which is the most one batch read takes. Each chunk is read and then patched
  # before the next is read, so an item is never patched against a read older than its chunk.
  for ($i = 0; $i -lt $targets.Count; $i += 200)
  {
    $chunk = @($targets[$i..([Math]::Min($i + 199, $targets.Count - 1))])
    $items = ReadItemsWithRelations $Project $chunk

    foreach ($id in $chunk)
    {
      $r = AddHyperlink $Project $id $items[[int]$id]

      switch ($r.Status)
      {
        'Added'   { WriteLog "  $(if ($script:DryRun) { 'WOULD  ' } else { 'ADDED  ' }) $($r.Label)"; $added++ }
        'Exists'  { WriteLog "  EXISTS  $($r.Label)"; $existing++ }
        'Skipped' { if (-not $All) { WriteLog "  SKIP    $($r.Label)" DarkYellow }; $skipped++ }
        default   { WriteLog "  FAIL    $($r.Label)" Red; $failed++ }
      }
    }
  }

  WriteLog
  WriteLog "----------------------------------------"
  WriteLog "Project:      $Project"
  WriteLog "$(if ($script:DryRun) { 'Would add:   ' } else { 'Added:       ' }) $added"
  WriteLog "Existing:     $existing"
  WriteLog "Skipped:      $skipped  (not migrated from Agility)"
  WriteLog "Failed:       $failed"
  WriteLog "----------------------------------------"
  if ($script:logPath)
  {
    $elapsed = (Get-Date) - $script:runStarted
    WriteLog "Log: $script:logPath" Cyan
    WriteLogDetail "Finished $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) after $([Math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
  }

  # Totalled rather than exited on; the bottom of the script turns the total into an exit code.
  $script:totalFailed += $failed
}

# One item: decide, patch, and check the result. Returns Status (Added, Exists, Skipped, Failed) and
# the Label to log. On a dry run Added means "would add" and nothing is sent.
function AddHyperlink([string]$project, [int]$id, $item)
{
  if (-not $item) { return (LinkResult 'Failed' "#$id was not found") }

  $type = "$($item.fields.'System.WorkItemType')"
  $number = "$($item.fields.($script:AgilityNumberField))".Trim()
  $label = "#$id $type $number".TrimEnd()

  # Asked for by id, so it could be anywhere in the org. Only ever link inside the named project.
  $itemProject = "$($item.fields.'System.TeamProject')"
  if ($itemProject -ne $project) { return (LinkResult 'Failed' "$label is in project '$itemProject', not '$project' - left alone") }

  if (-not $number) { return (LinkResult 'Skipped' "$label has no $script:AgilityNumberField, so it did not come from Agility") }
  if (-not (IsAgilityNumber $number)) { return (LinkResult 'Failed' "$label - '$number' is not an Agility Number, no link built") }

  $url = BuildAgilityUrl $number
  $label = "$label -> $url"

  if (HasHyperlink $item $url) { return (LinkResult 'Exists' $label) }
  if ($script:DryRun) { return (LinkResult 'Added' $label) }

  try
  {
    $response = InvokeAdoRequest (WorkItemUrl $project $id) "Patch" @(BuildAddHyperlinkOps $item $url $number) "application/json-patch+json"
  }
  catch
  {
    WriteErrorDetail $_ "add hyperlink to #$id"
    return (LinkResult 'Failed' "$label - $(ReadAdoError $_)")
  }

  # A 200 is not evidence. The response is the item after the patch, so it is checked against the
  # item as it was read.
  $problem = VerifyHyperlinkAdded $item $response $url
  if ($problem) { return (LinkResult 'Failed' "$label - patched, but $problem") }

  return (LinkResult 'Added' $label)
}

function LinkResult([string]$status, [string]$label)
{
  return [pscustomobject]@{ Status = $status; Label = $label }
}

# The page in Agility for one Number. assetdetail.v1 resolves the Number itself and redirects to the
# right page for the asset's type, so neither the type nor the oid is needed to build it.
function BuildAgilityUrl([string]$number)
{
  return "{0}/assetdetail.v1?Number={1}" -f $script:config.Agility.BaseUrl.TrimEnd('/'), [uri]::EscapeDataString($number)
}

# Letters, a hyphen, digits: E-09415, S-40245, D-02525, TK-141988, I-01687. Anything else in the
# field is not something to build a link from.
function IsAgilityNumber([string]$number)
{
  return ($number -cmatch '^[A-Z]{1,3}-\d+$')
}

# Whether the item already carries a hyperlink to this url. Compared without case, because a url
# that differs only by case is the same link to a person and must not be added twice.
function HasHyperlink($item, [string]$url)
{
  return (@(HyperlinksTo $item.relations $url).Count -gt 0)
}

# @($null) is a one element array, so the null filter is not optional on an item with no relations.
function HyperlinksTo($relations, [string]$url)
{
  return @(@($relations) | Where-Object { $_ -and $_.rel -eq $script:HyperlinkRel -and [string]::Equals("$($_.url)", $url, [StringComparison]::OrdinalIgnoreCase) })
}

# The patch for one item: a test on its revision, so it cannot land on an item somebody changed
# since it was read, then the one relation appended. The comment is what the Links tab shows.
function BuildAddHyperlinkOps($item, [string]$url, [string]$number)
{
  return @(
    @{ op = "test"; path = "/rev"; value = [int]$item.rev },
    @{
      op    = "add"
      path  = "/relations/-"
      value = @{ rel = $script:HyperlinkRel; url = $url; attributes = @{ comment = "digital.ai Agility $number" } }
    }
  )
}

# "rel|url" for every relation, compared as a set before and after.
function RelationKeys($relations)
{
  return @(@($relations) | Where-Object { $_ -and $_.rel } | ForEach-Object { "$($_.rel)|$($_.url)" })
}

# Why the item after the patch is wrong, or $null when it is right. Right means: the link is there
# exactly once, every relation that was there before is still there, and the only new one is ours.
function VerifyHyperlinkAdded($before, $after, [string]$url)
{
  $links = @(HyperlinksTo $after.relations $url).Count
  if ($links -ne 1) { return "the item carries $links hyperlinks to $url, expected 1" }

  $was = @(RelationKeys $before.relations)
  $now = @(RelationKeys $after.relations)

  $lost = @($was | Where-Object { $now -notcontains $_ })
  if ($lost.Count -gt 0) { return "a relation that was there before is gone: $($lost -join ', ')" }

  if ($now.Count -ne $was.Count + 1) { return "it has $($now.Count) relations, expected $($was.Count + 1)" }

  return $null
}

# Every work item id in the project. Paged on a System.Id watermark: WIQL caps a flat query at
# 20,000 rows and FAILS it with VS402337 rather than truncating, and a migrated project holds over
# 54,000. $top goes on the query string, not in the body. No filter on the Agility Number here: an
# item without one is skipped on the client, where an empty field cannot be misread.
function GetAllWorkItemIds([string]$project, [int]$wiqlPageSize = 19000)
{
  $all = @()
  $lastId = 0

  while ($true)
  {
    $wiql = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$project' AND [System.Id] > $lastId ORDER BY [System.Id]" }
    $url = "{0}/{1}/_apis/wit/wiql?`$top={2}&api-version=7.1" -f $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'), [uri]::EscapeDataString($project), $wiqlPageSize

    $response = InvokeAdoRequest $url "Post" $wiql "application/json"
    $ids = @($response.workItems | Where-Object { $_ } | ForEach-Object { [int]$_.id })
    if ($ids.Count -eq 0) { break }

    $all += $ids

    # ORDER BY means the last id is the highest, so it is the next watermark.
    $lastId = $ids[-1]
    if ($ids.Count -lt $wiqlPageSize) { break }
  }

  return $all
}

# Up to 200 items with their relations, keyed by id. $expand cannot be combined with a field list,
# so every field comes back, which is where the Agility Number is read from. errorPolicy Omit makes
# an id that does not exist come back as a null rather than failing the other 199.
function ReadItemsWithRelations([string]$project, $ids)
{
  $items = @{}
  $url = "{0}/{1}/_apis/wit/workitemsbatch?api-version=7.1" -f $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'), [uri]::EscapeDataString($project)
  $response = InvokeAdoRequest $url "Post" @{ ids = @($ids | ForEach-Object { [int]$_ }); '$expand' = 'relations'; errorPolicy = 'Omit' } "application/json"

  foreach ($wi in @($response.value | Where-Object { $_ })) { $items[[int]$wi.id] = $wi }

  return $items
}

function WorkItemUrl([string]$project, [int]$id)
{
  return "{0}/{1}/_apis/wit/workitems/{2}?`$expand=relations&api-version=7.1" -f $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'), [uri]::EscapeDataString($project), $id
}

##################################################################################################
# Logging
##################################################################################################

# One log per call, named for the moment it started. Never throws: a run that cannot open its log
# is still a run worth making, so this warns and carries on with the console only.
function StartLog
{
  StopLog

  try
  {
    if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Path $script:logDir -Force | Out-Null }

    $script:logPath = Join-Path $script:logDir ("Add-Hyperlinks-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

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

# The one call the whole script uses for progress. A bare WriteLog is a blank spacer line. Nothing
# in a run may call Write-Host directly, or the console and the log drift apart.
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

  # A logging fault must never take down a run that is otherwise succeeding.
  try { $script:logWriter.WriteLine($message) }
  catch
  {
    $script:logWriter = $null
    Write-Host "WARN    logging to $script:logPath stopped: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

# The console gets one readable line per failure; the log gets what is needed to diagnose it once
# the run is over and the error record is gone.
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

# Resolves a secret from the environment first, then Windows Credential Manager. The environment
# wins so a pipeline can inject the token without a credential store being present.
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

# Longest this will ever sleep on one attempt.
$script:MaxRetryDelaySeconds = 120

# Is this failure worth trying again? A failure with NO response (socket timeout, dropped
# connection) has no status to read and is treated as transient, not permanent.
function IsTransientFailure($errorRecord)
{
  $response = $errorRecord.Exception.Response
  if (-not $response) { return $true }

  $status = $response.StatusCode.value__
  if ($null -eq $status) { return $true }

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

# Retries transient failures with backoff. Anything permanent fails immediately. $fixedDelay is for
# tests only: 0 makes the retries instant.
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

# The tests dot source this file to load the functions without touching anything, and set this flag
# first to say so. Explicit, and this script's own: VS Code's F5 dot sources the file exactly like
# the tests do, so $MyInvocation cannot tell a test run from a real one.
if ($global:AddHyperlinksLoadFunctionsOnly)
{
  Write-Host "Functions loaded, Main skipped." -ForegroundColor DarkGray
}
else
{
  # finally, not a plain call: an exception on the way out of Main must still release the log handle.
  try     { Main }
  finally { StopLog }

  # Non zero if any link failed to add or read back wrong.
  if ($script:totalFailed -gt 0) { exit 1 }
}
