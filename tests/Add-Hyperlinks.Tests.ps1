##################################################################################################
# Tests for the Agility hyperlink script.
#
# It adds ONE relation to a migrated work item: a hyperlink back to its source record in Agility,
# built from the Number already on the item. The tests are about the ways that can go wrong: a link
# built to the wrong place, a rerun adding the same link twice, an item that never came from Agility
# getting one, an item in the wrong project getting one, a patch that lands on a changed item or
# costs the item a relation, a dry run that writes, and a 200 taken as proof.
#
# Every test is hermetic. Nothing here resolves a credential, queries the live org, or writes a log.
##################################################################################################

BeforeAll {
  $script:scriptPath  = Join-Path $PSScriptRoot ".." "src" "Add-Hyperlinks.ps1"
  $script:otherPaths  = @(Get-ChildItem (Join-Path $PSScriptRoot ".." "src") -Filter *.ps1 | Where-Object { $_.Name -ne 'Add-Hyperlinks.ps1' } | ForEach-Object { $_.FullName })

  $global:AddHyperlinksLoadFunctionsOnly = $true
  . $script:scriptPath

  function CodeLines([string]$path) { return @(Get-Content $path | Where-Object { $_ -notmatch '^\s*#' }) }

  function TestConfig
  {
    return [pscustomobject]@{
      Agility     = [pscustomobject]@{ BaseUrl = "https://www7.v1host.com/YourInstance/" }
      AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/contoso"; Project = "IT"; CredentialTarget = "x" }
    }
  }

  function Rel([string]$rel, [string]$url) { return [pscustomobject]@{ rel = $rel; url = $url; attributes = [pscustomobject]@{ comment = "x" } } }

  function Item([int]$id, [string]$number, $relations, [string]$project = 'Training', [int]$rev = 4)
  {
    $wi = [pscustomobject]@{
      id = $id; rev = $rev
      fields = [pscustomobject]@{ 'System.WorkItemType' = 'Task'; 'System.TeamProject' = $project; 'Custom.DigitalAIID' = $number }
    }
    if ($null -ne $relations) { $wi | Add-Member -NotePropertyName relations -NotePropertyValue @($relations) }
    return $wi
  }

  $script:S40245 = 'https://www7.v1host.com/YourInstance/assetdetail.v1?Number=S-40245'
  $script:parent = Rel 'System.LinkTypes.Hierarchy-Reverse' 'https://dev.azure.com/contoso/_apis/wit/workItems/1'
}

Describe "The link is built from the Number alone" {

  BeforeEach { $script:config = TestConfig }

  # assetdetail.v1 resolves a Number for every asset type, so neither the type nor the oid is needed.
  It "builds the assetdetail.v1 url from the configured base and the Number, whatever the type" {
    BuildAgilityUrl 'S-40245'   | Should -Be $script:S40245
    BuildAgilityUrl 'TK-141988' | Should -Be 'https://www7.v1host.com/YourInstance/assetdetail.v1?Number=TK-141988'
  }

  It "does not double the slash when the configured BaseUrl ends in one" {
    BuildAgilityUrl 'E-09415' | Should -Not -Match 'YourInstance//'
  }

  It "accepts every Number prefix the migration writes" {
    foreach ($n in 'E-09415', 'S-40245', 'D-02525', 'TK-141988', 'I-01687') { IsAgilityNumber $n | Should -BeTrue -Because $n }
  }

  It "refuses anything that is not a Number, so no link is built from junk" {
    foreach ($n in '', 'S-', '40245', 's-40245', 'S-40245&x=1', 'S 40245', 'https://evil.example') { IsAgilityNumber $n | Should -BeFalse -Because "'$n'" }
  }
}

Describe "The patch" {

  BeforeEach { $script:config = TestConfig }

  It "tests the revision first, then appends one Hyperlink relation" {
    $ops = @(BuildAddHyperlinkOps (Item 7 'S-40245' @($script:parent) -rev 15) $script:S40245 'S-40245')

    $ops.Count | Should -Be 2
    $ops[0].op | Should -Be 'test'
    $ops[0].path | Should -Be '/rev'
    $ops[0].value | Should -Be 15
    $ops[1].op | Should -Be 'add'
    $ops[1].path | Should -Be '/relations/-'
    $ops[1].value.rel | Should -Be 'Hyperlink'
    $ops[1].value.url | Should -Be $script:S40245
  }

  It "carries the Number as the link comment, which is what the Links tab shows" {
    $ops = @(BuildAddHyperlinkOps (Item 7 'S-40245' $null) $script:S40245 'S-40245')
    $ops[1].value.attributes.comment | Should -Be 'digital.ai Agility S-40245'
  }

  It "serializes as a JSON array, which JSON Patch requires" {
    $ops = @(BuildAddHyperlinkOps (Item 7 'S-40245' $null) $script:S40245 'S-40245')
    ($ops -is [array]) | Should -BeTrue
    ($ops | ConvertTo-Json -Depth 10 -AsArray:($ops -is [array])).TrimStart() | Should -Match '^\['
  }
}

Describe "Idempotent: a link that is there is never added again" {

  BeforeEach { $script:config = TestConfig }

  It "finds an existing hyperlink to the same url" {
    HasHyperlink (Item 7 'S-40245' @($script:parent, (Rel 'Hyperlink' $script:S40245))) $script:S40245 | Should -BeTrue
  }

  It "matches the url without regard to case" {
    HasHyperlink (Item 7 'S-40245' @((Rel 'Hyperlink' $script:S40245.ToUpperInvariant()))) $script:S40245 | Should -BeTrue
  }

  It "is not fooled by a hyperlink to somewhere else, or by another relation with the same url" {
    HasHyperlink (Item 7 'S-40245' @((Rel 'Hyperlink' 'https://example.com/'), (Rel 'ArtifactLink' $script:S40245))) $script:S40245 | Should -BeFalse
  }

  # @($null) is a one element array holding a null; an item with no relations has no property at all.
  It "survives an item with no relations" {
    HasHyperlink (Item 7 'S-40245' $null) $script:S40245 | Should -BeFalse
  }
}

Describe "One item" {

  BeforeEach {
    $script:config = TestConfig
    $script:DryRun = $false
    $script:calls = @()
    Mock WriteLog { }
    Mock WriteLogDetail { }
    Mock WriteErrorDetail { }
  }

  It "patches the item and reports Added when the response shows the link and nothing lost" {
    $before = Item 7 'S-40245' @($script:parent)
    Mock InvokeAdoRequest {
      $script:calls += [pscustomobject]@{ url = $url; method = $method; body = $body; contentType = $contentType }
      return (Item 7 'S-40245' @($script:parent, (Rel 'Hyperlink' $script:S40245)) -rev 5)
    }

    $r = AddHyperlink 'Training' 7 $before

    $r.Status | Should -Be 'Added'
    $script:calls.Count | Should -Be 1
    $script:calls[0].method | Should -Be 'Patch'
    $script:calls[0].url | Should -Match '/Training/_apis/wit/workitems/7\?'
    $script:calls[0].url | Should -Not -Match 'bypassRules'
    $script:calls[0].contentType | Should -Be 'application/json-patch+json'
  }

  It "sends nothing for an item that already has the link" {
    Mock InvokeAdoRequest { $script:calls += 1 }

    $r = AddHyperlink 'Training' 7 (Item 7 'S-40245' @((Rel 'Hyperlink' $script:S40245)))

    $r.Status | Should -Be 'Exists'
    $script:calls.Count | Should -Be 0
  }

  It "sends nothing on a dry run, and still says what it would add" {
    $script:DryRun = $true
    Mock InvokeAdoRequest { $script:calls += 1 }

    $r = AddHyperlink 'Training' 7 (Item 7 'S-40245' @($script:parent))

    $r.Status | Should -Be 'Added'
    $r.Label | Should -Match 'Number=S-40245'
    $script:calls.Count | Should -Be 0
  }

  It "skips an item with no Agility Number: it was not migrated, so there is nothing to link to" {
    Mock InvokeAdoRequest { $script:calls += 1 }

    $r = AddHyperlink 'Training' 7 (Item 7 '' @($script:parent))

    $r.Status | Should -Be 'Skipped'
    $script:calls.Count | Should -Be 0
  }

  It "refuses an item that lives in another project" {
    Mock InvokeAdoRequest { $script:calls += 1 }

    $r = AddHyperlink 'Training' 7 (Item 7 'S-40245' @($script:parent) -project 'IT')

    $r.Status | Should -Be 'Failed'
    $r.Label | Should -Match "'IT'"
    $script:calls.Count | Should -Be 0
  }

  It "fails an id that was not found, and a field that is not a Number, without sending anything" {
    Mock InvokeAdoRequest { $script:calls += 1 }

    (AddHyperlink 'Training' 7 $null).Status | Should -Be 'Failed'
    (AddHyperlink 'Training' 7 (Item 7 'not a number' $null)).Status | Should -Be 'Failed'
    $script:calls.Count | Should -Be 0
  }

  It "reports a rejected patch as Failed with ADO's message, and does not throw" {
    Mock InvokeAdoRequest { throw "TF26071: This work item has been changed by someone else" }

    $r = AddHyperlink 'Training' 7 (Item 7 'S-40245' @($script:parent))

    $r.Status | Should -Be 'Failed'
    $r.Label | Should -Match 'TF26071'
  }

  # A green 200 is not evidence. The response is the item after the patch, and it is checked.
  It "fails a patch that returned 200 but whose response does not carry the link" {
    Mock InvokeAdoRequest { return (Item 7 'S-40245' @($script:parent) -rev 5) }

    (AddHyperlink 'Training' 7 (Item 7 'S-40245' @($script:parent))).Status | Should -Be 'Failed'
  }
}

Describe "Verifying the item after the patch" {

  BeforeEach { $script:config = TestConfig }

  It "passes when the link is there once and every earlier relation survived" {
    $before = Item 7 'S-40245' @($script:parent)
    $after = Item 7 'S-40245' @($script:parent, (Rel 'Hyperlink' $script:S40245))

    VerifyHyperlinkAdded $before $after $script:S40245 | Should -BeNullOrEmpty
  }

  It "passes on an item that had no relations at all before" {
    VerifyHyperlinkAdded (Item 7 'S-40245' $null) (Item 7 'S-40245' @((Rel 'Hyperlink' $script:S40245))) $script:S40245 | Should -BeNullOrEmpty
  }

  It "reports a relation that went missing" {
    $before = Item 7 'S-40245' @($script:parent, (Rel 'AttachedFile' 'https://dev.azure.com/contoso/_apis/wit/attachments/abc'))
    $after = Item 7 'S-40245' @($script:parent, (Rel 'Hyperlink' $script:S40245))

    VerifyHyperlinkAdded $before $after $script:S40245 | Should -Match 'AttachedFile'
  }

  It "reports a duplicate link, and a relation nobody asked for" {
    $before = Item 7 'S-40245' @($script:parent)
    $twice = Item 7 'S-40245' @($script:parent, (Rel 'Hyperlink' $script:S40245), (Rel 'Hyperlink' $script:S40245))
    $extra = Item 7 'S-40245' @($script:parent, (Rel 'Hyperlink' $script:S40245), (Rel 'Hyperlink' 'https://example.com/'))

    VerifyHyperlinkAdded $before $twice $script:S40245 | Should -Match 'expected 1'
    VerifyHyperlinkAdded $before $extra $script:S40245 | Should -Match 'expected 2'
  }
}

Describe "The run" {

  BeforeEach {
    $script:config = TestConfig
    $script:totalFailed = 0
    $script:lines = @()
    Mock GetConfig { return (TestConfig) }
    Mock BuildAdoHeaders { return @{} }
    Mock StartLog { }
    Mock WriteLog { $script:lines += $message }
    Mock WriteLogDetail { }
    Mock WriteErrorDetail { }
  }

  It "requires a project, and never falls back to the configured one" {
    { AddHyperlinks -Ids 7 } | Should -Throw -ExpectedMessage "*-Project*"
  }

  It "requires -Ids or -All, so it can never default to a whole project" {
    { AddHyperlinks -Project 'Training' } | Should -Throw -ExpectedMessage "*-Ids*"
    { AddHyperlinks -Project 'Training' -Ids 7 -All } | Should -Throw -ExpectedMessage "*not both*"
  }

  It "reads the named project, not the configured one" {
    $script:urls = @()
    Mock InvokeAdoRequest { $script:urls += $url; return [pscustomobject]@{ value = @() } }

    AddHyperlinks -Project 'Training' -Ids 7 -DryRun

    @($script:urls | Where-Object { $_ -match '/IT/' }) | Should -BeNullOrEmpty
    $script:urls[0] | Should -Match '/Training/_apis/wit/workitemsbatch'
  }

  It "writes nothing at all on a dry run" {
    $script:methods = @()
    Mock InvokeAdoRequest {
      $script:methods += $method
      return [pscustomobject]@{ value = @((Item 7 'S-40245' @($script:parent)), (Item 8 'TK-141988' $null)) }
    }

    AddHyperlinks -Project 'Training' -Ids 7, 8 -DryRun

    @($script:methods | Where-Object { $_ -ne 'Post' }) | Should -BeNullOrEmpty
    # -cmatch: -match is case insensitive and would count the summary's own "Would add:" line.
    @($script:lines | Where-Object { $_ -cmatch '^\s*WOULD' }).Count | Should -Be 2
  }

  It "counts an id that was not found as a failure, and totals it rather than exiting" {
    Mock InvokeAdoRequest { return [pscustomobject]@{ value = @($null) } }

    AddHyperlinks -Project 'Training' -Ids 999 -DryRun

    $script:totalFailed | Should -Be 1

    $source = Get-Content $script:scriptPath -Raw
    $body = [regex]::Match($source, "function AddHyperlinks\b[\s\S]*?(?=\r?\nfunction )").Value
    $body | Should -Not -Match '(?m)^\s*exit\b'
  }

  It "reads in chunks of 200, the most one batch call takes" {
    $script:sizes = @()
    Mock InvokeAdoRequest { $script:sizes += @($body.ids).Count; return [pscustomobject]@{ value = @() } }

    AddHyperlinks -Project 'Training' -Ids (1..450) -DryRun

    $script:sizes | Should -Be @(200, 200, 50)
  }

  # WIQL fails a flat query past 20,000 rows rather than truncating, so -All pages on a watermark.
  It "walks the whole project on a System.Id watermark, with top on the query string" {
    $script:queries = @()
    Mock InvokeAdoRequest {
      $script:queries += [pscustomobject]@{ url = $url; query = $body.query }
      if ($body.query -match '\[System\.Id\] > 0 ') { return [pscustomobject]@{ workItems = @([pscustomobject]@{ id = 1 }, [pscustomobject]@{ id = 2 }) } }
      return [pscustomobject]@{ workItems = @([pscustomobject]@{ id = 3 }) }
    }

    $ids = @(GetAllWorkItemIds 'Training' 2)

    $ids | Should -Be @(1, 2, 3)
    $script:queries[0].url | Should -Match '\$top=2'
    $script:queries[0].query | Should -Match "\[System\.TeamProject\] = 'Training'"
    $script:queries[1].query | Should -Match '\[System\.Id\] > 2 '
  }
}

Describe "Self contained, and it can only add a relation" {

  It "loads no other script and is named by none" {
    $code = CodeLines $script:scriptPath
    @($code | Where-Object { $_ -match 'Migrate-Agility|Remove-WorkItems|Create-Iterations|Repair-DependencyDirection' }) | Should -BeNullOrEmpty
    @($code | Where-Object { $_ -match '^\s*\.\s+[''"$]' }) | Should -BeNullOrEmpty

    $script:otherPaths.Count | Should -BeGreaterThan 0
    foreach ($other in $script:otherPaths)
    {
      @((CodeLines $other) | Where-Object { $_ -match 'Add-Hyperlinks' }) | Should -BeNullOrEmpty -Because $other
    }
  }

  # The link is built from the Number on the work item. Nothing here calls Agility, so it holds no
  # token for it and has no door to it.
  It "never deletes anything and never reaches Agility" {
    $source = Get-Content $script:scriptPath -Raw
    $code = CodeLines $script:scriptPath

    $source | Should -Not -Match 'destroy=true'
    @($code | Where-Object { $_ -match '(?i)-Method\s+["'']?Delete' -or $_ -match '(?i)InvokeAdoRequest\s+\S+\s+["'']Delete' }) | Should -BeNullOrEmpty
    $source | Should -Not -Match 'rest-1\.v1'
    $source | Should -Not -Match 'AGILITY_ACCESS_TOKEN'
    $source | Should -Not -Match 'InvokeAgility'
    @($code | Where-Object { $_ -match 'Agility\.CredentialTarget' }) | Should -BeNullOrEmpty
  }

  It "patches only relations and the revision test: never a field, never a remove, never under bypassRules" {
    $code = CodeLines $script:scriptPath

    @($code | Where-Object { $_ -match '/fields/' }) | Should -BeNullOrEmpty
    @($code | Where-Object { $_ -match 'op\s*=\s*["'']remove' }) | Should -BeNullOrEmpty
    @($code | Where-Object { $_ -match 'bypassRules' }) | Should -BeNullOrEmpty
  }

  It "writes its own log file name and guards its entry point with its own flag" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Match 'Add-Hyperlinks-\{0\}'
    $source | Should -Match '\$global:AddHyperlinksLoadFunctionsOnly'
    $source | Should -Not -Match 'AgilityEpicsLoadFunctionsOnly'
    $source | Should -Not -Match 'RemoveWorkItemsLoadFunctionsOnly'
    @((CodeLines $script:scriptPath) | Where-Object { $_ -match '\$MyInvocation\.InvocationName' }) | Should -BeNullOrEmpty
  }

  It "ships with a dry run as the live line in Main" {
    $source = Get-Content $script:scriptPath -Raw
    $main = [regex]::Match($source, "function Main\b[\s\S]*?(?=\r?\n#{10,})").Value
    $live = @(($main -split "`r?`n") | Where-Object { $_ -match '^\s*AddHyperlinks\b' })

    $live.Count | Should -Be 1
    $live[0] | Should -Match '-DryRun'
  }

  It "has no param block and no dashes the style rules bar" {
    $source = Get-Content $script:scriptPath -Raw
    @((CodeLines $script:scriptPath) | Where-Object { $_ -match '^param\b' }) | Should -BeNullOrEmpty
    $source | Should -Not -Match "[–—]"
  }
}

Describe "Logging" {

  It "routes every progress line through WriteLog, so the console and the log cannot drift" {
    $lines = Get-Content $script:scriptPath
    $inMain = $false; $inLogging = $false; $inGuard = $false; $offenders = @()
    for ($i = 0; $i -lt $lines.Count; $i++)
    {
      $line = $lines[$i]
      if ($line -match '^function Main\s*$') { $inMain = $true } elseif ($line -match '^function \w+') { $inMain = $false }
      if ($line -match '^# Logging\s*$') { $inLogging = $true }
      if ($line -match '^# Configuration and secrets\s*$') { $inLogging = $false }
      if ($line -match '^if \(\$global:AddHyperlinksLoadFunctionsOnly\)') { $inGuard = $true }
      if ($line -notmatch 'Write-Host') { continue }
      if ($line -match '^\s*#') { continue }
      if ($inMain -or $inLogging -or $inGuard) { continue }
      $offenders += "line $($i + 1): $($line.Trim())"
    }
    $offenders | Should -BeNullOrEmpty -Because "these should call WriteLog: $($offenders -join ' | ')"
  }

  It "is safe to log with no writer behind it" {
    $script:logWriter = $null
    { WriteLog "still talking" } | Should -Not -Throw
    { WriteLogDetail "still recording" } | Should -Not -Throw
    { StopLog } | Should -Not -Throw
  }
}

Describe "Retry" {

  It "retries a failure that has no response at all" {
    $noResponse = [System.Management.Automation.ErrorRecord]::new([Exception]::new("The operation has timed out"), "timeout", 'OperationTimeout', $null)
    IsTransientFailure $noResponse | Should -BeTrue
  }

  It "backs off on a failure with no response, rather than throwing" {
    $noResponse = [System.Management.Automation.ErrorRecord]::new([Exception]::new("The operation has timed out"), "timeout", 'OperationTimeout', $null)
    { ResolveRetryDelay $noResponse 1 } | Should -Not -Throw
    ResolveRetryDelay $noResponse 1 | Should -Be 2
  }

  It "gives up immediately on a permanent failure" {
    Mock IsTransientFailure { return $false }
    Mock WriteLog { }
    $script:attempts = 0
    { InvokeWithRetry { $script:attempts++; throw "bad request" } -attempts 3 -fixedDelay 0 } | Should -Throw
    $script:attempts | Should -Be 1
  }

  It "never sleeps longer than the cap" {
    $script:MaxRetryDelaySeconds | Should -Be 120
  }
}
