##################################################################################################
# Tests for the delete script.
#
# Two things are under test here. The first is that a delete removes exactly one work item type and
# nothing else: these deletes are destroy=true, so a filter that goes missing is not a bug anyone
# gets to fix afterwards. The second is the air gap itself - that this script and the migration
# script cannot reach each other - which is invisible from the outside and so is asserted against
# the source text.
#
# Every test is hermetic. Nothing here resolves a credential, queries the live project, or writes a
# log file.
##################################################################################################

BeforeAll {
  $script:scriptPath  = Join-Path $PSScriptRoot ".." "src" "Remove-WorkItems.ps1"
  $script:migratePath = Join-Path $PSScriptRoot ".." "src" "Migrate-Agility.ps1"

  # Load the functions without deleting anything. This must be explicit: VS Code's F5 also dot
  # sources the script, so the script cannot infer a test run from how it was invoked.
  $global:RemoveWorkItemsLoadFunctionsOnly = $true
  . $script:scriptPath

  # Source lines with whole line comments dropped, for the air gap assertions. A cross reference in
  # a banner or a menu comment is documentation and is allowed; what must not exist is code that
  # names or loads the other script.
  function CodeLines([string]$path)
  {
    return @(Get-Content $path | Where-Object { $_ -notmatch '^\s*#' })
  }
}

Describe "Delete helpers: remove ONLY one type, so it can be re-migrated" {

  BeforeAll {
    $script:testConfig = [pscustomobject]@{
      AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/contoso"; Project = "Migration" }
    }
    $script:config = $script:testConfig

    # The query each wrapper actually sends, with nothing deleted.
    function QueryOf([scriptblock]$call)
    {
      $script:queries = @()
      Mock InvokeAdoRequest { $script:queries += $body.query; return [pscustomobject]@{ workItems = @() } }
      & $call
      return $script:queries[0]
    }
  }

  # These call the real entry points, which read config, resolve credentials and open a log. Stub all
  # three: a unit test must not touch the credential store, the live instance, or the logs directory.
  BeforeEach {
    Mock GetConfig       { return $script:testConfig }
    Mock BuildAdoHeaders { return @{ Authorization = "Basic test" } }
    Mock StartLog        { }
    Mock WriteLog        { }
    Mock WriteLogDetail  { }
  }

  It "sends a work item type filter for every wrapper, and the right one" {
    $expected = @{
      'DeleteAllEpics'               = 'Epic'
      'DeleteAllFeatures'            = 'Feature'
      'DeleteAllProductBacklogItems' = 'Product Backlog Item'
      'DeleteAllBugs'                = 'Bug'
      'DeleteAllTasks'               = 'Task'
      'DeleteAllImpediments'         = 'Impediment'
    }

    foreach ($fn in $expected.Keys)
    {
      $query = QueryOf ([scriptblock]::Create("$fn -DryRun"))

      $query | Should -Match ([regex]::Escape("[System.WorkItemType] = '$($expected[$fn])'")) `
        -Because "$fn must delete only $($expected[$fn])"
    }
  }

  # A wrapper must never match a type that is not its own.
  It "never matches another type" {
    (QueryOf { DeleteAllEpics -DryRun })    | Should -Not -Match "'Feature'"
    (QueryOf { DeleteAllFeatures -DryRun }) | Should -Not -Match "'Epic'"
    (QueryOf { DeleteAllBugs -DryRun })     | Should -Not -Match "'Task'"
  }

  # The rail that replaces "the type is hard coded": an unrecognised type must stop, not run a query
  # with a filter that matches everything or nothing by accident.
  It "throws on an unknown type rather than querying without a real filter" {
    { DeleteAllOfType 'Widget' -DryRun } | Should -Throw -ExpectedMessage "*Widget*"
    { DeleteAllOfType '' -DryRun }       | Should -Throw
  }

  It "always scopes to the configured project as well as the type" {
    (QueryOf { DeleteAllTasks -DryRun }) | Should -Match "\[System\.TeamProject\] = 'Migration'"
  }

  It "destroys rather than recycling, so a rerun cannot find them by DigitalAIID" {
    $source = Get-Content $script:scriptPath -Raw
    $body = [regex]::Match($source, "function DeleteAllOfType\b[\s\S]*?(?=\r?\nfunction )").Value

    $body | Should -Match 'destroy=true'
    $body | Should -Match "InvokeAdoRequest .* `"Delete`""
  }

  It "deletes nothing on a dry run" {
    $script:calls = @()
    Mock InvokeAdoRequest {
      $script:calls += $method
      if ($method -eq 'Post') { return [pscustomobject]@{ workItems = @([pscustomobject]@{ id = 1 }) } }
      return $null
    }

    DeleteAllEpics -DryRun

    $script:calls | Should -Not -Contain 'Delete'
  }

  It "walks every item with a System.Id watermark, past the 20,000 row WIQL cap" {
    # Two full pages of 1000, then a short page, then it stops. Ids are unique and ascending.
    $script:call = 0
    Mock InvokeAdoRequest {
      $script:call++
      $count = if ($script:call -le 2) { 1000 } elseif ($script:call -eq 3) { 3 } else { 0 }
      $start = ($script:call - 1) * 1000
      return [pscustomobject]@{ workItems = @(1..$count | ForEach-Object { [pscustomobject]@{ id = $start + $_ } }) }
    }

    $ids = GetAllIdsOfType 'Task'

    @($ids).Count | Should -Be 2003
    $ids[-1] | Should -Be 2003 -Because "the watermark keeps advancing past 20k"
  }

  It "asks for ids above the last one it saw, so no page is fetched twice" {
    # A FULL first page (1000) forces a second query; its watermark must be the last id seen.
    $script:queries = @()
    Mock InvokeAdoRequest {
      $script:queries += $body.query
      if ($script:queries.Count -eq 1) { return [pscustomobject]@{ workItems = @(1..1000 | ForEach-Object { [pscustomobject]@{ id = $_ } }) } }
      return [pscustomobject]@{ workItems = @() }
    }

    GetAllIdsOfType 'Task' | Out-Null

    $script:queries[0] | Should -Match 'System\.Id\] > 0'
    $script:queries[1] | Should -Match 'System\.Id\] > 1000'
  }

  # 'Product Backlog Item' contains spaces; the WIQL quoting has to survive that.
  It "handles a type name with spaces" {
    (QueryOf { DeleteAllProductBacklogItems -DryRun }) |
      Should -Match ([regex]::Escape("[System.WorkItemType] = 'Product Backlog Item'"))
  }

  It "counts a failed delete instead of abandoning the rest of the run" {
    Mock InvokeAdoRequest {
      if ($method -eq 'Post') { return [pscustomobject]@{ workItems = @(1..3 | ForEach-Object { [pscustomobject]@{ id = $_ } }) } }
      if ($url -match '/2\?') { throw "boom" }
      return $null
    }
    Mock WriteErrorDetail { }

    # One of three ids fails. The loop must reach the third rather than stopping at the second.
    { DeleteAllBugs } | Should -Not -Throw
    Should -Invoke InvokeAdoRequest -Times 4 -Exactly
  }

  # Same contract Migrate has: total the failures, let the bottom of the script turn them into an
  # exit code. Calling exit in here would stop a Main that deletes more than one type.
  It "totals failures rather than exiting, so Main can delete more than one type" {
    $source = Get-Content $script:scriptPath -Raw
    $body = [regex]::Match($source, "function DeleteAllOfType\b[\s\S]*?(?=\r?\nfunction )").Value

    $body | Should -Match '\$script:totalFailed \+= \$failed'
    $body | Should -Not -Match '(?m)^\s*exit\b'

    $script:totalFailed = 0
    Mock InvokeAdoRequest {
      if ($method -eq 'Post') { return [pscustomobject]@{ workItems = @(1..2 | ForEach-Object { [pscustomobject]@{ id = $_ } }) } }
      throw "boom"
    }
    Mock WriteErrorDetail { }

    DeleteAllTasks

    $script:totalFailed | Should -Be 2
  }

  It "adds nothing to the failure total on a clean dry run" {
    $script:totalFailed = 0
    Mock InvokeAdoRequest { return [pscustomobject]@{ workItems = @([pscustomobject]@{ id = 1 }) } }

    DeleteAllEpics -DryRun

    $script:totalFailed | Should -Be 0
  }
}

Describe "Air gap: the delete script and the migration script cannot reach each other" {

  # The whole reason this script exists as a separate file. A dot source, or any code that names the
  # other script, puts the create paths and the destroy loop back in one process.
  It "loads no other script" {
    $code = CodeLines $script:scriptPath

    @($code | Where-Object { $_ -match 'Migrate-Agility' }) | Should -BeNullOrEmpty `
      -Because "only a comment may mention the migration script"

    # A dot source is `. <path>` at the start of a statement. Method calls and $_. are not.
    @($code | Where-Object { $_ -match '^\s*\.\s+[''"$]' }) | Should -BeNullOrEmpty `
      -Because "the delete script must be self contained"
  }

  # Agility is the read only system. The delete script has no business there at all, so it carries
  # no door to it - not even one hard coded to GET.
  It "has no door to Agility" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Not -Match 'rest-1\.v1'
    $source | Should -Not -Match 'AGILITY_ACCESS_TOKEN'
    $source | Should -Not -Match 'InvokeAgility'
    $source | Should -Not -Match 'attachment\.img'
  }

  # The other half. The migration script writes; it must not be able to destroy.
  It "leaves no delete capability in the migration script" {
    $source = Get-Content $script:migratePath -Raw

    $source | Should -Not -Match 'destroy=true'
    $source | Should -Not -Match 'DeleteAllOfType'
    $source | Should -Not -Match 'DeletableAdoTypes'
    $source | Should -Not -Match 'GetAllIdsOfType'

    foreach ($fn in @('DeleteAllEpics', 'DeleteAllFeatures', 'DeleteAllProductBacklogItems',
                      'DeleteAllBugs', 'DeleteAllTasks', 'DeleteAllImpediments'))
    {
      $source | Should -Not -Match $fn -Because "$fn belongs to Remove-WorkItems.ps1 now"
    }
  }

  It "sends no Delete verb to Azure DevOps from the migration script" {
    $code = CodeLines $script:migratePath

    @($code | Where-Object { $_ -match '(?i)-Method\s+["'']?Delete' -or $_ -match '(?i)InvokeAdoRequest\s+\S+\s+["'']Delete' }) |
      Should -BeNullOrEmpty -Because "deleting lives in Remove-WorkItems.ps1"
  }

  It "does not run the delete script from the migration script" {
    @((CodeLines $script:migratePath) | Where-Object { $_ -match 'Remove-WorkItems' }) |
      Should -BeNullOrEmpty -Because "only a comment may point at the delete script"
  }

  # The two scripts each open their own log. Sharing a name would make a destroy run indistinguishable
  # from a migration run in a directory that already holds dozens of the latter.
  It "writes its own log file name" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Match 'Remove-WorkItems-\{0\}'
    $source | Should -Not -Match 'Migrate-Agility-\{0\}'
  }

  # Reusing the migration script's flag would let one suite suppress the other script's Main.
  It "guards its entry point with its own explicit flag" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Match '\$global:RemoveWorkItemsLoadFunctionsOnly'
    $source | Should -Not -Match 'AgilityEpicsLoadFunctionsOnly'

    # Not $MyInvocation: VS Code's F5 dot sources exactly as the tests do, so it cannot tell them
    # apart, and keying off it makes F5 print nothing at all. Code lines only - the script explains
    # that in a comment, and the explanation is the reason the mistake is not made twice.
    @((CodeLines $script:scriptPath) | Where-Object { $_ -match '\$MyInvocation\.InvocationName' }) |
      Should -BeNullOrEmpty
  }
}

Describe "Logging" {

  # A Write-Host inside a run prints a line that never reaches the log, so the log quietly stops
  # being the record of what happened. That is invisible from the outside, because the console still
  # looks right. Only three regions may legitimately bypass WriteLog:
  #   Main               - its banner prints before a log is open
  #   the Logging block  - WriteLog is built out of Write-Host, so it has to call it
  #   the dot source guard - not part of any run
  It "routes every progress line through WriteLog, so the console and the log cannot drift" {
    $lines = Get-Content $script:scriptPath

    $inMain = $false
    $inLogging = $false
    $inGuard = $false
    $offenders = @()

    for ($i = 0; $i -lt $lines.Count; $i++)
    {
      $line = $lines[$i]

      if ($line -match '^function Main\s*$') { $inMain = $true }
      elseif ($line -match '^function \w+')  { $inMain = $false }

      if ($line -match '^# Logging\s*$')                   { $inLogging = $true }
      if ($line -match '^# Configuration and secrets\s*$') { $inLogging = $false }

      if ($line -match '^if \(\$global:RemoveWorkItemsLoadFunctionsOnly\)') { $inGuard = $true }

      if ($line -notmatch 'Write-Host') { continue }
      if ($line -match '^\s*#') { continue }
      if ($inMain -or $inLogging -or $inGuard) { continue }

      $offenders += "line $($i + 1): $($line.Trim())"
    }

    $offenders | Should -BeNullOrEmpty -Because "these should call WriteLog: $($offenders -join ' | ')"
  }

  It "is safe to log with no writer behind it" {
    $script:logWriter = $null

    { WriteLog "still talking" }       | Should -Not -Throw
    { WriteLogDetail "still recording" } | Should -Not -Throw
    { StopLog }                        | Should -Not -Throw
  }
}

Describe "Retry" {

  # A socket timeout or a dropped connection produces an error record with NO Response, so reading
  # .StatusCode gives $null. Treating that as permanent gave up without a single retry, which on a
  # long destroy run is the difference between resuming and starting over.
  It "retries a failure that has no response at all" {
    $noResponse = [System.Management.Automation.ErrorRecord]::new(
      [Exception]::new("The operation has timed out"), "timeout", 'OperationTimeout', $null)

    IsTransientFailure $noResponse | Should -BeTrue
  }

  It "gives up immediately on a permanent failure, rather than retrying a 400" {
    Mock IsTransientFailure { return $false }
    $script:attempts = 0

    { InvokeWithRetry { $script:attempts++; throw "bad request" } -attempts 3 -fixedDelay 0 } | Should -Throw

    $script:attempts | Should -Be 1
  }

  It "retries a transient failure up to the attempt limit, then rethrows" {
    Mock IsTransientFailure { return $true }
    Mock WriteLog { }
    $script:attempts = 0

    { InvokeWithRetry { $script:attempts++; throw "throttled" } -attempts 3 -fixedDelay 0 } | Should -Throw

    $script:attempts | Should -Be 3
  }

  It "never sleeps longer than the cap, whatever Retry-After says" {
    $script:MaxRetryDelaySeconds | Should -Be 120
  }
}
