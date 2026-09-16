##################################################################################################
# Script to create the Azure DevOps iteration nodes the migration needs, from Agility's timeboxes.
#
#   CreateIterations             CreateIterations -DryRun
#
# The migration writes every Story, Defect and Task that sits in an Agility Timebox to the iteration
# path "<Project>\<Timebox name>", and Azure DevOps REJECTS an unknown iteration path outright
# (TF401347), once per item. So the nodes have to exist before the migration runs. Nothing in the
# migration creates them - it only ever creates area nodes - and this script is where that lives.
#
# What it creates is DERIVED from the live Agility data, not a hard coded list: it walks every
# configured scope for the three types the migration reads a Timebox on, collects each distinct
# Timebox name with its begin and end dates, and creates a flat node for each one directly under
# the project root. The name goes across VERBATIM, because that is what the migration writes; one
# real timebox is spelled "Sprint  005" with two spaces, and a tidied node would fail every item
# on it.
#
# IDEMPOTENT. A node that already exists is left alone, whatever its dates, so this can be run and
# re-run and only ever adds what is missing. It never updates and never deletes. After creating, it
# reads every node back and checks the dates landed, because ADO accepts a date it cannot parse
# with HTTP 200 and simply drops it - only the full ISO 8601 form with a time part is kept.
#
# It is a SEPARATE script, self contained like Remove-WorkItems.ps1, for the same reason: it
# neither loads nor names the other scripts, its one door to Agility hard codes GET, and it has no
# way to touch a work item. Tests assert all of that, which is why the plumbing below is duplicated
# rather than factored into a shared file.
#
# Edit the call in Main to control what runs. Config is read from appsettings.json in this script's
# parent folder. Every call writes its own log to logs/Create-Iterations-<yyyyMMdd-HHmmss>.log.
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

  Write-Host "Create-Iterations starting" -ForegroundColor Cyan
  Write-Host

  # Futz with these. Creating is additive and idempotent, so the real call is safe to leave live;
  # the dry run lists what a run would add without adding it.
  #
  # CreateIterations -DryRun                              # list the nodes that are missing
  # CreateIterations -RepairDates -DryRun                 # also list existing nodes whose dates are wrong
  # CreateIterations -RepairDates                         # and correct them (the only thing that ever updates a node)
  #
  # Work items are created by Migrate-Agility.ps1 and removed by Remove-WorkItems.ps1, both of
  # which are air gapped from this script.

  CreateIterations
}

##################################################################################################
# Create
##################################################################################################

# The Agility types the migration reads Timebox.Name on. Story and Defect carry their own; Task's is
# inherited from its parent Story, and the migration writes it all the same. Epic and Issue have no
# Timebox. Walking any other type is wasted calls; missing one of these leaves sprints uncreated.
$script:TimeboxedAgilityTypes = @('Story', 'Defect', 'Task')

# Creates every iteration node the configured scopes need and does not yet have.
#
# -RepairDates is the one deliberate exception to "adds, never updates". The first version of this
# script copied Agility's EndDate verbatim, and that date is EXCLUSIVE (the Wednesday the next
# sprint starts), so all 142 nodes on the IT project finished a day late and overlapped. With the
# switch, a pre-existing node whose dates differ from Agility's is patched and read back; without
# it, the difference is only reported. Both are idempotent: a correct node is never touched.
function CreateIterations([switch]$DryRun, [switch]$RepairDates)
{
  $script:DryRun = [bool]$DryRun
  $created = 0
  $existing = 0
  $repaired = 0
  $failed = 0
  $createdNames = @{}

  StartLog
  $script:runStarted = Get-Date
  WriteLogDetail "CreateIterations log, started $($script:runStarted.ToString('yyyy-MM-dd HH:mm:ss'))"
  WriteLogDetail ""

  $script:config = GetConfig $script:configPath

  WriteLog "Creating iteration nodes in $($script:config.AzureDevOps.OrganizationUrl) project $($script:config.AzureDevOps.Project)"
  if ($script:DryRun) { WriteLog "DRY RUN - nothing will be written to Azure DevOps" Yellow }
  WriteLog

  WriteLog "Resolving credentials..."
  $script:agilityHeaders = BuildAgilityHeaders
  $script:adoHeaders = BuildAdoHeaders
  WriteLog

  $wanted = GetAgilityTimeboxes
  WriteLog "Found $($wanted.Count) distinct timeboxes in Agility across $(@($script:config.Agility.Scopes).Count) scopes"

  $have = GetAdoIterations
  WriteLog "Found $($have.Count) existing iteration nodes in Azure DevOps"
  WriteLog

  # Oldest first, so the log reads in sprint order and a partial run leaves a contiguous prefix.
  foreach ($name in ($wanted.Keys | Sort-Object { $wanted[$_].Begin }, { $_ }))
  {
    $tb = $wanted[$name]
    $label = "{0}  {1} -> {2}  ({3} items)" -f $name, $tb.Begin, (FinishDay $tb.End), $tb.Items

    # Case-insensitive, because ADO node names are. A node that exists is never touched, whatever
    # its dates: this script adds, it does not update.
    if ($have.ContainsKey($name.ToLowerInvariant()))
    {
      WriteLog "  EXISTS  $label"
      $existing++
      continue
    }

    if ($script:DryRun)
    {
      WriteLog "  WOULD   $label"
      $created++
      continue
    }

    try
    {
      InvokeAdoRequest (IterationNodesUrl) "Post" (BuildIterationBody $name $tb.Begin $tb.End) "application/json" | Out-Null
      WriteLog "  CREATED $label"
      $created++
      $createdNames[$name.ToLowerInvariant()] = $true
    }
    catch
    {
      WriteLog "  FAIL    $name could not be created - $(ReadAdoError $_)" Red
      WriteErrorDetail $_ "create iteration '$name'"
      $failed++
    }
  }

  # Read back and prove the dates landed. A create that silently dropped its dates is HTTP 200 and
  # indistinguishable from a good one until the node is read again. The dates have been seen not to
  # take on the create, so a node THIS RUN made is patched and read once more before it counts as a
  # failure. A node that was already there is never patched: this script adds, it does not update,
  # so a difference there is reported and left alone.
  #
  # On a dry run the read back is skipped, except with -RepairDates, where it is the only way to
  # list what a repair would touch (it is GET only). A node the dry run would have created is not
  # there to verify and is skipped.
  if (-not $script:DryRun -or $RepairDates)
  {
    WriteLog
    $after = GetAdoIterations
    foreach ($name in ($wanted.Keys | Sort-Object))
    {
      $key = $name.ToLowerInvariant()
      $node = $after[$key]
      if ($script:DryRun -and -not $node) { continue }

      $problem = VerifyIterationNode $node $wanted[$name]
      if (-not $problem) { continue }

      $preExisting = -not $createdNames.ContainsKey($key)

      if ($preExisting -and -not $RepairDates)
      {
        WriteLog "  WARN    $name existed before this run and $problem - left as is (rerun with -RepairDates to fix)" Yellow
        continue
      }

      if ($preExisting -and $script:DryRun)
      {
        WriteLog "  WOULD REPAIR  $name $problem" Yellow
        $repaired++
        continue
      }

      if ($node)
      {
        $verb = if ($preExisting) { "REPAIR " } else { "RETRY  " }
        WriteLog "  $verb $name $problem - patching the dates" DarkYellow
        try
        {
          $node = PatchIterationDates $name $wanted[$name]
          $problem = VerifyIterationNode $node $wanted[$name]
          if (-not $problem -and $preExisting) { $repaired++ }
        }
        catch
        {
          $problem = "the date patch failed - $(ReadAdoError $_)"
          WriteErrorDetail $_ "patch iteration '$name'"
        }
      }

      if ($problem)
      {
        WriteLog "  FAIL    $name read back wrong - $problem" Red
        $failed++
      }
    }
    WriteLog "Read back $($after.Count) iteration nodes"
  }

  WriteLog
  WriteLog "----------------------------------------"
  WriteLog "$(if ($script:DryRun) { 'Would create:' } else { 'Created:     ' }) $created"
  WriteLog "Existing:     $existing"
  if ($RepairDates) { WriteLog "$(if ($script:DryRun) { 'Would repair:' } else { 'Repaired:    ' }) $repaired" }
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

# Every distinct Timebox the configured scopes reference, keyed by name: Begin, End, and how many
# items carry it. One cheap walk per scope and type, selecting only the three Timebox attributes.
function GetAgilityTimeboxes
{
  $found = @{}
  $pageSize = 500

  foreach ($s in $script:config.Agility.Scopes)
  {
    foreach ($type in $script:TimeboxedAgilityTypes)
    {
      # Never an empty where clause: the Dead filter keeps Agility's placeholder templates out, the
      # same rail the migration keeps.
      $where = "Scope='$($s.Scope)';AssetState!='Dead'"
      $start = 0

      while ($true)
      {
        $url = "{0}/rest-1.v1/Data/{1}?sel=Timebox.Name,Timebox.BeginDate,Timebox.EndDate&where={2}&page={3},{4}" -f `
          $script:config.Agility.BaseUrl.TrimEnd('/'), $type, [uri]::EscapeDataString($where), $pageSize, $start

        $batch = @((InvokeAgilityGet $url).Assets | Where-Object { $_ })
        CollectTimeboxes $batch $found

        if ($batch.Count -lt $pageSize) { break }
        $start += $pageSize
      }

      WriteLog "  read $type in $($s.Scope): $($found.Count) timeboxes so far"
    }
  }

  return $found
}

# Folds one page of assets into the map. The name is kept verbatim; the first sighting supplies the
# dates and every sighting counts an item.
function CollectTimeboxes($assets, $found)
{
  foreach ($asset in @($assets | Where-Object { $_ }))
  {
    $attributes = $asset.Attributes
    if (-not $attributes) { continue }

    $name = $attributes.PSObject.Properties['Timebox.Name'].Value.value
    if (-not $name) { continue }

    if (-not $found.ContainsKey($name))
    {
      $found[$name] = @{
        Begin = "$($attributes.PSObject.Properties['Timebox.BeginDate'].Value.value)"
        End   = "$($attributes.PSObject.Properties['Timebox.EndDate'].Value.value)"
        Items = 0
      }
    }

    $found[$name].Items++
  }
}

# Every iteration node directly under the project root, keyed by lower cased name. Flat on purpose:
# the migration writes "<Project>\<Timebox>" and nothing deeper.
function GetAdoIterations
{
  $root = InvokeAdoRequest "$(IterationNodesUrl '$depth=2&')" "Get" $null $null
  $nodes = @{}

  if ($root.PSObject.Properties['children'] -and $root.children)
  {
    # @($null) is a one element array, so the null filter is not optional.
    foreach ($child in @($root.children | Where-Object { $_ }))
    {
      $nodes[$child.name.ToLowerInvariant()] = $child
    }
  }

  return $nodes
}

function IterationNodesUrl([string]$query = "")
{
  return "{0}/{1}/_apis/wit/classificationnodes/Iterations?{2}api-version=7.1" -f `
    $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'),
    [uri]::EscapeDataString($script:config.AzureDevOps.Project),
    $query
}

# One node by name, directly under the root. The name is escaped, so a double space survives.
function IterationNodeUrl([string]$name)
{
  return "{0}/{1}/_apis/wit/classificationnodes/Iterations/{2}?api-version=7.1" -f `
    $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'),
    [uri]::EscapeDataString($script:config.AzureDevOps.Project),
    [uri]::EscapeDataString($name)
}

# Applies the dates to a node this run created whose create call dropped them, then reads the node
# back and returns it. Only ever called for a node made in this run.
function PatchIterationDates([string]$name, $wanted)
{
  $body = @{ attributes = @{ startDate = (FormatIterationDate $wanted.Begin); finishDate = (FormatFinishDate $wanted.End) } }
  InvokeAdoRequest (IterationNodeUrl $name) "Patch" $body "application/json" | Out-Null

  return InvokeAdoRequest (IterationNodeUrl $name) "Get" $null $null
}

# The create payload. The attributes block is omitted entirely when there are no dates, so ADO is
# handed nothing it could reject or misread.
function BuildIterationBody([string]$name, [string]$begin, [string]$end)
{
  $body = @{ name = $name }

  $startDate = FormatIterationDate $begin
  $finishDate = FormatFinishDate $end
  if ($startDate -and $finishDate)
  {
    $body.attributes = @{ startDate = $startDate; finishDate = $finishDate }
  }

  return $body
}

# Full ISO 8601 with a time part, or nothing. A bare "yyyy-MM-dd" is silently dropped by ADO: the
# node is created, the response is 200, and it has no dates. Agility timebox dates are date only,
# so the day is taken as is and pinned to midnight UTC; the Z is quoted because in a .NET format
# string a bare Z is a literal, not a specifier.
function FormatIterationDate([string]$value)
{
  if (-not $value) { return $null }

  $parsed = [datetime]::MinValue
  if (-not [datetime]::TryParse($value, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed))
  {
    return $null
  }

  return $parsed.ToString("yyyy-MM-dd'T'00:00:00'Z'")
}

# The finish date ADO gets: the day BEFORE Agility's EndDate. Agility's end is exclusive - on the
# CWI - 3 weeks schedule every one of the 142 timeboxes ends on the Wednesday the next one begins -
# while ADO's finish date is inclusive. Copying it verbatim made every sprint overlap its successor
# by a day (all 141 consecutive pairs on IT, 2026-09-16). So a Wednesday end is a Tuesday finish.
function FormatFinishDate([string]$end)
{
  if (-not $end) { return $null }

  $iso = FormatIterationDate $end
  if (-not $iso) { return $null }

  $parsed = [datetime]::ParseExact($iso.Substring(0, 10), 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
  return $parsed.AddDays(-1).ToString("yyyy-MM-dd'T'00:00:00'Z'")
}

# The finish day as yyyy-MM-dd, for log lines, or Agility's raw value when it cannot be parsed.
function FinishDay([string]$end)
{
  $iso = FormatFinishDate $end
  if ($iso) { return $iso.Substring(0, 10) }
  return $end
}

# Why a node read back is wrong, or $null when it is right. Right means: present, and both dates
# start with the day Agility has. An Agility timebox with no dates expects none.
function VerifyIterationNode($node, $wanted)
{
  if (-not $node) { return "missing" }

  $expectedStart = FormatIterationDate $wanted.Begin
  $expectedFinish = FormatFinishDate $wanted.End
  if (-not $expectedStart -or -not $expectedFinish) { return $null }

  # Compared as DAYS, never as strings. Invoke-RestMethod hands the response's ISO date back as a
  # DateTime, and stringifying that gives the local culture's "11/21/2018 00:00:00", which no ISO
  # prefix will ever match: the first live run read all 142 correct nodes back as wrong that way.
  $start = ReadDay $node.attributes.startDate
  $finish = ReadDay $node.attributes.finishDate

  if ($start -ne $expectedStart.Substring(0, 10) -or $finish -ne $expectedFinish.Substring(0, 10))
  {
    return "dates are '$start' -> '$finish', expected $($wanted.Begin) -> $(FinishDay $wanted.End)"
  }

  return $null
}

# The yyyy-MM-dd day of a date as it came back from Azure DevOps, whether it arrived as a DateTime
# or as an ISO string, or an empty string when there is none. A UTC or local Kind is converted to
# UTC first; the dates were written at midnight UTC, so that is the day that means anything.
function ReadDay($value)
{
  if ($null -eq $value -or "$value" -eq "") { return "" }

  $parsed = [datetime]::MinValue
  if ($value -is [datetime]) { $parsed = $value }
  elseif (-not [datetime]::TryParse("$value", [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed))
  {
    return "$value"
  }

  if ($parsed.Kind -eq [DateTimeKind]::Local) { $parsed = $parsed.ToUniversalTime() }

  return $parsed.ToString('yyyy-MM-dd')
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

    $script:logPath = Join-Path $script:logDir ("Create-Iterations-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

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

##################################################################################################
# Agility (read only)
##################################################################################################

# The ONLY door to Agility, and it hard codes GET. There is no method parameter, and no other call
# in this script reaches Agility. A test asserts both. Do not add one.
function InvokeAgilityGet([string]$url)
{
  return InvokeWithRetry {
    Invoke-RestMethod -Uri $url -Method Get -Headers $script:agilityHeaders -ErrorAction Stop
  }
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
# never exceeds MaxRetryDelaySeconds.
function ResolveRetryDelay($errorRecord, [int]$attempt)
{
  $backoff = [int][Math]::Pow(2, $attempt)

  # A transport failure (timeout, dropped connection) has NO Response, and indexing into its Headers
  # threw "Cannot index into a null array" on the way to the retry - the very failure the retry was
  # hardened to survive. Found the hard way: it cost TK-141237 on the 2026-09-15 run.
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

# The tests dot source this file to load the functions without creating anything, and set this flag
# first to say so. Explicit, and this script's own: VS Code's F5 dot sources the file exactly like
# the tests do, so $MyInvocation cannot tell a test run from a real one.
if ($global:CreateIterationsLoadFunctionsOnly)
{
  Write-Host "Functions loaded, Main skipped." -ForegroundColor DarkGray
}
else
{
  # finally, not a plain call: an exception on the way out of Main must still release the log handle.
  try     { Main }
  finally { StopLog }

  # Non zero if any node failed to create or read back wrong.
  if ($script:totalFailed -gt 0) { exit 1 }
}
