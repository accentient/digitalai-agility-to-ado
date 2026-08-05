##################################################################################################
# Script to PERMANENTLY delete work items from Azure DevOps, one work item type at a time.
#
#   DeleteAllEpics                DeleteAllProductBacklogItems     DeleteAllTasks
#   DeleteAllFeatures             DeleteAllBugs                    DeleteAllImpediments
#
# This exists to make a broken migration run redoable. A work item that failed part way through is
# still IN Azure DevOps - created, then a later patch failed - so the migration counts it FAIL and
# then SKIPS it forever on a rerun, leaving it broken. Removing the type makes the rerun re-create
# it properly.
#
# It is a SEPARATE script from the migration on purpose. The migration only ever creates and
# updates; this only ever destroys. Neither script loads, names or shares code with the other, so
# no edit to one can change what the other does. That air gap is the point, and tests assert it,
# which is why the plumbing below is duplicated rather than factored into a shared file.
#
# Two things to know before running it:
#
#   destroy=true is PERMANENT. Items do not go to the recycle bin and cannot be recovered. That is
#   deliberate: a clean slate for 40,000+ Tasks would otherwise flood the bin. Always -DryRun first.
#
#   Deleting a type ORPHANS whatever hangs off it. Features hang off Epics; PBIs and Bugs off Epics;
#   Tasks off PBIs and Bugs. The parent link is only ever written when a child is CREATED, so a
#   surviving child is never re-linked to a re-created parent. Delete in reverse dependency order -
#   Impediment, Task, Bug, PBI, Feature, Epic - and re-migrate everything below whatever you removed.
#
# Edit the calls in Main to control what runs. Config is read from appsettings.json in this
# script's parent folder. Every call writes its own log to logs/Remove-WorkItems-<yyyyMMdd-HHmmss>.log.
##################################################################################################

$script:configPath = Join-Path $PSScriptRoot ".." "appsettings.json"
# Resolved rather than left as src\..\logs: this is the one path the operator has to find again
# after a run, so it gets printed, and a printed path should be one they can paste.
$script:logDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".." "logs"))
$script:logPath = $null
$script:logWriter = $null
$script:totalFailed = 0

function Main
{
  # clear-host throws when the host has no console handle, as in CI or any redirected run.
  try { clear-host } catch { }

  Write-Host "Remove-WorkItems starting" -ForegroundColor Cyan
  Write-Host

  # Futz with these. Every delete is PERMANENT, so the uncommented line below is a -DryRun and
  # should stay one until the moment you mean it.
  #
  # Delete in reverse dependency order and re-migrate the children of whatever you remove.
  #
  # DeleteAllImpediments -DryRun                          # count; then drop -DryRun to delete
  # DeleteAllTasks -DryRun
  # DeleteAllBugs -DryRun
  # DeleteAllProductBacklogItems -DryRun
  # DeleteAllFeatures -DryRun
  # DeleteAllEpics -DryRun
  #
  # DeleteAllTasks                                        # the real thing, ~44,000 items, no undo
  #
  # Creating work items lives in Migrate-Agility.ps1, which is air gapped from this script.

  DeleteAllTasks -DryRun
}

##################################################################################################
# Delete
##################################################################################################

# The ADO work item types these helpers are allowed to delete. An unrecognised name throws rather
# than running a query whose type clause matches nothing (or, one careless edit later, everything).
# This is the same rail as the migration side's Agility AssetState filter: the danger is the filter
# going missing, and these destroy permanently.
$script:DeletableAdoTypes = @('Epic', 'Feature', 'Product Backlog Item', 'Bug', 'Task', 'Impediment')

function DeleteAllEpics([switch]$DryRun)               { DeleteAllOfType 'Epic'                 -DryRun:$DryRun }
function DeleteAllFeatures([switch]$DryRun)            { DeleteAllOfType 'Feature'              -DryRun:$DryRun }
function DeleteAllProductBacklogItems([switch]$DryRun) { DeleteAllOfType 'Product Backlog Item' -DryRun:$DryRun }
function DeleteAllBugs([switch]$DryRun)                { DeleteAllOfType 'Bug'                  -DryRun:$DryRun }
function DeleteAllTasks([switch]$DryRun)               { DeleteAllOfType 'Task'                 -DryRun:$DryRun }
function DeleteAllImpediments([switch]$DryRun)         { DeleteAllOfType 'Impediment'           -DryRun:$DryRun }

# Deletes every work item of ONE type in the project. The named wrappers above are the intended entry
# points; this takes the type so the delete loop exists once rather than six times.
function DeleteAllOfType([string]$adoType, [switch]$DryRun)
{
  if ($script:DeletableAdoTypes -notcontains $adoType)
  {
    throw "'$adoType' is not a work item type this can delete. Use one of: $($script:DeletableAdoTypes -join ', ')."
  }

  $script:DryRun = [bool]$DryRun
  $deleted = 0
  $failed = 0

  StartLog
  $script:runStarted = Get-Date
  WriteLogDetail "DeleteAllOfType '$adoType' log, started $($script:runStarted.ToString('yyyy-MM-dd HH:mm:ss'))"
  WriteLogDetail ""

  $script:config = GetConfig $script:configPath

  WriteLog "Deleting ALL $adoType work items in $($script:config.AzureDevOps.OrganizationUrl) project $($script:config.AzureDevOps.Project)"
  if ($script:DryRun) { WriteLog "DRY RUN - nothing will be deleted" Yellow }
  else { WriteLog "PERMANENT (destroy=true): these $adoType items CANNOT be recovered from the recycle bin" Red }
  WriteLog

  WriteLog "Resolving credentials..."
  $script:adoHeaders = BuildAdoHeaders
  WriteLog

  $org = $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/')
  $ids = GetAllIdsOfType $adoType
  WriteLog "Found $($ids.Count) $adoType work items"
  WriteLog

  if ($script:DryRun)
  {
    WriteLog "  WOULD delete $($ids.Count) $adoType items (destroy, permanent). First ids: $((@($ids) | Select-Object -First 10) -join ', ')"
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
        WriteErrorDetail $_ "delete $adoType #$id"
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

  # Totalled rather than exited on, so Main can call this more than once. The bottom of the script
  # turns the total into an exit code.
  $script:totalFailed += $failed
}

# Every id of one type in the project, walked with a System.Id watermark so it survives past the
# 20,000 row WIQL cap. $top keeps each query small and steady. The type is quoted into the WHERE
# clause; a name with spaces ('Product Backlog Item') needs no escaping beyond the single quotes
# WIQL already uses.
#
# WIQL has no OFFSET and no paging of its own, and it does not truncate: a flat query past 20,000
# rows fails outright with VS402337. A watermark rather than an offset, so the walk stays correct
# even if items are created while it runs.
function GetAllIdsOfType([string]$adoType)
{
  $org = $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/')
  $project = $script:config.AzureDevOps.Project
  $pageSize = 1000
  $ids = @()
  $lastId = 0

  while ($true)
  {
    $wiql = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$project' AND [System.WorkItemType] = '$adoType' AND [System.Id] > $lastId ORDER BY [System.Id]" }
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

##################################################################################################
# Logging
##################################################################################################

# One log per delete call, named for the moment it started. Never throws: a run that cannot open its
# log is still a run worth making, so this warns and carries on with the console only.
function StartLog
{
  StopLog

  try
  {
    if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Path $script:logDir -Force | Out-Null }

    $script:logPath = Join-Path $script:logDir ("Remove-WorkItems-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

    # AutoFlush so a crash, a throttling timeout, or a Ctrl-C still leaves a complete log. A log
    # that only survives a clean finish is missing exactly when it is wanted - and here it is the
    # only record of which ids were destroyed.
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

# File only. For detail that belongs in the record but would drown a console printing 40,000 items.
function WriteLogDetail([string]$message)
{
  AppendLog $message
}

function AppendLog([string]$message)
{
  if (-not $script:logWriter) { return }

  # A logging fault must never take down a run that is otherwise succeeding. Drop the writer and say
  # so once, rather than throwing on every subsequent line.
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
# such as "ADO-YourOrg-PAT". The secret itself never lands in a parameter, it comes back from
# Get-StoredCredential as a SecureString below.
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

# Longest this will ever sleep on one attempt. A server can send an absurd Retry-After and a run
# must not stall for an hour on a single call.
$script:MaxRetryDelaySeconds = 120

# Is this failure worth trying again?
#
# A failure with NO response is the important case. A socket timeout, a dropped connection or a DNS
# blip produces an error record with no Response at all, so reading .StatusCode gives $null, which
# compares false against every status. Treating that as permanent gave up WITHOUT A SINGLE RETRY,
# and it is exactly the kind of failure a run of tens of thousands of calls actually hits.
function IsTransientFailure($errorRecord)
{
  $response = $errorRecord.Exception.Response
  if (-not $response) { return $true }

  $status = $response.StatusCode.value__
  if ($null -eq $status) { return $true }

  return (($status -eq 429) -or ($status -ge 500 -and $status -le 599))
}

# How long to wait before the next attempt. ADO sends Retry-After on a 429 saying exactly how long
# it wants; guessing shorter just earns another 429. Falls back to exponential backoff when there is
# no usable header, and never exceeds MaxRetryDelaySeconds.
function ResolveRetryDelay($errorRecord, [int]$attempt)
{
  $backoff = [int][Math]::Pow(2, $attempt)

  $header = $errorRecord.Exception.Response.Headers['Retry-After']
  # Headers commonly arrive as a single element collection rather than a bare value.
  if ($header -is [array]) { $header = @($header)[0] }

  if ($null -ne $header)
  {
    $seconds = 0
    # Retry-After may also be an HTTP date, which we do not attempt to parse; the backoff covers it.
    if ([int]::TryParse("$header", [ref]$seconds) -and $seconds -gt 0)
    {
      return [Math]::Min($seconds, $script:MaxRetryDelaySeconds)
    }
  }

  return [Math]::Min($backoff, $script:MaxRetryDelaySeconds)
}

# Retries transient failures with backoff. Anything permanent fails immediately, because retrying a
# 400 or a 401 just wastes time. $fixedDelay is for tests only: 0 makes the retries instant.
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

# The tests dot source this file to load the functions without deleting anything, and set this flag
# first to say so.
#
# The flag has to be explicit, and it has to be this script's own. VS Code's F5 dot sources the file
# exactly like the tests do, so $MyInvocation.InvocationName cannot tell a test run from a real one;
# keying off it made F5 print nothing at all.
if ($global:RemoveWorkItemsLoadFunctionsOnly)
{
  Write-Host "Functions loaded, Main skipped." -ForegroundColor DarkGray
}
else
{
  # finally, not a plain call: an exception on the way out of Main must still release the log
  # handle. AutoFlush means the content is already safe either way, so this is about the handle.
  try     { Main }
  finally { StopLog }

  # Non zero if any item failed to delete, across every call Main made.
  if ($script:totalFailed -gt 0) { exit 1 }
}
