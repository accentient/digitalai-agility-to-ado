##################################################################################################
# Tests for the iteration script.
#
# Three things are under test. First, idempotence: a rerun creates only the nodes that are missing
# and never touches one that exists, so the script can be run as often as anyone likes. Second, that
# the node it creates is the one the migration will write to - the Timebox name verbatim, directly
# under the project, with dates in the one form ADO does not silently drop. Third, the air gap: this
# script is self contained, reads Agility through a GET only door, and can neither destroy anything
# in Azure DevOps nor be reached from the other two scripts.
#
# Every test is hermetic. Nothing here resolves a credential, queries the live instance, or writes a
# log file.
##################################################################################################

BeforeAll {
  $script:scriptPath  = Join-Path $PSScriptRoot ".." "src" "Create-Iterations.ps1"
  $script:migratePath = Join-Path $PSScriptRoot ".." "src" "Migrate-Agility.ps1"
  $script:removePath  = Join-Path $PSScriptRoot ".." "src" "Remove-WorkItems.ps1"

  # Load the functions without creating anything. Explicit flag, this script's own: VS Code's F5
  # also dot sources the script, so it cannot infer a test run from how it was invoked.
  $global:CreateIterationsLoadFunctionsOnly = $true
  . $script:scriptPath

  function CodeLines([string]$path)
  {
    return @(Get-Content $path | Where-Object { $_ -notmatch '^\s*#' })
  }

  # One page of Agility Story assets in the rest-1.v1 wire shape, as Timebox.Name and its dates
  # arrive. The item with no Timebox is the common case (Epics never have one, and a third of
  # Stories do not) and must contribute nothing.
  $script:agilityPage = @'
{
  "_type": "Assets",
  "pageSize": 500,
  "pageStart": 0,
  "Assets": [
    { "id": "Story:1", "Attributes": {
        "Timebox.Name":      { "name": "Timebox.Name",      "value": "Sprint 001" },
        "Timebox.BeginDate": { "name": "Timebox.BeginDate", "value": "2018-08-29" },
        "Timebox.EndDate":   { "name": "Timebox.EndDate",   "value": "2018-09-19" } } },
    { "id": "Story:2", "Attributes": {
        "Timebox.Name":      { "name": "Timebox.Name",      "value": "Sprint 001" },
        "Timebox.BeginDate": { "name": "Timebox.BeginDate", "value": "2018-08-29" },
        "Timebox.EndDate":   { "name": "Timebox.EndDate",   "value": "2018-09-19" } } },
    { "id": "Story:3", "Attributes": {
        "Timebox.Name":      { "name": "Timebox.Name",      "value": "Sprint  005" },
        "Timebox.BeginDate": { "name": "Timebox.BeginDate", "value": "2018-11-21T00:00:00" },
        "Timebox.EndDate":   { "name": "Timebox.EndDate",   "value": "2018-12-12T00:00:00" } } },
    { "id": "Story:4", "Attributes": {
        "Timebox.Name":      { "name": "Timebox.Name",      "value": null },
        "Timebox.BeginDate": { "name": "Timebox.BeginDate", "value": null },
        "Timebox.EndDate":   { "name": "Timebox.EndDate",   "value": null } } }
  ]
}
'@ | ConvertFrom-Json
}

Describe "Reading the timeboxes the migration will write" {

  BeforeAll {
    $script:config = [pscustomobject]@{
      Agility = [pscustomobject]@{
        BaseUrl = "https://www7.v1host.com/YourInstance"
        Scopes  = @([pscustomobject]@{ Scope = "Scope:2345"; AreaPath = "Operations" },
                    [pscustomobject]@{ Scope = "Scope:3456"; AreaPath = "User Services" })
      }
      AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/contoso"; Project = "IT" }
    }
  }

  It "collects each distinct timebox once, with its dates and how many items carry it" {
    $found = @{}

    CollectTimeboxes $script:agilityPage.Assets $found

    $found.Count | Should -Be 2
    $found['Sprint 001'].Begin | Should -Be '2018-08-29'
    $found['Sprint 001'].End   | Should -Be '2018-09-19'
    $found['Sprint 001'].Items | Should -Be 2
    $found['Sprint  005'].Items | Should -Be 1
  }

  # Agility spells one real timebox 'Sprint  005' with two spaces, and the migration writes the
  # Timebox name into System.IterationPath verbatim. So the node name must be verbatim too, or every
  # item on that sprint fails with TF401347.
  It "keeps the timebox name verbatim, double spaces included" {
    $found = @{}

    CollectTimeboxes $script:agilityPage.Assets $found

    $found.ContainsKey('Sprint  005') | Should -BeTrue
    $found.ContainsKey('Sprint 005')  | Should -BeFalse
  }

  It "ignores an item with no timebox" {
    $found = @{}

    CollectTimeboxes @($script:agilityPage.Assets[3]) $found

    $found.Count | Should -Be 0
  }

  # The migration reads Timebox.Name on Story, Defect and Task, and on nothing else. Walking any
  # other type would be wasted calls; missing one would leave its sprints uncreated.
  It "walks exactly the Agility types the migration reads a Timebox on" {
    $script:TimeboxedAgilityTypes | Should -Be @('Story', 'Defect', 'Task')
  }

  It "asks Agility for every configured scope and every timeboxed type, excluding Dead items" {
    $script:urls = @()
    Mock InvokeAgilityGet { $script:urls += $url; return [pscustomobject]@{ Assets = @() } }
    Mock WriteLog { }

    GetAgilityTimeboxes | Out-Null

    $script:urls.Count | Should -Be 6 -Because "2 scopes x 3 types"
    foreach ($u in $script:urls)
    {
      $u | Should -Match 'sel=Timebox\.Name,Timebox\.BeginDate,Timebox\.EndDate'
      $u | Should -Match ([regex]::Escape([uri]::EscapeDataString("AssetState!='Dead'")))
      $u | Should -Match 'rest-1\.v1/Data/(Story|Defect|Task)\?'
    }
    @($script:urls | Where-Object { $_ -match ([regex]::Escape([uri]::EscapeDataString("Scope='Scope:3456'"))) }).Count | Should -Be 3
  }

  It "pages until a short batch" {
    $script:call = 0
    Mock InvokeAgilityGet {
      $script:call++
      # First call: a full page; every call after: a short one.
      $n = if ($script:call -eq 1) { 500 } else { 1 }
      return [pscustomobject]@{ Assets = @(1..$n | ForEach-Object {
        [pscustomobject]@{ id = "Story:$_"; Attributes = [pscustomobject]@{
          'Timebox.Name'      = [pscustomobject]@{ value = "Sprint $($script:call)" }
          'Timebox.BeginDate' = [pscustomobject]@{ value = "2020-01-01" }
          'Timebox.EndDate'   = [pscustomobject]@{ value = "2020-01-22" } } } }) }
    }
    Mock WriteLog { }

    $found = GetAgilityTimeboxes

    # 6 walks; the first walk (Story, scope 1) needed two pages, the other five stopped after one.
    $script:call | Should -Be 7
    $found['Sprint 1'].Items | Should -Be 500
  }
}

Describe "The node it creates is the one the migration writes to" {

  # A bare "2018-08-29" is silently ignored by ADO: HTTP 200, node created, no dates. Only the full
  # ISO 8601 form with a time part lands.
  It "sends dates as full ISO 8601 with a time part" {
    FormatIterationDate '2018-08-29'           | Should -Be '2018-08-29T00:00:00Z'
    FormatIterationDate '2018-11-21T00:00:00'  | Should -Be '2018-11-21T00:00:00Z'
  }

  It "sends no date at all rather than an invented one" {
    FormatIterationDate ''    | Should -BeNullOrEmpty
    FormatIterationDate $null | Should -BeNullOrEmpty
  }

  # Agility's EndDate is EXCLUSIVE: every timebox on the schedule ends on the Wednesday the next one
  # begins. ADO's finish date is inclusive, so copying it verbatim made each sprint overlap the next
  # by a day (found on the IT project 2026-09-16, all 141 consecutive pairs). The sprint finishes on
  # the Tuesday, the day before.
  It "builds a node body with the name verbatim, the begin date, and a finish the day BEFORE Agility's end" {
    $body = BuildIterationBody 'Sprint  005' '2018-11-21' '2018-12-12'

    $body.name                  | Should -Be 'Sprint  005'
    $body.attributes.startDate  | Should -Be '2018-11-21T00:00:00Z'
    $body.attributes.finishDate | Should -Be '2018-12-11T00:00:00Z'
  }

  It "turns a Wednesday end into a Tuesday finish" {
    $finish = [datetime]::Parse((FormatFinishDate '2018-09-19').TrimEnd('Z'))
    $finish.DayOfWeek | Should -Be 'Tuesday'
    $finish.ToString('yyyy-MM-dd') | Should -Be '2018-09-18'
  }

  It "gives no finish date at all when there is no end date" {
    FormatFinishDate '' | Should -BeNullOrEmpty
  }

  # Invoke-RestMethod turns the ISO date in the response into a DateTime, and the first live run
  # stringified it in the local culture ("11/21/2018 00:00:00") and compared that against
  # "2018-11-21": all 142 nodes read back as wrong when every one was right. The check has to
  # compare days, not strings, whatever type the value arrives as.
  It "accepts a node read back with DateTime-typed dates on the right day" {
    $node = [pscustomobject]@{ name = 'Sprint 001'; attributes = [pscustomobject]@{
      startDate  = [datetime]::new(2018, 8, 29, 0, 0, 0, [DateTimeKind]::Utc)
      finishDate = [datetime]::new(2018, 9, 18, 0, 0, 0, [DateTimeKind]::Utc) } }

    VerifyIterationNode $node @{ Begin = '2018-08-29'; End = '2018-09-19' } | Should -BeNullOrEmpty
  }

  It "accepts a node read back with ISO string dates on the right day" {
    $node = [pscustomobject]@{ name = 'Sprint 001'; attributes = [pscustomobject]@{ startDate = '2018-08-29T00:00:00Z'; finishDate = '2018-09-18T00:00:00Z' } }

    VerifyIterationNode $node @{ Begin = '2018-08-29'; End = '2018-09-19' } | Should -BeNullOrEmpty
  }

  # A finish ON Agility's end date is the overlap bug and must read back as wrong.
  It "rejects a node read back on the wrong day, one finishing on Agility's end date, and one with no dates" {
    $wrong = [pscustomobject]@{ name = 'Sprint 001'; attributes = [pscustomobject]@{
      startDate  = [datetime]::new(2018, 8, 30, 0, 0, 0, [DateTimeKind]::Utc)
      finishDate = [datetime]::new(2018, 9, 18, 0, 0, 0, [DateTimeKind]::Utc) } }
    $overlap = [pscustomobject]@{ name = 'Sprint 001'; attributes = [pscustomobject]@{
      startDate  = [datetime]::new(2018, 8, 29, 0, 0, 0, [DateTimeKind]::Utc)
      finishDate = [datetime]::new(2018, 9, 19, 0, 0, 0, [DateTimeKind]::Utc) } }
    $none = [pscustomobject]@{ name = 'Sprint 001'; attributes = $null }

    VerifyIterationNode $wrong   @{ Begin = '2018-08-29'; End = '2018-09-19' } | Should -Match 'expected 2018-08-29'
    VerifyIterationNode $overlap @{ Begin = '2018-08-29'; End = '2018-09-19' } | Should -Match 'expected 2018-08-29 -> 2018-09-18'
    VerifyIterationNode $none  @{ Begin = '2018-08-29'; End = '2018-09-19' } | Should -Not -BeNullOrEmpty
  }

  It "omits the attributes block when a timebox has no dates, so ADO gets nothing to reject" {
    $body = BuildIterationBody 'Backlog' '' ''

    $body.name | Should -Be 'Backlog'
    $body.ContainsKey('attributes') | Should -BeFalse
  }
}

Describe "Idempotence: a rerun creates only what is missing" {

  BeforeAll {
    $script:testConfig = [pscustomobject]@{
      Agility     = [pscustomobject]@{ BaseUrl = "https://www7.v1host.com/YourInstance"; Scopes = @([pscustomobject]@{ Scope = "Scope:2345"; AreaPath = "Operations" }) }
      AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/contoso"; Project = "IT" }
    }

    # Three timeboxes in Agility; ADO already has the first, spelled in a different case.
    function ThreeTimeboxes
    {
      return @{
        'Sprint 001' = @{ Begin = '2018-08-29'; End = '2018-09-19'; Items = 5 }
        'Sprint 002' = @{ Begin = '2018-09-19'; End = '2018-10-10'; Items = 7 }
        'Sprint 003' = @{ Begin = '2018-10-10'; End = '2018-10-31'; Items = 2 }
      }
    }

    # The ADO tree as read back, each node carrying the dates its timebox has (matched without
    # regard to case, as ADO matches names), so a correct run reads back clean.
    function AdoTree($names)
    {
      $timeboxes = ThreeTimeboxes
      return [pscustomobject]@{
        name = 'IT'
        children = @($names | ForEach-Object {
          $name = $_
          $tb = $null
          foreach ($k in $timeboxes.Keys) { if ($k.ToLowerInvariant() -eq $name.ToLowerInvariant()) { $tb = $timeboxes[$k] } }
          $attrs = if ($tb) { [pscustomobject]@{ startDate = "$($tb.Begin)T00:00:00Z"; finishDate = ([datetime]$tb.End).AddDays(-1).ToString("yyyy-MM-dd'T'00:00:00'Z'") } }
                   else { [pscustomobject]@{ startDate = '2019-01-01T00:00:00Z'; finishDate = '2019-01-22T00:00:00Z' } }
          [pscustomobject]@{ name = $name; attributes = $attrs } })
      }
    }
  }

  BeforeEach {
    Mock GetConfig            { return $script:testConfig }
    Mock BuildAdoHeaders      { return @{ Authorization = "Basic test" } }
    Mock BuildAgilityHeaders  { return @{ Authorization = "Bearer test" } }
    Mock StartLog             { }
    Mock WriteLog             { }
    Mock WriteLogDetail       { }
    Mock GetAgilityTimeboxes  { return (ThreeTimeboxes) }
    $script:totalFailed = 0
  }

  It "creates the missing nodes and leaves the existing one alone" {
    $script:posted = @()
    Mock InvokeAdoRequest {
      if ($method -eq 'Post') { $script:posted += $body.name; return $null }
      # First read: one node exists. Read back after creating: all three.
      if ($script:posted.Count -eq 0) { return (AdoTree @('SPRINT 001')) }
      return (AdoTree @('SPRINT 001', 'Sprint 002', 'Sprint 003'))
    }

    CreateIterations

    $script:posted | Should -Be @('Sprint 002', 'Sprint 003')
  }

  It "creates nothing when every node already exists" {
    Mock InvokeAdoRequest {
      if ($method -eq 'Post') { throw "should not create" }
      return (AdoTree @('Sprint 001', 'Sprint 002', 'Sprint 003'))
    }

    { CreateIterations } | Should -Not -Throw
    Should -Invoke InvokeAdoRequest -ParameterFilter { $method -eq 'Post' } -Times 0 -Exactly
  }

  It "creates nothing on a dry run" {
    Mock InvokeAdoRequest {
      if ($method -eq 'Post') { throw "should not create" }
      return (AdoTree @())
    }

    { CreateIterations -DryRun } | Should -Not -Throw
    Should -Invoke InvokeAdoRequest -ParameterFilter { $method -eq 'Post' } -Times 0 -Exactly
  }

  # Flat under the project root, because that is where the migration writes: "<Project>\<Timebox>".
  It "posts each node directly under the project root" {
    $script:urls = @()
    Mock InvokeAdoRequest {
      if ($method -eq 'Post') { $script:urls += $url; return $null }
      return (AdoTree @('Sprint 001', 'Sprint 002', 'Sprint 003'))
    }
    Mock GetAgilityTimeboxes { return @{ 'Sprint 009' = @{ Begin = '2019-01-01'; End = '2019-01-22'; Items = 1 } } }

    CreateIterations

    $script:urls.Count | Should -Be 1
    $script:urls[0] | Should -Match '/IT/_apis/wit/classificationnodes/Iterations\?api-version='
  }

  It "counts a failed create instead of abandoning the rest of the run" {
    Mock InvokeAdoRequest {
      if ($method -eq 'Post')
      {
        if ($body.name -eq 'Sprint 002') { throw "boom" }
        return $null
      }
      return (AdoTree @('Sprint 001'))
    }
    Mock WriteErrorDetail { }

    { CreateIterations } | Should -Not -Throw
    Should -Invoke InvokeAdoRequest -ParameterFilter { $method -eq 'Post' -and $body.name -eq 'Sprint 003' } -Times 1 -Exactly
  }

  # A create that returns 200 with no dates is the failure this script exists to catch, and it is
  # invisible in the create response. Only reading the node back proves the dates landed. When they
  # did not, the dates are patched onto the node this run just made and it is read once more.
  It "patches the dates onto a node it just created when the create dropped them" {
    $script:patched = @()
    $script:posted = 0
    Mock InvokeAdoRequest {
      if ($method -eq 'Post')  { $script:posted++; return $null }
      if ($method -eq 'Patch') { $script:patched += $url; return $null }
      # The single node read after the patch carries the dates; the tree read before it does not.
      if ($url -match '/Iterations/Sprint%20003\?')
      {
        return [pscustomobject]@{ name = 'Sprint 003'; attributes = [pscustomobject]@{ startDate = '2018-10-10T00:00:00Z'; finishDate = '2018-10-30T00:00:00Z' } }
      }
      # Before the create: two nodes. After it: Sprint 003 is there, but with no dates.
      $tree = AdoTree @('Sprint 001', 'Sprint 002')
      if ($script:posted) { $tree.children += [pscustomobject]@{ name = 'Sprint 003'; attributes = $null } }
      return $tree
    }

    CreateIterations

    $script:patched.Count | Should -Be 1
    $script:patched[0] | Should -Match '/Iterations/Sprint%20003\?'
    $script:totalFailed | Should -Be 0
  }

  It "counts a created node whose dates still did not land after the patch as a failure" {
    $script:posted = 0
    Mock InvokeAdoRequest {
      if ($method -eq 'Post') { $script:posted++; return $null }
      if ($method -ne 'Get')  { return $null }
      if ($url -match '/Iterations/Sprint%20003\?') { return [pscustomobject]@{ name = 'Sprint 003'; attributes = $null } }
      $tree = AdoTree @('Sprint 001', 'Sprint 002')
      if ($script:posted) { $tree.children += [pscustomobject]@{ name = 'Sprint 003'; attributes = $null } }
      return $tree
    }

    CreateIterations

    $script:totalFailed | Should -Be 1
  }

  # This script adds; it never updates. A node that was there before the run keeps whatever dates it
  # has, and the difference is reported rather than corrected or counted as a failure.
  It "never patches a node that already existed, even when its dates differ" {
    Mock InvokeAdoRequest {
      if ($method -eq 'Patch') { throw "must not patch a pre-existing node" }
      if ($method -eq 'Post')  { return $null }
      $tree = AdoTree @('Sprint 002', 'Sprint 003')
      $tree.children += [pscustomobject]@{ name = 'Sprint 001'; attributes = [pscustomobject]@{ startDate = '2001-01-01T00:00:00Z'; finishDate = '2001-01-22T00:00:00Z' } }
      return $tree
    }

    { CreateIterations } | Should -Not -Throw
    Should -Invoke InvokeAdoRequest -ParameterFilter { $method -eq 'Patch' } -Times 0 -Exactly
    $script:totalFailed | Should -Be 0
  }

  # -RepairDates is the one deliberate exception to "adds, never updates": it exists to correct the
  # 142 nodes the first version of this script created with the overlapping finish date. It patches
  # ONLY a pre-existing node whose dates are wrong, so it too is idempotent.
  It "with -RepairDates, patches only the pre-existing nodes whose dates are wrong" {
    $script:patched = @()
    Mock InvokeAdoRequest {
      if ($method -eq 'Patch') { $script:patched += $url; return $null }
      if ($method -eq 'Post')  { throw "nothing is missing, nothing should be created" }
      # Single node reads after a patch come back correct.
      if ($url -match '/Iterations/Sprint%2000[23]\?')
      {
        $n = if ($url -match '002') { 'Sprint 002' } else { 'Sprint 003' }
        $tb = (ThreeTimeboxes)[$n]
        return [pscustomobject]@{ name = $n; attributes = [pscustomobject]@{ startDate = "$($tb.Begin)T00:00:00Z"; finishDate = ([datetime]$tb.End).AddDays(-1).ToString("yyyy-MM-dd'T'00:00:00'Z'") } }
      }
      # Sprint 001 is right; 002 and 003 carry the overlapping finish (= Agility's end date).
      $tree = AdoTree @('Sprint 001')
      foreach ($n in @('Sprint 002', 'Sprint 003'))
      {
        $tb = (ThreeTimeboxes)[$n]
        $tree.children += [pscustomobject]@{ name = $n; attributes = [pscustomobject]@{ startDate = "$($tb.Begin)T00:00:00Z"; finishDate = "$($tb.End)T00:00:00Z" } }
      }
      return $tree
    }

    CreateIterations -RepairDates

    $script:patched.Count | Should -Be 2
    $script:patched[0] | Should -Match '/Iterations/Sprint%20002\?'
    $script:patched[1] | Should -Match '/Iterations/Sprint%20003\?'
    $script:totalFailed | Should -Be 0
  }

  It "with -RepairDates on a dry run, lists the nodes it would repair and patches nothing" {
    Mock InvokeAdoRequest {
      if ($method -ne 'Get') { throw "dry run must not write" }
      $tree = AdoTree @('Sprint 001')
      $tb = (ThreeTimeboxes)['Sprint 002']
      $tree.children += [pscustomobject]@{ name = 'Sprint 002'; attributes = [pscustomobject]@{ startDate = "$($tb.Begin)T00:00:00Z"; finishDate = "$($tb.End)T00:00:00Z" } }
      return $tree
    }
    $script:lines = @()
    Mock WriteLog { $script:lines += $message }

    { CreateIterations -RepairDates -DryRun } | Should -Not -Throw

    @($script:lines | Where-Object { $_ -match 'WOULD REPAIR\s+Sprint 002' }).Count | Should -Be 1
    $script:totalFailed | Should -Be 0
  }

  It "totals failures rather than exiting, so the bottom of the script can turn them into an exit code" {
    $source = Get-Content $script:scriptPath -Raw
    $body = [regex]::Match($source, "function CreateIterations\b[\s\S]*?(?=\r?\nfunction )").Value

    $body | Should -Match '\$script:totalFailed \+= \$failed'
    $body | Should -Not -Match '(?m)^\s*exit\b'
  }

  It "adds nothing to the failure total on a clean run" {
    Mock InvokeAdoRequest {
      if ($method -eq 'Post') { return $null }
      return (AdoTree @('Sprint 001', 'Sprint 002', 'Sprint 003'))
    }

    CreateIterations

    $script:totalFailed | Should -Be 0
  }
}

Describe "Air gap: self contained, GET only to Agility, no way to destroy" {

  It "loads no other script" {
    $code = CodeLines $script:scriptPath

    @($code | Where-Object { $_ -match 'Migrate-Agility|Remove-WorkItems' }) | Should -BeNullOrEmpty `
      -Because "only a comment may mention the other scripts"
    @($code | Where-Object { $_ -match '^\s*\.\s+[''"$]' }) | Should -BeNullOrEmpty `
      -Because "the iteration script must be self contained"
  }

  It "is not loaded or named by the other two scripts" {
    @((CodeLines $script:migratePath) | Where-Object { $_ -match 'Create-Iterations' }) | Should -BeNullOrEmpty
    @((CodeLines $script:removePath)  | Where-Object { $_ -match 'Create-Iterations' }) | Should -BeNullOrEmpty
  }

  # Agility is read only. The one door to it hard codes GET and takes no method.
  It "reads Agility through a door that hard codes GET" {
    $source = Get-Content $script:scriptPath -Raw
    $body = [regex]::Match($source, "function InvokeAgilityGet\b[\s\S]*?(?=\r?\nfunction )").Value

    $body | Should -Match '-Method Get\b'
    $body | Should -Not -Match '-Method \$'
    $body | Should -Not -Match '\[string\]\$method'

    # No second Invoke-RestMethod against Agility anywhere else.
    $others = [regex]::Matches($source, 'Invoke-RestMethod[^\r\n]*agilityHeaders')
    $others.Count | Should -Be 1
  }

  # This script creates classification nodes and nothing else. No work item is ever written or
  # deleted from here.
  It "sends no Delete verb and touches no work item" {
    $code = CodeLines $script:scriptPath
    $source = Get-Content $script:scriptPath -Raw

    @($code | Where-Object { $_ -match '(?i)-Method\s+["'']?Delete' -or $_ -match '(?i)InvokeAdoRequest\s+\S+\s+["'']Delete' }) |
      Should -BeNullOrEmpty
    $source | Should -Not -Match 'destroy=true'
    @($code | Where-Object { $_ -match '_apis/wit/workitems' }) | Should -BeNullOrEmpty
  }

  It "writes its own log file name" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Match 'Create-Iterations-\{0\}'
    $source | Should -Not -Match 'Migrate-Agility-\{0\}'
    $source | Should -Not -Match 'Remove-WorkItems-\{0\}'
  }

  It "guards its entry point with its own explicit flag" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Match '\$global:CreateIterationsLoadFunctionsOnly'
    $source | Should -Not -Match 'AgilityEpicsLoadFunctionsOnly'
    $source | Should -Not -Match 'RemoveWorkItemsLoadFunctionsOnly'
    @((CodeLines $script:scriptPath) | Where-Object { $_ -match '\$MyInvocation\.InvocationName' }) | Should -BeNullOrEmpty
  }
}

Describe "Logging" {

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

      if ($line -match '^if \(\$global:CreateIterationsLoadFunctionsOnly\)') { $inGuard = $true }

      if ($line -notmatch 'Write-Host') { continue }
      if ($line -match '^\s*#') { continue }
      if ($inMain -or $inLogging -or $inGuard) { continue }

      $offenders += "line $($i + 1): $($line.Trim())"
    }

    $offenders | Should -BeNullOrEmpty -Because "these should call WriteLog: $($offenders -join ' | ')"
  }

  It "is safe to log with no writer behind it" {
    $script:logWriter = $null

    { WriteLog "still talking" }         | Should -Not -Throw
    { WriteLogDetail "still recording" } | Should -Not -Throw
    { StopLog }                          | Should -Not -Throw
  }
}

Describe "Retry" {

  It "retries a failure that has no response at all" {
    $noResponse = [System.Management.Automation.ErrorRecord]::new(
      [Exception]::new("The operation has timed out"), "timeout", 'OperationTimeout', $null)

    IsTransientFailure $noResponse | Should -BeTrue
  }

  # Transient is not enough: the delay calculation that runs next must survive the missing Response
  # too, or the retry throws instead of waiting. It cost the migration an item on 2026-09-15.
  It "backs off on a failure with no response, rather than throwing" {
    $noResponse = [System.Management.Automation.ErrorRecord]::new(
      [Exception]::new("The operation has timed out"), "timeout", 'OperationTimeout', $null)

    { ResolveRetryDelay $noResponse 1 } | Should -Not -Throw
    ResolveRetryDelay $noResponse 1 | Should -Be 2
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
