##################################################################################################
# Tests for the migration script. Covers the pure functions, the parser and the hierarchy
# resolver, and the guarantee that Agility is never written to.
#
# Several tests here exist because a real dry run caught a bug that produced no error at all: a
# tag query matching zero rows, a parent link resolving to null, a one element array unrolling to
# a string. Each of those looked like success. Where a test asserts against the source text rather
# than behaviour, that is why: it pins a decision that is invisible from the outside.
##################################################################################################

BeforeAll {
  $script:scriptPath = Join-Path $PSScriptRoot ".." "src" "Migrate-Agility.ps1"

  # Load the functions without running the migration. This must be explicit: VS Code's F5 also
  # dot sources the script, so the script cannot infer a test run from how it was invoked.
  $global:AgilityEpicsLoadFunctionsOnly = $true
  . $script:scriptPath

  $script:mappings = [pscustomobject]@{
    WorkItemTypes = [pscustomobject]@{
      Epic       = "Epic"
      NestedEpic = "Feature"
    }
  }

  function NewAsset([string]$oid, [string]$number, [string]$name, [string]$superOid, [string]$areaPath = "IT")
  {
    return [pscustomobject]@{
      AgilityType = "Epic"
      Oid         = $oid
      Number      = $number
      Name        = $name
      Description = "desc"
      Estimate    = $null
      Status      = "Future"
      Priority    = "Medium"
      SuperOid    = $superOid
      AssetState  = "Active"
      AreaPath    = $areaPath
    }
  }
}

Describe "ConvertFromAgilityAssets" {

  It "parses the documented Assets/Attributes shape" {
    $response = @'
{
  "total": 1,
  "Assets": [
    {
      "id": "Epic:1001:55",
      "Attributes": {
        "Name":        { "name": "Name",        "value": "Checkout rework" },
        "Number":      { "name": "Number",      "value": "E-01001" },
        "Description": { "name": "Description", "value": "<p>html body</p>" },
        "Status.Name": { "name": "Status.Name", "value": "In Progress" }
      }
    }
  ]
}
'@ | ConvertFrom-Json

    $result = ConvertFromAgilityAssets $response

    $result.Count | Should -Be 1
    $result[0].Name | Should -Be "Checkout rework"
    $result[0].Number | Should -Be "E-01001"
    $result[0].Description | Should -Be "<p>html body</p>"
    $result[0].Status | Should -Be "In Progress"
  }

  It "reads the Created By person, which becomes the assignee for an ownerless item" {
    $response = @'
{
  "Assets": [
    {
      "id": "Epic:9418",
      "Attributes": {
        "Number":         { "name": "Number",         "value": "E-09418" },
        "CreatedBy.Name":  { "name": "CreatedBy.Name",  "value": "Sam Carter" },
        "CreatedBy.Email": { "name": "CreatedBy.Email", "value": "sam.carter@example.com" }
      }
    }
  ]
}
'@ | ConvertFrom-Json

    $result = ConvertFromAgilityAssets $response
    $result[0].CreatedByName  | Should -Be "Sam Carter"
    $result[0].CreatedByEmail | Should -Be "sam.carter@example.com"
  }

  # StrategicThemes is multi value; the DevLabs multi-value field needs the whole list, not just the
  # first. E-01169 carries four in real data.
  It "reads every StrategicTheme, not just the first, for the multi-value field" {
    $response = @'
{
  "Assets": [
    {
      "id": "Epic:1169",
      "Attributes": {
        "Number":              { "name": "Number",              "value": "E-01169" },
        "StrategicThemes.Name": { "name": "StrategicThemes.Name", "value": ["Planning", "Org - Advance Student Success"] }
      }
    }
  ]
}
'@ | ConvertFrom-Json

    $result = ConvertFromAgilityAssets $response
    @($result[0].StrategicThemes).Count | Should -Be 2
    $result[0].StrategicThemes | Should -Contain "Planning"
    $result[0].StrategicThemes | Should -Contain "Org - Advance Student Success"
  }

  It "strips the moment suffix from oids so the same asset compares equal across reads" {
    $response = @'
{ "Assets": [ { "id": "Epic:1001:55", "Attributes": {} } ] }
'@ | ConvertFrom-Json

    (ConvertFromAgilityAssets $response)[0].Oid | Should -Be "Epic:1001"
  }

  It "reads a relation through its idref and strips the moment" {
    $response = @'
{
  "Assets": [
    {
      "id": "Epic:1002",
      "Attributes": {
        "Super": { "name": "Super", "value": { "idref": "Epic:1001:9", "href": "/x" } }
      }
    }
  ]
}
'@ | ConvertFrom-Json

    (ConvertFromAgilityAssets $response)[0].SuperOid | Should -Be "Epic:1001"
  }

  It "treats a null relation as no parent" {
    $response = @'
{ "Assets": [ { "id": "Epic:1001", "Attributes": { "Super": { "name": "Super", "value": null } } } ] }
'@ | ConvertFrom-Json

    (ConvertFromAgilityAssets $response)[0].SuperOid | Should -BeNullOrEmpty
  }

  It "takes the first entry of a multi value attribute" {
    $response = @'
{
  "Assets": [
    { "id": "Epic:1", "Attributes": { "Owners.Name": { "name": "Owners.Name", "value": ["Ann", "Bob"] } } }
  ]
}
'@ | ConvertFrom-Json

    # Owners is not mapped onto the output object, but the accessor is shared by every attribute,
    # so exercise it directly.
    GetAttributeValue $response.Assets[0].Attributes "Owners.Name" | Should -Be "Ann"
  }

  It "returns empty for a response with no assets" {
    $response = '{ "total": 0, "Assets": [] }' | ConvertFrom-Json
    (ConvertFromAgilityAssets $response).Count | Should -Be 0
  }

  It "returns empty rather than throwing when the response is null" {
    (ConvertFromAgilityAssets $null).Count | Should -Be 0
  }

  It "returns null for an attribute the selection did not ask for" {
    $response = '{ "Assets": [ { "id": "Epic:1", "Attributes": {} } ] }' | ConvertFrom-Json
    (ConvertFromAgilityAssets $response)[0].Name | Should -BeNullOrEmpty
  }
}

Describe "ResolveEpicHierarchy" {

  It "maps a top level Epic to an ADO Epic with no parent" {
    $assets = @( (NewAsset "Epic:1" "E-1" "Root" $null) )

    $result = ResolveEpicHierarchy $assets $script:mappings

    $result[0].AdoType | Should -Be "Epic"
    $result[0].ParentOid | Should -BeNullOrEmpty
    $result[0].Depth | Should -Be 1
    $result[0].Flattened | Should -BeFalse
  }

  It "maps a nested Epic to a Feature parented to the root Epic" {
    $assets = @(
      (NewAsset "Epic:1" "E-1" "Root" $null),
      (NewAsset "Epic:2" "E-2" "Child" "Epic:1")
    )

    $result = ResolveEpicHierarchy $assets $script:mappings
    $child = $result | Where-Object { $_.Oid -eq "Epic:2" }

    $child.AdoType | Should -Be "Feature"
    $child.ParentOid | Should -Be "Epic:1"
    $child.Depth | Should -Be 2
    $child.Flattened | Should -BeFalse
  }

  It "flattens a grandchild Epic onto the root Epic and flags it" {
    $assets = @(
      (NewAsset "Epic:1" "E-1" "Root" $null),
      (NewAsset "Epic:2" "E-2" "Child" "Epic:1"),
      (NewAsset "Epic:3" "E-3" "Grandchild" "Epic:2")
    )

    $result = ResolveEpicHierarchy $assets $script:mappings
    $grandchild = $result | Where-Object { $_.Oid -eq "Epic:3" }

    $grandchild.AdoType | Should -Be "Feature"
    $grandchild.ParentOid | Should -Be "Epic:1"
    $grandchild.Depth | Should -Be 3
    $grandchild.Flattened | Should -BeTrue
  }

  It "never produces a same category link, which ADO would accept and then break the backlog on" {
    $assets = @(
      (NewAsset "Epic:1" "E-1" "Root" $null),
      (NewAsset "Epic:2" "E-2" "Child" "Epic:1"),
      (NewAsset "Epic:3" "E-3" "Grandchild" "Epic:2"),
      (NewAsset "Epic:4" "E-4" "Great grandchild" "Epic:3")
    )

    $result = ResolveEpicHierarchy $assets $script:mappings
    $typeByOid = @{}
    foreach ($item in $result) { $typeByOid[$item.Oid] = $item.AdoType }

    foreach ($item in $result)
    {
      if (-not $item.ParentOid) { continue }
      $typeByOid[$item.ParentOid] | Should -Not -Be $item.AdoType `
        -Because "$($item.Number) is a $($item.AdoType) parented to a $($typeByOid[$item.ParentOid])"
    }
  }

  It "treats an Epic whose parent is outside the scope as top level" {
    $assets = @( (NewAsset "Epic:2" "E-2" "Orphan" "Epic:999") )

    $result = ResolveEpicHierarchy $assets $script:mappings

    $result[0].AdoType | Should -Be "Epic"
    $result[0].ParentOid | Should -BeNullOrEmpty
  }

  It "throws on a cycle rather than looping forever" {
    $assets = @(
      (NewAsset "Epic:1" "E-1" "A" "Epic:2"),
      (NewAsset "Epic:2" "E-2" "B" "Epic:1")
    )

    { ResolveEpicHierarchy $assets $script:mappings } | Should -Throw -ExpectedMessage "*Cycle detected*"
  }

  It "orders Epics before Features so a parent id always exists when a child is created" {
    $assets = @(
      (NewAsset "Epic:3" "E-3" "Grandchild" "Epic:2"),
      (NewAsset "Epic:2" "E-2" "Child" "Epic:1"),
      (NewAsset "Epic:1" "E-1" "Root" $null)
    )

    $result = ResolveEpicHierarchy $assets $script:mappings | Sort-Object { $_.Depth }

    $result[0].AdoType | Should -Be "Epic"
    $result[0].Oid | Should -Be "Epic:1"
  }

  It "returns empty for no assets" {
    (ResolveEpicHierarchy @() $script:mappings).Count | Should -Be 0
  }
}

Describe "ResolveEpicHierarchy - true parent for flattened epics" {

  It "keeps the real parent on a flattened Epic so it is not lost" {
    $assets = @(
      (NewAsset "Epic:1" "E-1" "Root" $null),
      (NewAsset "Epic:2" "E-2" "Child" "Epic:1"),
      (NewAsset "Epic:3" "E-3" "Grandchild" "Epic:2")
    )

    $grandchild = ResolveEpicHierarchy $assets $script:mappings | Where-Object { $_.Oid -eq "Epic:3" }

    $grandchild.ParentOid | Should -Be "Epic:1" -Because "the hierarchy link must go to the root"
    $grandchild.TrueParentOid | Should -Be "Epic:2" -Because "the real parent must survive as a Related link"
  }

  It "does not differ from the hierarchy parent at depth 2, where nothing is flattened" {
    $assets = @(
      (NewAsset "Epic:1" "E-1" "Root" $null),
      (NewAsset "Epic:2" "E-2" "Child" "Epic:1")
    )

    $child = ResolveEpicHierarchy $assets $script:mappings | Where-Object { $_.Oid -eq "Epic:2" }

    $child.ParentOid | Should -Be $child.TrueParentOid
  }

  It "carries the area path from the scope the Epic was read from" {
    $assets = @(
      (NewAsset "Epic:1" "E-1" "Root" $null "IT"),
      (NewAsset "Epic:9" "E-9" "Other" $null "IT\Operations")
    )

    $result = ResolveEpicHierarchy $assets $script:mappings

    ($result | Where-Object { $_.Oid -eq "Epic:1" }).AreaPath | Should -Be "IT"
    ($result | Where-Object { $_.Oid -eq "Epic:9" }).AreaPath | Should -Be "IT\Operations"
  }
}

Describe "MapState" {

  BeforeAll {
    # Mirrors the real per-type shape in mappings.json.
    $script:mappings = [pscustomobject]@{
      States = [pscustomobject]@{
        Epic  = [pscustomobject]@{
          DefaultState = "New"; ClosedState = "Done"
          Map = [pscustomobject]@{ "In Progress" = "In Progress"; "Done" = "Done"; "Ready" = "New" }
        }
        Story = [pscustomobject]@{
          DefaultState = "New"; ClosedState = "Done"
          Map = [pscustomobject]@{ "In Progress" = "In Progress"; "Committed" = "Approved"; "Done" = "Done" }
        }
        Issue = [pscustomobject]@{
          DefaultState = "Open"; ClosedState = "Closed"
          Map = [pscustomobject]@{}
        }
      }
    }
  }

  It "maps an active Epic by its Status" {
    MapState ([pscustomobject]@{ AgilityType = "Epic"; AssetState = 64; Status = "In Progress" }) | Should -Be "In Progress"
  }

  It "falls back to the default state for an active Epic with no Status" {
    MapState ([pscustomobject]@{ AgilityType = "Epic"; AssetState = 64; Status = $null }) | Should -Be "New"
  }

  It "maps a CLOSED Epic to Done even when it has no Status at all" {
    # 385 of the 754 closed epics have an empty Status. Mapping on Status alone would recreate
    # them in ADO as active work.
    MapState ([pscustomobject]@{ AgilityType = "Epic"; AssetState = 128; Status = $null }) | Should -Be "Done"
  }

  It "maps a CLOSED Epic to Done even when its Status still says In Progress" {
    # 6 of the closed epics say In Progress. Agility closed them; ADO must not show them active.
    MapState ([pscustomobject]@{ AgilityType = "Epic"; AssetState = 128; Status = "In Progress" }) | Should -Be "Done"
  }

  It "maps a CLOSED Epic to Done even when its Status is unmapped" {
    MapState ([pscustomobject]@{ AgilityType = "Epic"; AssetState = 128; Status = "Ready" }) | Should -Be "Done"
  }

  It "treats AssetState as closed whether it arrives as a number or a string" {
    MapState ([pscustomobject]@{ AgilityType = "Epic"; AssetState = 128;   Status = $null }) | Should -Be "Done"
    MapState ([pscustomobject]@{ AgilityType = "Epic"; AssetState = "128"; Status = $null }) | Should -Be "Done"
  }

  It "does not treat an active Epic as closed" {
    IsAgilityClosed ([pscustomobject]@{ AssetState = 64 })  | Should -BeFalse
    IsAgilityClosed ([pscustomobject]@{ AssetState = 128 }) | Should -BeTrue
    IsAgilityClosed ([pscustomobject]@{ AssetState = 200 }) | Should -BeFalse
  }

  It "uses the per-type map: Story 'Committed' becomes Approved, which is not an Epic state" {
    MapState ([pscustomobject]@{ AgilityType = "Story"; AssetState = 64; Status = "Committed" }) | Should -Be "Approved"
  }

  It "maps an Issue to Open/Closed, because Impediment has no other states" {
    MapState ([pscustomobject]@{ AgilityType = "Issue"; AssetState = 64;  Status = $null }) | Should -Be "Open"
    MapState ([pscustomobject]@{ AgilityType = "Issue"; AssetState = 128; Status = $null }) | Should -Be "Closed"
  }

  It "throws for a type with no state mapping rather than inventing a state" {
    { MapState ([pscustomobject]@{ AgilityType = "Task"; AssetState = 64; Status = $null }) } |
      Should -Throw -ExpectedMessage "*No state mapping*"
  }

  It "reports whether a status was understood, so BuildTags can preserve unmapped ones" {
    IsMappedStatus ([pscustomobject]@{ AgilityType = "Story"; Status = "Committed" }) | Should -BeTrue
    IsMappedStatus ([pscustomobject]@{ AgilityType = "Story"; Status = "Vendor" })    | Should -BeFalse
    IsMappedStatus ([pscustomobject]@{ AgilityType = "Story"; Status = $null })       | Should -BeTrue
  }
}

##################################################################################################
# Work finished long ago is archived rather than shown as Done.
#
# The rule fires only on an item that would otherwise land in its type's ClosedState, so nothing
# active is ever touched, and only for a type that HAS a StaleState. Issue has none, because
# Impediment's only states are Open and Closed - the exclusion is the absence of config, not a
# hard coded type check.
##################################################################################################
Describe "Stale closed items become Removed" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{
      StaleAfterDays = 365
      States = [pscustomobject]@{
        Epic  = [pscustomobject]@{ DefaultState = "New";   ClosedState = "Done";   StaleState = "Removed"
                                   Map = [pscustomobject]@{ "In Progress" = "In Progress"; "Done" = "Done" } }
        Story = [pscustomobject]@{ DefaultState = "New";   ClosedState = "Done";   StaleState = "Removed"
                                   Map = [pscustomobject]@{ "Done" = "Done" } }
        Task  = [pscustomobject]@{ DefaultState = "To Do"; ClosedState = "Done";   StaleState = "Removed"
                                   Map = [pscustomobject]@{} }
        # No StaleState on purpose: Impediment has no Removed state to move to.
        Issue = [pscustomobject]@{ DefaultState = "Open";  ClosedState = "Closed"
                                   Map = [pscustomobject]@{} }
      }
    }

    # A fixed cutoff, so these tests do not drift as the calendar moves.
    $script:staleBefore = [datetime]"2025-01-01"

    function NewClosedItem($props)
    {
      $base = @{
        AgilityType = "Epic"; AssetState = 128; Status = $null
        ClosedDate = $null; ChangeDate = $null; CreateDate = $null
      }
      foreach ($k in $props.Keys) { $base[$k] = $props[$k] }
      return [pscustomobject]$base
    }
  }

  It "removes a closed Epic whose close date is older than the cutoff" {
    MapState (NewClosedItem @{ ClosedDate = "2019-03-04" }) | Should -Be "Removed"
  }

  It "leaves a recently closed Epic in Done" {
    MapState (NewClosedItem @{ ClosedDate = "2025-06-01" }) | Should -Be "Done"
  }

  # The trigger is the ADO state the item would land in, not AssetState. An item Agility still calls
  # active but whose Status maps to Done arrives closed in ADO, and is archived on the same rule.
  It "removes a Story that reached Done through its Status rather than its AssetState" {
    MapState (NewClosedItem @{ AgilityType = "Story"; AssetState = 64; Status = "Done"; ClosedDate = "2019-03-04" }) |
      Should -Be "Removed"
  }

  It "never removes an Issue, because Impediment has no Removed state" {
    MapState (NewClosedItem @{ AgilityType = "Issue"; ClosedDate = "2010-01-01" }) | Should -Be "Closed"
  }

  It "leaves unfinished work alone however old it is" {
    MapState (NewClosedItem @{ AssetState = 64; Status = "In Progress"; CreateDate = "2005-01-01" }) |
      Should -Be "In Progress"
  }

  # Not every closed item carries a real ClosedDate, which is already why the closing transition
  # falls back this way for Tasks. Same chain here, for the same reason.
  It "falls back to the change date when Agility has no close date" {
    MapState (NewClosedItem @{ ChangeDate = "2019-03-04" }) | Should -Be "Removed"
  }

  It "falls back to the create date when there is neither" {
    MapState (NewClosedItem @{ CreateDate = "2019-03-04" }) | Should -Be "Removed"
  }

  # No date at all means no evidence of age. Leaving it Done under-removes; inventing an age would
  # archive work that might be current.
  It "leaves a closed item with no date at all in Done rather than inventing an age" {
    MapState (NewClosedItem @{}) | Should -Be "Done"
  }

  It "prefers the real close date over the change date" {
    ResolveDoneDate (NewClosedItem @{ ClosedDate = "2019-03-04"; ChangeDate = "2026-01-01" }) |
      Should -Be ([datetime]"2019-03-04")
  }

  It "returns no done date for an item that carries none" {
    ResolveDoneDate (NewClosedItem @{}) | Should -BeNullOrEmpty
  }

  It "treats an item closed exactly on the cutoff as not yet stale" {
    MapState (NewClosedItem @{ ClosedDate = "2025-01-01" }) | Should -Be "Done"
  }

  # Every other entry point (CreateAreaPaths, the unit tests, a mappings file with no StaleAfterDays)
  # leaves the cutoff unset, and must behave exactly as it did before this rule existed.
  It "removes nothing when no cutoff is set, so the rule is off unless a run configures it" {
    $saved = $script:staleBefore
    $script:staleBefore = $null
    try     { MapState (NewClosedItem @{ ClosedDate = "2010-01-01" }) | Should -Be "Done" }
    finally { $script:staleBefore = $saved }
  }
}

Describe "ResolveStaleCutoff" {

  It "counts StaleAfterDays back from the run start" {
    $script:mappings = [pscustomobject]@{ StaleAfterDays = 365 }
    ResolveStaleCutoff ([datetime]"2026-07-30") | Should -Be ([datetime]"2025-07-30")
  }

  It "returns null when StaleAfterDays is absent, so an unconfigured run removes nothing" {
    $script:mappings = [pscustomobject]@{}
    ResolveStaleCutoff ([datetime]"2026-07-30") | Should -BeNullOrEmpty
  }

  # A zero would make the cutoff "now" and archive every closed item in the instance.
  It "returns null for a zero or negative StaleAfterDays rather than removing everything" {
    $script:mappings = [pscustomobject]@{ StaleAfterDays = 0 }
    ResolveStaleCutoff ([datetime]"2026-07-30") | Should -BeNullOrEmpty

    $script:mappings = [pscustomobject]@{ StaleAfterDays = -1 }
    ResolveStaleCutoff ([datetime]"2026-07-30") | Should -BeNullOrEmpty
  }
}

##################################################################################################
# Removed accepts a Closed Date and does not require one - verified live on Epic, Product Backlog
# Item, Bug and Task (bypass transition to Removed with a date, then a rule-checked patch: all
# passed, the date read back, and an empty one passed too). So the real Agility close date rides
# along, and nothing is ever fabricated for it.
##################################################################################################
Describe "The close date rides along on a Removed transition" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{
      Fields = [pscustomobject]@{ ClosedDate = "Microsoft.VSTS.Common.ClosedDate" }
      States = [pscustomobject]@{
        Epic = [pscustomobject]@{ DefaultState = "New";   ClosedState = "Done"; StaleState = "Removed"; Map = [pscustomobject]@{} }
        Task = [pscustomobject]@{ DefaultState = "To Do"; ClosedState = "Done"; StaleState = "Removed"; Map = [pscustomobject]@{} }
      }
    }
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/org" } }

    function NewRemovedItem($props)
    {
      $base = @{
        AgilityType = "Epic"; ChangedByEmail = $null; ChangedByName = $null
        CreatedByEmail = "creator@example.com"; CreatedByName = $null
        CreateDate = "2020-01-01"; ChangeDate = "2020-06-01"; ClosedDate = $null
      }
      foreach ($k in $props.Keys) { $base[$k] = $props[$k] }
      return [pscustomobject]$base
    }

    function RemovedClosedOp($item, $state)
    {
      $script:sent = $null
      Mock InvokeAdoRequest { $script:sent = [pscustomobject]@{ Url = $url; Body = $body } }
      SetAdoState 42 $state $item
      return @($script:sent.Body | Where-Object { $_.path -eq "/fields/Microsoft.VSTS.Common.ClosedDate" })[0]
    }
  }

  It "recognises the type's stale ADO state" {
    IsStaleAdoState ([pscustomobject]@{ AgilityType = "Epic" }) "Removed" | Should -BeTrue
    IsStaleAdoState ([pscustomobject]@{ AgilityType = "Epic" }) "Done"    | Should -BeFalse
  }

  It "does not call a type with no stale state removed" {
    $script:mappings.States | Add-Member -NotePropertyName Issue `
      -NotePropertyValue ([pscustomobject]@{ DefaultState = "Open"; ClosedState = "Closed"; Map = [pscustomobject]@{} }) -Force

    IsStaleAdoState ([pscustomobject]@{ AgilityType = "Issue" }) "Removed" | Should -BeFalse
  }

  It "writes the real Agility close date on a Removed transition" {
    $op = RemovedClosedOp (NewRemovedItem @{ ClosedDate = "2019-03-04" }) "Removed"

    $op | Should -Not -BeNullOrEmpty
    $op.value | Should -BeLike "2019-03-04T*Z"
    $script:sent.Url | Should -BeLike "*bypassRules=true*"
  }

  # Removed does not require a close date on any type, verified live - so unlike Task's Done, an
  # absent one is left absent rather than fabricated from the change date.
  It "does not fabricate a close date for a Task sent to Removed" {
    RemovedClosedOp (NewRemovedItem @{ AgilityType = "Task"; ClosedDate = $null; ChangeDate = "2020-06-01" }) "Removed" |
      Should -BeNullOrEmpty
  }

  It "still fabricates one for a Task sent to Done, which does require it" {
    $op = RemovedClosedOp (NewRemovedItem @{ AgilityType = "Task"; ClosedDate = $null; ChangeDate = "2020-06-01" }) "Done"

    $op | Should -Not -BeNullOrEmpty
    $op.value | Should -BeLike "2020-06-01T*Z"
  }
}

##################################################################################################
# A typo in StaleState must fail on call one, not on item one of tens of thousands. This is also
# what stops anyone giving Issue a StaleState: Impediment has no Removed, so the run dies here.
##################################################################################################
Describe "AssertStatesExist proves the stale state too" {

  BeforeAll {
    $script:config = [pscustomobject]@{
      AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/org"; Project = "Migration" }
    }
    $script:mappings = [pscustomobject]@{
      WorkItemTypes = [pscustomobject]@{ Story = "Product Backlog Item" }
      States = [pscustomobject]@{
        Story = [pscustomobject]@{ DefaultState = "New"; ClosedState = "Done"; StaleState = "Removed"
                                   Map = [pscustomobject]@{ "Done" = "Done" } }
      }
    }
  }

  It "throws when the work item type does not have the configured stale state" {
    Mock InvokeAdoRequest { [pscustomobject]@{ value = @(
      [pscustomobject]@{ name = "New" }, [pscustomobject]@{ name = "Done" }) } }

    { AssertStatesExist @('Story') } | Should -Throw -ExpectedMessage "*Removed*"
  }

  It "passes when it does" {
    Mock InvokeAdoRequest { [pscustomobject]@{ value = @(
      [pscustomobject]@{ name = "New" }, [pscustomobject]@{ name = "Done" }, [pscustomobject]@{ name = "Removed" }) } }

    { AssertStatesExist @('Story') } | Should -Not -Throw
  }
}

Describe "ResolveAreaPath" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{
      ThemeAreaPaths = [pscustomobject]@{
        "Applications" = "Apps"
        "Systems"      = "System"
        "Audio Visual" = "AV"
      }
    }
  }

  It "puts a themed Story under the theme's area path leaf" {
    ResolveAreaPath "IT\Operations" "Applications" | Should -Be "IT\Operations\Apps"
  }

  It "translates the theme name, which does not match the ADO node name" {
    ResolveAreaPath "IT\Operations" "Systems"      | Should -Be "IT\Operations\System"
    ResolveAreaPath "IT\User Services" "Audio Visual" | Should -Be "IT\User Services\AV"
  }

  It "falls back to the scope's area path when the Story has no Theme" {
    # 98 open Stories have no Theme at all.
    ResolveAreaPath "IT\Operations" $null | Should -Be "IT\Operations"
    ResolveAreaPath "IT\Operations" ""    | Should -Be "IT\Operations"
  }

  It "falls back rather than inventing a node for an unmapped Theme" {
    ResolveAreaPath "IT\Operations" "Some Other Theme" | Should -Be "IT\Operations"
  }
}

##################################################################################################
# The Team is the LAST resort for an area path, used only when an item would otherwise land at the
# project root. Measured across all 53,655 items: 122 land at root, and 30 of those carry a Team.
#
# The map is EXACT, never a substring or prefix match. "User Services - Sprint" contains the node
# name "User Services", so a prefix match would look right and then be wrong the moment a team is
# named after something that is not a node. Each entry below is evidence: every mapped team has
# 99.8-100% of its work in the scope it maps to.
##################################################################################################
Describe "Team as an area path fallback" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{
      ThemeAreaPaths = [pscustomobject]@{ "Applications" = "Apps" }
      TeamAreaPaths  = [pscustomobject]@{
        "IT_Operations"            = "Operations"
        "Operations"               = "Operations"
        "ITUser Services - Sprint" = "User Services"
        "User Services - Sprint"   = "User Services"
      }
      TeamValueMap = [pscustomobject]@{
        "IT_Operations"            = "Operations"
        "ITUser Services - Sprint" = "User Services - Sprint"
      }
    }
  }

  It "deduces the area path from the Team when the item would land at the root" {
    ResolveAreaPath "" $null "IT_Operations" | Should -Be "Operations"
  }

  # The user reads the ADO Team field, which shows the CLEANED name, so both spellings resolve.
  It "accepts the cleaned team name as well as the raw one" {
    ResolveAreaPath "" $null "Operations" | Should -Be "Operations"
  }

  # The exact hazard called out: this team's NAME contains a node name, and it must resolve by the
  # map rather than by anything that looks at the text.
  It "maps a team whose name contains a node name, without matching on the text" {
    ResolveAreaPath "" $null "ITUser Services - Sprint" | Should -Be "User Services"
    ResolveAreaPath "" $null "User Services - Sprint"   | Should -Be "User Services"
  }

  It "leaves the item at the root when the team is not in the map" {
    ResolveAreaPath "" $null "Reg Scrum" | Should -Be ""
  }

  It "leaves the item at the root when it has no team at all" {
    ResolveAreaPath "" $null $null | Should -Be ""
    ResolveAreaPath "" $null ""    | Should -Be ""
  }

  # The scope is better evidence than the team, so it must never be overridden.
  It "never overrides a scope that already has an area path" {
    ResolveAreaPath "User Services" $null "IT_Operations" | Should -Be "User Services"
  }

  # And the Theme is better evidence still.
  It "never overrides a theme leaf" {
    ResolveAreaPath "Operations" "Applications" "ITUser Services - Sprint" | Should -Be "Operations\Apps"
  }

  # A themed item in the ROOT scope would otherwise resolve to a bare leaf with no parent node, which
  # ADO rejects with TF401347. There are none today, but the team gives it a real home if one appears.
  It "prefers the team over a bare leaf when the scope is the root" {
    ResolveAreaPath "" "Applications" "IT_Operations" | Should -Be "Operations\Apps"
  }

  It "resolves a team to its area path, or null when unmapped" {
    ResolveTeamAreaPath "IT_Operations" | Should -Be "Operations"
    ResolveTeamAreaPath "Reg Scrum"     | Should -BeNullOrEmpty
    ResolveTeamAreaPath $null           | Should -BeNullOrEmpty
  }
}

Describe "BuildTags" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{
      States = [pscustomobject]@{
        Story = [pscustomobject]@{
          DefaultState = "New"; ClosedState = "Done"
          Map = [pscustomobject]@{ "In Progress" = "In Progress" }
        }
      }
    }

    # Must live in BeforeAll: Pester 5 runs the Describe body during discovery, so a function
    # defined there is not in scope inside It.
    function NewTagItem($props)
    {
      $base = @{ AgilityType = "Story"; Number = "E-1"; OwnerNames = @(); Status = $null }
      foreach ($k in $props.Keys) { $base[$k] = $props[$k] }
      return [pscustomobject]$base
    }
  }

  # The Number is Custom.DigitalAIID now, not a tag. BuildFieldPatch sets it; a tag would
  # be a second, drifting copy of the same fact.
  It "no longer tags the agility Number, which is a real field now" {
    BuildTags (NewTagItem @{}) | Should -Not -BeLike "*agility:E-1*"
  }

  # Owners, team, mandate, strategic theme and resolution reason all became Custom.DigitalAI* fields
  # on 2026-07-17; sprint is the iteration path. None of them is a tag any more.
  It "no longer tags the fields that became custom fields" {
    $tags = BuildTags (NewTagItem @{
      OwnerNames = @("Jane Doe", "Bob Smith"); OwnerEmails = @()
      Team = "IT"; Mandate = "M"; StrategicTheme = "T"; Timebox = "Sprint 1"; ResolutionReason = "Duplicate"
    })

    $tags | Should -Not -BeLike "*agility-owner*"
    $tags | Should -Not -BeLike "*agility-team*"
    $tags | Should -Not -BeLike "*agility-mandate*"
    $tags | Should -Not -BeLike "*agility-theme*"
    $tags | Should -Not -BeLike "*agility-sprint*"
    $tags | Should -Not -BeLike "*agility-resolution-reason*"
  }

  # Source is the exception: the user asked to keep a Defect's Source as a tag, not a field and not
  # in the description. Defect only (only Defect carries a Source), 23 of 706.
  It "tags a Defect's Source, which the user kept as a tag" {
    BuildTags (NewTagItem @{ Source = "Employees" }) | Should -BeLike "*agility-source:Employees*"
  }

  # Category and the fiscal year moved to Custom.DigitalAICategory and
  # Custom.DigitalAIFY. BuildFieldPatch writes them; a tag would be a drifting second copy.
  It "no longer tags Category or the fiscal year, which are real fields now" {
    $tags = BuildTags (NewTagItem @{ Category = "Applications"; FiscalYear = "FY 23" })

    $tags | Should -Not -BeLike "*agility-category*"
    $tags | Should -Not -BeLike "*agility-fy*"
  }

  # An item whose parent Epic lives in a scope that is not configured has no ADO parent to link to,
  # so the link cannot be made. Without the tag, nothing would record that the item ever had a
  # parent.
  It "tags an Agility parent that is not in ADO, since the link cannot be made" {
    $item = NewTagItem @{ ParentUnresolved = $true; ParentNumberForTag = "E-02581" }

    BuildTags $item | Should -BeLike "*agility-parent:E-02581*"
  }

  It "does not tag the parent when the link WAS made, since the link already says it" {
    $item = NewTagItem @{ ParentUnresolved = $false; ParentNumberForTag = "E-01330" }

    BuildTags $item | Should -Not -BeLike "*agility-parent*"
  }

  # The other thing still written as a tag: a blocked work item outside the configured scopes, whose
  # Affects link cannot be made, so the number is kept for later recovery.
  It "tags a blocked work item that is not in ADO" {
    $tags = BuildTags (NewTagItem @{ BlockedUnresolved = @("S-03703", "D-01966") })

    $tags | Should -BeLike "*agility-blocks:S-03703*"
    $tags | Should -BeLike "*agility-blocks:D-01966*"
  }

  # The raw status goes to Custom.DigitalAIStatus on every item now, mapped or not, which
  # is strictly more than the old tag carried: it only appeared when the status did NOT map.
  It "no longer tags the status, mapped or unmapped, since the raw value is a field now" {
    BuildTags (NewTagItem @{ Status = "Vendor" })      | Should -Not -BeLike "*agility-status*"
    BuildTags (NewTagItem @{ Status = "In Progress" }) | Should -Not -BeLike "*agility-status*"
  }

  # Only parent and blocks are tags now, so an item with neither gets no tags at all. BuildFieldPatch
  # must therefore not send an empty System.Tags.
  It "produces no tags at all for an item with nothing worth tagging" {
    BuildTags (NewTagItem @{ ParentUnresolved = $false; BlockedUnresolved = @() }) | Should -BeNullOrEmpty
  }
}

Describe "BuildAgilityDetails: the metadata block appended to the description" {

  BeforeAll {
    # Must live in BeforeAll: Pester 5 runs the Describe body at discovery time.
    function NewDetailItem($props)
    {
      $base = @{ AgilityType = "Story"; OwnerNames = @(); OwnerEmails = @(); Timebox = $null }
      foreach ($k in $props.Keys) { $base[$k] = $props[$k] }
      return [pscustomobject]$base
    }
  }

  # As of 2026-07-17 owners/team/mandate/strategic theme/resolution reason all became
  # Custom.DigitalAI* fields and source became a tag, so the ONLY line left in this block is the
  # sprint (the Agility Timebox).
  It "carries the sprint, the one piece of metadata still shown here" {
    $d = BuildAgilityDetails (NewDetailItem @{ Timebox = "Sprint 138" })

    $d | Should -BeLike "*Sprint: Sprint 138*"
  }

  It "no longer lists owners, team, mandate, strategic theme or resolution reason here" {
    $d = BuildAgilityDetails (NewDetailItem @{
      OwnerNames = @("Alex Rivera", "Robin Hale"); OwnerEmails = @("alex@example.com")
      Team = "IT_Operations"; Mandate = "Federal"; StrategicTheme = "Planning"; ResolutionReason = "Duplicate"
      Timebox = "Sprint 138"
    })

    $d | Should -Not -BeLike "*owners*"
    $d | Should -Not -BeLike "*Team:*"
    $d | Should -Not -BeLike "*Mandate:*"
    $d | Should -Not -BeLike "*Strategic theme:*"
    $d | Should -Not -BeLike "*Resolution reason:*"
  }

  It "wraps the sprint in one 'Agility details' block, not several" {
    $d = BuildAgilityDetails (NewDetailItem @{ Timebox = "Sprint 138" })

    ($d | Select-String -Pattern 'Agility details' -AllMatches).Matches.Count | Should -Be 1
    ([regex]::Matches($d, '<hr />')).Count | Should -Be 1 -Because "one block means one divider"
  }

  It "html encodes the value so markup cannot break the description" {
    $d = BuildAgilityDetails (NewDetailItem @{ Timebox = "Sprint <b>x</b>" })

    $d | Should -BeLike "*Sprint &lt;b&gt;x&lt;/b&gt;*"
    $d | Should -Not -BeLike "*<b>x</b>*"
  }

  It "returns nothing when there is no sprint to show" {
    BuildAgilityDetails (NewDetailItem @{}) | Should -BeNullOrEmpty
  }
}

Describe "Agility id and status go to fields, not tags" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{
      RequiredFields = [pscustomobject]@{
        AgilityId       = "Custom.DigitalAIID"
        AgilityStatus   = "Custom.DigitalAIStatus"
        AgilityCategory = "Custom.DigitalAICategory"
        AgilityFY       = "Custom.DigitalAIFY"
      }
      CustomFields = [pscustomobject]@{
        Owners               = [pscustomobject]@{ Field = "Custom.DigitalAIOwners";               AdoTypes = @("Epic", "Feature", "Product Backlog Item", "Bug", "Task", "Impediment") }
        Team                 = [pscustomobject]@{ Field = "Custom.DigitalAITeam";                 AdoTypes = @("Epic", "Feature", "Product Backlog Item", "Bug", "Task", "Impediment") }
        Mandate              = [pscustomobject]@{ Field = "Custom.DigitalAIMandate";              AdoTypes = @("Epic", "Feature") }
        StrategicTheme       = [pscustomobject]@{ Field = "Custom.DigitalAIStrategicTheme";       AdoTypes = @("Epic", "Feature") }
        BugResolution        = [pscustomobject]@{ Field = "Custom.DigitalAIBugResolution";        AdoTypes = @("Bug") }
        ImpedimentResolution = [pscustomobject]@{ Field = "Custom.DigitalAIImpedimentResolution"; AdoTypes = @("Impediment") }
      }
      TeamValueMap = [pscustomobject]@{
        "IT_Operations" = "Operations"; "IT_Kanban" = "IT - Kanban"; "AV - Kanban" = "AV - Kanban"
      }
      StrategicThemeValueMap = [pscustomobject]@{
        "Planning" = "Planning"
        "Org - Advance Student Success" = "Org - Advance Student Success"
        "IT Develop Implement IT Architecture" = "IT - Develop and Implement IT organizational architecture"
        "IT - Develop and Implement IT organizational architecture" = "IT - Develop and Implement IT organizational architecture"
        "IT - Facilitate and implement Business of organizationa Frame" = "IT - Facilitate and implement Business of organizational Framework"
        "Org - Initiate Connections & Partnerships to Support Economic Development & Meet Community Needs" = "Org - Initiate Connections & Partnerships to Support Economic Development & Meet Community Needs"
        "Org - Demonstrate Fiscal Stability and Sustainability" = "Org - Demonstrate Fiscal Stability and Sustainability"
        "Org - Ensure Operational Sustainability and Compliance" = "Org - Ensure Operational Sustainability and Compliance"
        "Org - Foster Respectful Community & Be a Model for Organizational Diversity" = "Org - Foster Respectful Community & Be a Model for Organizational Diversity"
      }
      Fields = [pscustomobject]@{
        Estimate = "Microsoft.VSTS.Scheduling.Effort"; TaskEstimate = "Microsoft.VSTS.Scheduling.RemainingWork"
        Resolution = "Microsoft.VSTS.Common.Resolution"; BusinessValue = "Microsoft.VSTS.Common.BusinessValue"
        ClosedDate = "Microsoft.VSTS.Common.ClosedDate"
        Environment = "Microsoft.VSTS.TCM.SystemInfo"; FoundInBuild = "Microsoft.VSTS.Build.FoundIn"
      }
      States = [pscustomobject]@{
        Epic = [pscustomobject]@{ DefaultState = "New"; ClosedState = "Done"; Map = [pscustomobject]@{ "In Progress" = "In Progress" } }
      }
      Priorities = [pscustomobject]@{ DefaultPriority = 2; Map = [pscustomobject]@{} }
    }
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ Project = "Migration" } }
    $script:numberByOid = @{}
    $script:fieldWarnings = @()

    function NewFieldItem($props)
    {
      $base = @{
        AgilityType = "Epic"; Number = "E-06527"; Name = "an epic"; AdoType = "Epic"
        AssetState = "64"; Status = "In Progress"; Description = ""; ClosedDate = $null
        OwnerNames = @(); OwnerEmails = @(); Estimate = $null; Order = $null; Priority = $null
        AreaPath = ""; Timebox = $null; Environment = $null; FoundInBuild = $null
        Resolution = $null; ResolutionReason = $null; BusinessValue = $null
        Category = $null; FiscalYear = $null; Flattened = $false; TrueParentOid = $null
        Team = $null; Mandate = $null; StrategicThemes = @(); Source = $null
      }
      foreach ($k in $props.Keys) { $base[$k] = $props[$k] }
      return [pscustomobject]$base
    }
  }

  It "writes the Agility Number to Custom.DigitalAIID" {
    $patch = BuildFieldPatch (NewFieldItem @{})

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIID" }).value | Should -Be "E-06527"
  }

  # The RAW status, not the mapped state. MapState collapses 393 finished Epics with no Status, and
  # junk like "Systems" and "Vendor", onto a handful of ADO states. This field is the before.
  It "writes the RAW Agility status, not the mapped ADO state" {
    $patch = BuildFieldPatch (NewFieldItem @{ Status = "Vendor" })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIStatus" }).value | Should -Be "Vendor"
  }

  It "writes an empty status rather than skipping the field, so the field always means something" {
    $patch = BuildFieldPatch (NewFieldItem @{ Status = $null })

    $f = $patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIStatus" }
    $f | Should -Not -BeNullOrEmpty
    $f.value | Should -Be ""
  }

  It "never puts the Number or the status in the tags" {
    $tagPatch = (BuildFieldPatch (NewFieldItem @{ Status = "Vendor"; Category = "X" })) |
                  Where-Object { $_.path -eq "/fields/System.Tags" }

    $tagPatch.value | Should -Not -BeLike "*E-06527*"
    $tagPatch.value | Should -Not -BeLike "*agility-status*"
  }

  # Category was an agility-category: tag until the user added Custom.DigitalAICategory to
  # every type. A tag would be a second, drifting copy of the same fact.
  It "writes the Agility Category to Custom.DigitalAICategory" {
    $patch = BuildFieldPatch (NewFieldItem @{ Category = "Applications" })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAICategory" }).value | Should -Be "Applications"
  }

  # Mirrors the raw-status field: always present, so a query on it always means something and an
  # item with no Category is distinguishable from one never migrated.
  It "writes an empty Category rather than skipping the field" {
    $patch = BuildFieldPatch (NewFieldItem @{ Category = $null })

    $f = $patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAICategory" }
    $f | Should -Not -BeNullOrEmpty
    $f.value | Should -Be ""
  }

  It "writes the Agility fiscal year to Custom.DigitalAIFY" {
    $patch = BuildFieldPatch (NewFieldItem @{ FiscalYear = "FY 23" })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIFY" }).value | Should -Be "FY 23"
  }

  It "writes an empty fiscal year rather than skipping the field" {
    $patch = BuildFieldPatch (NewFieldItem @{ FiscalYear = $null })

    $f = $patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIFY" }
    $f | Should -Not -BeNullOrEmpty
    $f.value | Should -Be ""
  }

  It "never puts the Category or the fiscal year in the tags" {
    $tagPatch = (BuildFieldPatch (NewFieldItem @{ Category = "Applications"; FiscalYear = "FY 23" })) |
                  Where-Object { $_.path -eq "/fields/System.Tags" }

    $tagPatch.value | Should -Not -BeLike "*agility-category*"
    $tagPatch.value | Should -Not -BeLike "*agility-fy*"
  }

  # BuildTags can now return nothing at all, and an empty System.Tags is not worth sending.
  It "omits System.Tags entirely when there is nothing to tag" {
    $patch = BuildFieldPatch (NewFieldItem @{})

    ($patch | Where-Object { $_.path -eq "/fields/System.Tags" }) | Should -BeNullOrEmpty
  }

  It "maps Agility Epic Value to Business Value" {
    $patch = BuildFieldPatch (NewFieldItem @{ BusinessValue = 40 })

    ($patch | Where-Object { $_.path -eq "/fields/Microsoft.VSTS.Common.BusinessValue" }).value | Should -Be 40
  }

  # Bug, Task and Impediment have no Business Value field, and ADO would drop it silently rather
  # than complain, so this has to be gated on the type and not just on the value being present.
  It "does not send Business Value for a type that has no such field" {
    $patch = BuildFieldPatch (NewFieldItem @{ AgilityType = "Defect"; BusinessValue = 40 })

    ($patch | Where-Object { $_.path -like "*BusinessValue*" }) | Should -BeNullOrEmpty
  }

  # ---- Custom.DigitalAIOwners: the owners who are NOT the assignee, comma separated ----
  It "writes the non-assignee owners to Custom.DigitalAIOwners" {
    $patch = BuildFieldPatch (NewFieldItem @{
      OwnerNames = @("Alex Rivera", "Robin Hale", "Kim Lee"); OwnerEmails = @("alex@example.com")
    })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIOwners" }).value | Should -Be "Robin Hale, Kim Lee"
  }

  It "does not write the owners field when the only owner is the assignee" {
    $patch = BuildFieldPatch (NewFieldItem @{ OwnerNames = @("Solo"); OwnerEmails = @("solo@example.com") })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIOwners" }) | Should -BeNullOrEmpty
  }

  # ---- Custom.DigitalAITeam: normalized through TeamValueMap, Epic only ----
  It "writes the mapped Team to Custom.DigitalAITeam" {
    $patch = BuildFieldPatch (NewFieldItem @{ Team = "IT_Operations" })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAITeam" }).value | Should -Be "Operations"
  }

  # The user added Team to every WIT on 2026-07-17, so a non-Epic type now writes it too.
  It "writes Team on a non-Epic type, now that the field is on every WIT" {
    $patch = BuildFieldPatch (NewFieldItem @{ AgilityType = "Story"; AdoType = "Product Backlog Item"; Team = "IT_Operations" })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAITeam" }).value | Should -Be "Operations"
  }

  It "records a Team value the map has never seen as a warning rather than writing it" {
    $script:fieldWarnings = @()
    $patch = BuildFieldPatch (NewFieldItem @{ Number = "E-99"; Team = "Brand New Team" })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAITeam" }) | Should -BeNullOrEmpty
    $script:fieldWarnings.Count | Should -Be 1
    $script:fieldWarnings[0].Raw | Should -Be "Brand New Team"
    $script:fieldWarnings[0].Id  | Should -Be "E-99"
  }

  It "matches the Team map case sensitively, so a different case is a warning, not a silent pass" {
    $script:fieldWarnings = @()
    BuildFieldPatch (NewFieldItem @{ Team = "it_operations" }) | Out-Null

    $script:fieldWarnings.Count | Should -Be 1 -Because "the map key is IT_Operations, not it_operations"
  }

  # ---- Custom.DigitalAIMandate: Epic only ----
  It "writes Mandate to Custom.DigitalAIMandate on an Epic" {
    $patch = BuildFieldPatch (NewFieldItem @{ Mandate = "Federal" })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIMandate" }).value | Should -Be "Federal"
  }

  # The user added Mandate to the Feature WIT on 2026-07-17, so a nested Agility Epic keeps it.
  It "writes Mandate to a Feature now that the field was added there" {
    $patch = BuildFieldPatch (NewFieldItem @{ AdoType = "Feature"; Mandate = "Federal" })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIMandate" }).value | Should -Be "Federal"
  }

  It "does not write Mandate to a Product Backlog Item, which still has no such field" {
    $patch = BuildFieldPatch (NewFieldItem @{ AgilityType = "Story"; AdoType = "Product Backlog Item"; Mandate = "Federal" })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIMandate" }) | Should -BeNullOrEmpty
  }

  # ---- Custom.DigitalAIStrategicTheme: multi value, corrected + deduped ----
  It "writes all mapped strategic themes as a semicolon separated string" {
    $patch = BuildFieldPatch (NewFieldItem @{ StrategicThemes = @("Planning", "Org - Advance Student Success") })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIStrategicTheme" }).value |
      Should -Be "Planning; Org - Advance Student Success"
  }

  # E-01169 is the real case: it carries the duplicate AND the goal it consolidates onto, so after
  # mapping the two collapse to one entry rather than repeating.
  It "collapses a consolidated duplicate onto its target theme, once" {
    $patch = BuildFieldPatch (NewFieldItem @{ StrategicThemes = @(
      "IT Develop Implement IT Architecture", "IT - Develop and Implement IT organizational architecture") })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIStrategicTheme" }).value |
      Should -Be "IT - Develop and Implement IT organizational architecture"
  }

  It "applies the spelling correction to a strategic theme" {
    $patch = BuildFieldPatch (NewFieldItem @{ StrategicThemes = @(
      "IT - Facilitate and implement Business of organizationa Frame") })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIStrategicTheme" }).value |
      Should -Be "IT - Facilitate and implement Business of organizational Framework"
  }

  # The multi-value control's string field caps at 255. Rather than let ADO reject the whole create
  # (TF401324, as E-04968's 315-char list did), keep the themes that fit and record the dropped ones.
  It "keeps the themes that fit in 255 chars and records the overflow rather than failing" {
    $script:fieldWarnings = @()
    $long = @(
      "Org - Advance Student Success"
      "Org - Initiate Connections & Partnerships to Support Economic Development & Meet Community Needs"
      "Org - Demonstrate Fiscal Stability and Sustainability"
      "Org - Ensure Operational Sustainability and Compliance"
      "Org - Foster Respectful Community & Be a Model for Organizational Diversity"
    )

    $patch = BuildFieldPatch (NewFieldItem @{ Number = "E-04968"; StrategicThemes = $long })
    $written = ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIStrategicTheme" }).value

    $written.Length | Should -BeLessOrEqual 255
    $written | Should -BeLike "Org - Advance Student Success*" -Because "themes are kept in order until the cap"
    ($script:fieldWarnings | Where-Object { $_.Id -eq "E-04968" -and $_.Map -like "*over 255*" }) | Should -Not -BeNullOrEmpty
  }

  # On overflow the FULL list is appended to the description under "Strategic Themes", so nothing is
  # lost even though the field only holds what fit.
  It "appends ALL themes to the description under 'Strategic Themes' when they overflow" {
    $long = @(
      "Org - Advance Student Success"
      "Org - Initiate Connections & Partnerships to Support Economic Development & Meet Community Needs"
      "Org - Demonstrate Fiscal Stability and Sustainability"
      "Org - Ensure Operational Sustainability and Compliance"
      "Org - Foster Respectful Community & Be a Model for Organizational Diversity"
    )
    $desc = (BuildFieldPatch (NewFieldItem @{ Number = "E-04968"; StrategicThemes = $long }) | Where-Object { $_.path -eq "/fields/System.Description" }).value

    $desc | Should -BeLike "*Strategic Themes:*"
    foreach ($t in $long) { $desc | Should -BeLike "*$([System.Net.WebUtility]::HtmlEncode($t))*" -Because "every theme must survive in the description" }
  }

  It "does not add the Strategic Themes description block when the themes fit" {
    $desc = (BuildFieldPatch (NewFieldItem @{ StrategicThemes = @("Planning") }) | Where-Object { $_.path -eq "/fields/System.Description" }).value

    $desc | Should -Not -BeLike "*Strategic Themes:*"
  }

  It "does not write the theme field on a type that lacks it" {
    $patch = BuildFieldPatch (NewFieldItem @{ AgilityType = "Story"; AdoType = "Product Backlog Item"; StrategicThemes = @("Planning") })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIStrategicTheme" }) | Should -BeNullOrEmpty
  }

  # ---- ResolutionReason routes to a different field per type ----
  It "writes a Defect's ResolutionReason to Custom.DigitalAIBugResolution" {
    $patch = BuildFieldPatch (NewFieldItem @{ AgilityType = "Defect"; AdoType = "Bug"; ResolutionReason = "Fixed" })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIBugResolution" }).value | Should -Be "Fixed"
  }

  It "writes an Issue's ResolutionReason to Custom.DigitalAIImpedimentResolution" {
    $patch = BuildFieldPatch (NewFieldItem @{ AgilityType = "Issue"; AdoType = "Impediment"; ResolutionReason = "No Action" })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIImpedimentResolution" }).value | Should -Be "No Action"
  }

  It "does not cross the resolution fields: a Defect never writes the Impediment field" {
    $patch = BuildFieldPatch (NewFieldItem @{ AgilityType = "Defect"; AdoType = "Bug"; ResolutionReason = "Fixed" })

    ($patch | Where-Object { $_.path -eq "/fields/Custom.DigitalAIImpedimentResolution" }) | Should -BeNullOrEmpty
  }

  # A Defect's Source is a tag now, not the description and not a field.
  It "writes a Defect's Source as an agility-source tag" {
    $patch = BuildFieldPatch (NewFieldItem @{ AgilityType = "Defect"; AdoType = "Bug"; Source = "Employees" })

    ($patch | Where-Object { $_.path -eq "/fields/System.Tags" }).value | Should -BeLike "*agility-source:Employees*"
  }

  # ---- Revision history: the create carries NO assignee, only the backdated header ----
  It "does not put System.AssignedTo in the create payload" {
    $patch = BuildFieldPatch (NewFieldItem @{ OwnerNames = @("Alex Rivera"); OwnerEmails = @("alex@example.com") })

    ($patch | Where-Object { $_.path -eq "/fields/System.AssignedTo" }) | Should -BeNullOrEmpty
  }
}

Describe "Two-point revision history" {

  BeforeAll {
    function NewHistItem($props)
    {
      $base = @{
        Number = "E-1"; CreatedByName = $null; CreatedByEmail = $null; CreateDate = $null
        ChangedByName = $null; ChangedByEmail = $null; ChangeDate = $null
        OwnerNames = @(); OwnerEmails = @()
      }
      foreach ($k in $props.Keys) { $base[$k] = $props[$k] }
      return [pscustomobject]$base
    }
  }

  # Revision 1: the item is created as if by its Agility creator on its create date, so ADO shows the
  # real "created by X on date" rather than the migration account today.
  It "backdates the create to the Agility creator and create date" {
    $ops = BuildHistoryHeaderOps (NewHistItem @{
      CreatedByEmail = "sam.carter@example.com"; CreatedByName = "Sam Carter"; CreateDate = "2026-04-23"
    })

    ($ops | Where-Object { $_.path -eq "/fields/System.CreatedBy" }).value   | Should -Be "sam.carter@example.com"
    ($ops | Where-Object { $_.path -eq "/fields/System.ChangedBy" }).value   | Should -Be "sam.carter@example.com"
    ($ops | Where-Object { $_.path -eq "/fields/System.CreatedDate" }).value | Should -BeLike "2026-04-23T*Z"
    ($ops | Where-Object { $_.path -eq "/fields/System.ChangedDate" }).value | Should -BeLike "2026-04-23T*Z"
  }

  It "prefers the creator's email but falls back to the name" {
    $ops = BuildHistoryHeaderOps (NewHistItem @{ CreatedByName = "Departed Person"; CreateDate = "2026-04-23" })

    ($ops | Where-Object { $_.path -eq "/fields/System.CreatedBy" }).value | Should -Be "Departed Person"
  }

  # No half-backdated items: with no creator or no create date, ADO's own create stamp stands.
  It "produces no header ops when there is no creator or no create date" {
    (BuildHistoryHeaderOps (NewHistItem @{ CreateDate = "2026-04-23" })).Count | Should -Be 0
    (BuildHistoryHeaderOps (NewHistItem @{ CreatedByEmail = "x@example.com" })).Count | Should -Be 0
  }

  # A history person is NOT filtered for assignability: a departed changer is fine under bypassRules,
  # which is how "then changed by <departed person>" survives.
  It "resolves a history person by email, then name, without an assignability check" {
    ResolveHistoryPerson "jordan.blake@example.com" "Jordan Blake" | Should -Be "jordan.blake@example.com"
    ResolveHistoryPerson $null "Jordan Blake"                     | Should -Be "Jordan Blake"
    ResolveHistoryPerson $null $null                                  | Should -BeNullOrEmpty
  }

  It "builds the assignee op from the resolved assignee, and null when there is none" {
    (BuildAssigneeOp ([pscustomobject]@{ OwnerEmails = @("alex@example.com"); OwnerNames = @("Alex Rivera") })).value | Should -Be "alex@example.com"
    BuildAssigneeOp ([pscustomobject]@{ OwnerEmails = @(); OwnerNames = @() }) | Should -BeNullOrEmpty
  }
}

Describe "ReadAdoError and IsIdentityProblem" {

  It "pulls the message out of an ADO JSON error blob" {
    $rec = [pscustomobject]@{
      ErrorDetails = [pscustomobject]@{ Message = '{"message":"The identity value is an unknown identity.","errorCode":600171}' }
      Exception    = [pscustomobject]@{ Message = "fallback" }
    }

    ReadAdoError $rec | Should -Be "The identity value is an unknown identity."
  }

  It "falls back to the exception message when there is no JSON" {
    $rec = [pscustomobject]@{
      ErrorDetails = $null
      Exception    = [pscustomobject]@{ Message = "connection refused" }
    }

    ReadAdoError $rec | Should -Be "connection refused"
  }

  It "returns the raw text when the body is not JSON" {
    $rec = [pscustomobject]@{
      ErrorDetails = [pscustomobject]@{ Message = "plain text failure" }
      Exception    = [pscustomobject]@{ Message = "fallback" }
    }

    ReadAdoError $rec | Should -Be "plain text failure"
  }

  It "recognises an unknown identity so the assignee can be dropped instead of the item" {
    IsIdentityProblem "The identity value 'x@y.z' for field 'Assigned To' is an unknown identity." | Should -BeTrue
  }

  It "does not mistake an unrelated failure for an identity problem" {
    IsIdentityProblem "TF401320: Rule Error for field Effort." | Should -BeFalse
  }
}

Describe "FormatDate" {

  It "converts an Agility date to ISO 8601, which ADO accepts" {
    FormatDate "2023-07-01" | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
  }

  It "returns null for an empty date rather than a bogus one" {
    FormatDate $null | Should -BeNullOrEmpty
    FormatDate "" | Should -BeNullOrEmpty
  }

  It "returns null for an unparseable value instead of throwing" {
    FormatDate "not a date" | Should -BeNullOrEmpty
  }

  # The bug: 'Z' is a literal in a .NET custom format string, not a specifier. The old code took
  # local midnight, stamped a Z on it, and told ADO it was UTC. Mountain users then saw 5pm (MST)
  # or 6pm (MDT) on the PREVIOUS day, on every start and target date.
  #
  # These assert the round trip rather than a fixed string, so they hold in any timezone and on
  # either side of a daylight saving boundary.
  It "sends a dateless Agility date as midnight LOCAL, not midnight UTC" {
    $result = FormatDate "2023-07-01"

    # Back to local, it must still be midnight on the 1st: the day the Agility value named.
    $roundTrip = [datetime]::Parse($result, [cultureinfo]::InvariantCulture,
                   [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()

    $roundTrip.Year   | Should -Be 2023
    $roundTrip.Month  | Should -Be 7
    $roundTrip.Day    | Should -Be 1 -Because "the date must not slip to the previous day"
    $roundTrip.Hour   | Should -Be 0 -Because "no time in Agility means 12:00am, not 5pm or 6pm"
    $roundTrip.Minute | Should -Be 0
  }

  It "does not slip the day across a daylight saving boundary either" {
    foreach ($date in @('2023-01-15', '2023-07-15', '2023-03-12', '2023-11-05'))
    {
      $roundTrip = [datetime]::Parse((FormatDate $date), [cultureinfo]::InvariantCulture,
                     [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()

      $roundTrip.ToString('yyyy-MM-dd') | Should -Be $date -Because "$date must survive the round trip"
      $roundTrip.Hour | Should -Be 0
    }
  }

  It "keeps the real time of day when Agility supplies one" {
    $roundTrip = [datetime]::Parse((FormatDate "12/3/2020 5:39:52 PM"), [cultureinfo]::InvariantCulture,
                   [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()

    $roundTrip.ToString('yyyy-MM-dd HH:mm:ss') | Should -Be '2020-12-03 17:39:52'
  }

  It "still emits the Z suffix ADO needs, and does not double convert an offset value" {
    FormatDate "2023-07-01" | Should -BeLike "*Z"

    # An input that already carries a zone must not be shifted a second time.
    FormatDate "2023-07-01T12:00:00+00:00" | Should -Be "2023-07-01T12:00:00Z"
  }
}

Describe "GetAttributeValues" {

  It "keeps every entry of a multi value attribute, unlike GetAttributeValue" {
    $response = @'
{ "Assets": [ { "id": "Epic:1", "Attributes": { "Owners.Name": { "name": "Owners.Name", "value": ["Ann", "Bob", "Cy"] } } } ] }
'@ | ConvertFrom-Json
    $attrs = $response.Assets[0].Attributes

    (GetAttributeValues $attrs "Owners.Name").Count | Should -Be 3
    (GetAttributeValue $attrs "Owners.Name") | Should -Be "Ann" -Because "the single-value accessor still takes the first"
  }

  It "returns an empty array for a missing attribute" {
    $response = '{ "Assets": [ { "id": "Epic:1", "Attributes": {} } ] }' | ConvertFrom-Json

    (GetAttributeValues $response.Assets[0].Attributes "Owners.Name").Count | Should -Be 0
  }

  It "returns an empty array for a null value" {
    $response = '{ "Assets": [ { "id": "Epic:1", "Attributes": { "Owners.Name": { "value": null } } } ] }' | ConvertFrom-Json

    (GetAttributeValues $response.Assets[0].Attributes "Owners.Name").Count | Should -Be 0
  }
}

Describe "BuildTitle" {

  It "passes a normal title through untouched" {
    BuildTitle ([pscustomobject]@{ Name = "Windows 11 Rollout"; Number = "E-1" }) | Should -Be "Windows 11 Rollout"
  }

  It "keeps a title at exactly the 255 limit intact" {
    $name = "x" * 255
    $result = BuildTitle ([pscustomobject]@{ Name = $name; Number = "E-1" })

    $result.Length | Should -Be 255
    $result | Should -Be $name
  }

  It "truncates a title over the limit to exactly 255, which ADO would otherwise reject" {
    $name = "y" * 391
    $result = BuildTitle ([pscustomobject]@{ Name = $name; Number = "E-1" })

    $result.Length | Should -Be 255
    $result | Should -BeLike "*..."
  }

  # S-29493's Agility name has a newline with pasted UI chrome after it. System.Title is a single
  # line field, so the whitespace is collapsed. The words are kept: nothing is dropped.
  It "collapses a newline in the name, since System.Title is a single line" {
    $epic = NewAsset "Story:1" "S-29493" "Update NVR Servers to Latest Version`nDetails History"

    BuildTitle $epic | Should -Be "Update NVR Servers to Latest Version Details History"
  }

  It "collapses tabs and runs of spaces too" {
    $epic = NewAsset "Story:2" "S-2" "spaced`tout    title"

    BuildTitle $epic | Should -Be "spaced out title"
  }

  It "trims leading and trailing whitespace" {
    $epic = NewAsset "Story:3" "S-3" "  padded  "

    BuildTitle $epic | Should -Be "padded"
  }

  It "does not call a title truncated when only its whitespace pushed it over the limit" {
    # 250 characters plus 10 newlines. Over the limit raw, under it once collapsed, so BuildTitle
    # returns it whole and IsTitleTruncated must agree.
    $epic = NewAsset "Story:4" "S-4" (("a" * 250) + ("`n" * 10))

    IsTitleTruncated $epic | Should -BeFalse
    (BuildTitle $epic) | Should -Not -BeLike "*..."
  }

  It "falls back to the Number when an Epic has no name" {
    BuildTitle ([pscustomobject]@{ Name = $null; Number = "E-1" }) | Should -BeLike "*E-1*"
  }

  It "reports truncation only when the title actually exceeded the limit" {
    IsTitleTruncated ([pscustomobject]@{ Name = "z" * 256 }) | Should -BeTrue
    IsTitleTruncated ([pscustomobject]@{ Name = "z" * 255 }) | Should -BeFalse
    IsTitleTruncated ([pscustomobject]@{ Name = $null }) | Should -BeFalse
  }
}

Describe "BuildDescription - truncated titles" {

  BeforeAll { $script:numberByOid = @{} }

  It "preserves the full title in the description when it was truncated" {
    $long = "The IT team will " + ("a" * 300)
    $epic = [pscustomobject]@{ Name = $long; Description = "<p>body</p>"; Number = "E-08866"; Flattened = $false; TrueParentOid = $null }

    $result = BuildDescription $epic

    $result | Should -BeLike "*Full Agility title*"
    $result | Should -BeLike "*$("a" * 300)*" -Because "the full name must survive somewhere"
    $result | Should -BeLike "*<p>body</p>*"
  }

  It "does not add a full-title block for a normal title" {
    $epic = [pscustomobject]@{ Name = "Short"; Description = "<p>body</p>"; Number = "E-1"; Flattened = $false; TrueParentOid = $null }

    BuildDescription $epic | Should -Not -BeLike "*Full Agility title*"
  }

  It "html encodes the preserved title so markup in a name cannot break the description" {
    $epic = [pscustomobject]@{ Name = ("<script>x</script>" + "b" * 300); Description = ""; Number = "E-1"; Flattened = $false; TrueParentOid = $null }

    $result = BuildDescription $epic

    $result | Should -BeLike "*&lt;script&gt;*"
  }
}

Describe "FormatAreaPath" {

  BeforeAll {
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ Project = "Migration" } }
  }

  It "roots the configured area path at the project" {
    FormatAreaPath "IT\Operations" | Should -Be "Migration\IT\Operations"
  }

  It "falls back to the project root when no area path is configured" {
    FormatAreaPath "" | Should -Be "Migration"
  }

  It "does not double the separator when the config has a leading slash" {
    FormatAreaPath "\IT" | Should -Be "Migration\IT"
  }
}

##################################################################################################
# The migration footer moved OUT of the description and into a Discussion comment on 2026-07-30, at
# the user's request: the description should carry the item's own content, not our provenance note.
##################################################################################################
Describe "BuildDescription" {

  BeforeAll {
    $script:numberByOid = @{ "Epic:2" = "E-02002" }
  }

  It "no longer stamps a migration footer into the description" {
    $epic = [pscustomobject]@{ Description = "<p>body</p>"; Number = "E-01001"; Flattened = $false; TrueParentOid = $null }

    $html = BuildDescription $epic
    $html | Should -Be "<p>body</p>"
    $html | Should -Not -Match "Migrated from"
  }

  # The footer used to guarantee a non empty description. Without it an item that had nothing to say
  # in Agility says nothing in ADO, rather than carrying a line of our own bookkeeping.
  It "returns an empty description when Agility had none" {
    $epic = [pscustomobject]@{ Description = $null; Number = "E-01001"; Flattened = $false; TrueParentOid = $null }

    BuildDescription $epic | Should -Be ""
  }

  It "no longer names the flattened parent in the description either" {
    $epic = [pscustomobject]@{ Description = "<p>body</p>"; Number = "E-01001"; Flattened = $true; TrueParentOid = "Epic:2" }

    BuildDescription $epic | Should -Not -Match "Agility parent"
  }

  # Everything the description legitimately carries must survive the footer's removal.
  It "still carries the content blocks that belong to the item" {
    $epic = [pscustomobject]@{
      Description = "<p>body</p>"; Number = "E-01001"; Flattened = $false; TrueParentOid = $null
      AgilityType = "Defect"; Resolution = "fixed it"; Timebox = "Sprint 3"
    }

    $html = BuildDescription $epic
    $html | Should -Match "body"
    $html | Should -Match "fixed it"
    $html | Should -Match "Sprint 3"
  }
}

Describe "The migration note is a Discussion comment" {

  BeforeAll {
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/org" } }
    $script:numberByOid = @{ "Epic:2" = "E-02002" }
  }

  BeforeEach { $script:DryRun = $false; $script:sent = $null }

  It "says where the item came from" {
    BuildMigrationNote ([pscustomobject]@{ Number = "E-08866"; Flattened = $false; TrueParentOid = $null }) |
      Should -Be "Migrated from digital.ai Agility E-08866"
  }

  It "names the real parent when the Epic was flattened onto the root" {
    BuildMigrationNote ([pscustomobject]@{ Number = "E-01001"; Flattened = $true; TrueParentOid = "Epic:2" }) |
      Should -Match "Agility parent: E-02002"
  }

  It "does not mention a parent when nothing was flattened" {
    BuildMigrationNote ([pscustomobject]@{ Number = "E-01001"; Flattened = $false; TrueParentOid = "Epic:2" }) |
      Should -Not -Match "Agility parent"
  }

  # System.History IS the discussion entry. It must be rule-checked and must NOT carry a ChangedDate,
  # or the comment would be backdated to the Agility date instead of showing today.
  It "patches System.History without bypassRules and without a date" {
    Mock InvokeAdoRequest { $script:sent = [pscustomobject]@{ Url = $url; Body = $body } }

    AddAdoMigrationComment 42 ([pscustomobject]@{ Number = "E-08866"; Flattened = $false; TrueParentOid = $null })

    $script:sent.Url | Should -Not -BeLike "*bypassRules*"
    @($script:sent.Body).Count | Should -Be 1
    $script:sent.Body[0].path  | Should -Be "/fields/System.History"
    $script:sent.Body[0].value | Should -Be "Migrated from digital.ai Agility E-08866"
  }

  It "writes no comment on a dry run" {
    $script:DryRun = $true
    Mock InvokeAdoRequest { $script:sent = [pscustomobject]@{ Url = $url; Body = $body } }

    AddAdoMigrationComment 42 ([pscustomobject]@{ Number = "E-08866"; Flattened = $false; TrueParentOid = $null })

    $script:sent | Should -BeNullOrEmpty
  }

  # A comment is bookkeeping. The work item already exists by the time it is added, so a failure here
  # must warn rather than fail an item that is otherwise complete.
  It "warns rather than failing the item when the comment cannot be added" {
    $script:warnings = 0
    Mock InvokeAdoRequest { throw "comment exploded" }

    { AddAdoMigrationComment 42 ([pscustomobject]@{ Number = "E-08866"; Flattened = $false; TrueParentOid = $null }) } |
      Should -Not -Throw
    $script:warnings | Should -BeGreaterThan 0
  }
}

Describe "ResolveMigratedId" {

  BeforeAll {
    $script:numberByOid = @{ "Epic:1" = "E-1"; "Epic:2" = "E-2" }
  }

  It "maps an Agility oid to the ADO id it was migrated as" {
    ResolveMigratedId "Epic:1" @{ "E-1" = 42 } | Should -Be 42
  }

  It "returns null for an oid that has not been migrated yet" {
    ResolveMigratedId "Epic:2" @{ "E-1" = 42 } | Should -BeNullOrEmpty
  }

  It "returns null for a null oid rather than throwing" {
    ResolveMigratedId $null @{} | Should -BeNullOrEmpty
  }
}

AfterAll {
  # Leaving this set would suppress Main for anything else run in this session.
  Remove-Variable -Name AgilityEpicsLoadFunctionsOnly -Scope Global -ErrorAction SilentlyContinue
}

##################################################################################################
# Closed items are ALWAYS migrated: -IncludeClosed was removed on 2026-07-30 because every real run
# used it. Dead items are still never migrated, and that is the whole risk of the removal - the two
# filters used to be the two halves of one conditional, so dropping the wrong half would have
# migrated the 18 placeholder templates ("IT - Registration Checklist - <insert semester>").
##################################################################################################
Describe "Closed and Dead filtering" {

  It "no longer filters closed items out, because closed items always migrate" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Not -Match "AssetState!='Closed'" `
      -Because "every run includes closed items, so there is no closed filter left to apply"
  }

  It "never migrates Dead items, which are placeholder templates" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Match "AssetState!='Dead'"
  }

  # The invariant that replaces the old conditional: every Agility query that scopes by Scope also
  # filters Dead. Counting them is what catches a future query added without the filter.
  It "puts the Dead filter on every scoped Agility query, with none left unfiltered" {
    $source = Get-Content $script:scriptPath -Raw

    $scoped = @([regex]::Matches($source, '\$where\s*=\s*"Scope=')).Count
    $dead   = @([regex]::Matches($source, "AssetState!='Dead'")).Count

    $scoped | Should -BeGreaterThan 0
    $dead   | Should -Be $scoped -Because "each scoped query needs exactly one Dead filter"
  }

  It "has no trace of the removed switch left" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Not -Match 'IncludeClosed' `
      -Because "the switch is gone, and a stale reference would read as if it still worked"
  }
}

Describe "ClosedDate" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{
      Fields = [pscustomobject]@{
        ClosedDate = "Microsoft.VSTS.Common.ClosedDate"
        Estimate   = "Microsoft.VSTS.Scheduling.Effort"
      }
      Tags   = [pscustomobject]@{}
      States = [pscustomobject]@{
        Story = [pscustomobject]@{ DefaultState = "New"; ClosedState = "Done"; Map = [pscustomobject]@{} }
      }
      Priorities = [pscustomobject]@{ DefaultPriority = 2; Map = [pscustomobject]@{} }
    }
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ Project = "Migration" } }

    function NewClosedItem
    {
      return [pscustomobject]@{
        AgilityType = "Story"; Number = "S-1"; Name = "closed story"; AdoType = "Product Backlog Item"
        AssetState  = "128"; Status = $null; ClosedDate = "2020-05-04T00:00:00.000"
        OwnerNames  = @(); OwnerEmails = @(); Estimate = $null; Order = $null; Priority = $null
        AreaPath    = ""; Timebox = $null; Environment = $null; FoundInBuild = $null
      }
    }
  }

  # ADO rejects the whole create with "Rule Error for field Closed Date. Error code:
  # InvalidNotEmpty" if ClosedDate rides along while the item is still in its default state. This
  # failed every closed Story in a real dry run.
  It "never puts ClosedDate in the create payload, which ADO would reject outright" {
    $patch = BuildFieldPatch (NewClosedItem)

    ($patch | Where-Object { $_.path -like "*ClosedDate*" }) | Should -BeNullOrEmpty
  }

  It "still builds the rest of the create payload for a closed item" {
    $patch = BuildFieldPatch (NewClosedItem)

    ($patch | Where-Object { $_.path -eq "/fields/System.Title" }).value | Should -Be "closed story"
  }

  # The close date is written INSIDE the bypassRules state transition, so it is populated before the
  # rule-checked assignee patch. A closed item with an empty Closed Date makes that later patch fail
  # (TF401320 "Closed Date Required" - what broke 30,928 Tasks). It is not a separate call any more.
  It "writes the close date inside the bypassRules state transition" {
    $source = Get-Content $script:scriptPath -Raw
    $stateBody = [regex]::Match($source, "function SetAdoState\b[\s\S]*?(?=\r?\nfunction )").Value

    $stateBody | Should -Match 'bypassRules=true'
    $stateBody | Should -Match 'Fields\.ClosedDate'
    $source | Should -Not -Match 'function SetAdoClosedDate' -Because "the separate correction call is gone"
  }

  # bypassRules is no longer confined to the close date: the revision history needs it on the
  # backdated create (System.CreatedBy/CreatedDate) and the backdated state transition
  # (System.ChangedBy/ChangedDate) as well. The guarantee that replaces "one call site" is that
  # System.AssignedTo NEVER travels in a bypassRules payload - because bypassRules skips identity
  # validation, a departed owner in a bypass create would be stored as an unresolvable identity
  # instead of being rejected. AssignedTo is set only by SetAdoAssignee, which is rule checked.
  It "never sends System.AssignedTo in a bypassRules payload" {
    $source = Get-Content $script:scriptPath -Raw

    # A function body, bounded by the next 'function ' declaration, so an assertion cannot leak into
    # a neighbouring function.
    function BodyOf($src, $name) { [regex]::Match($src, "function $name\b[\s\S]*?(?=\r?\nfunction )").Value }

    # The create is bypassRules (to backdate CreatedBy/CreatedDate) and must not carry the assignee.
    # Match the op path, not the bare word, so a comment mentioning AssignedTo does not trip it.
    $newBody = BodyOf $source 'NewAdoWorkItem'
    $newBody | Should -Match 'bypassRules=true'
    $newBody | Should -Not -Match '/fields/System\.AssignedTo'

    # The backdated state transition is bypassRules (to attribute ChangedBy) and also must not.
    $stateBody = BodyOf $source 'SetAdoState'
    $stateBody | Should -Not -Match '/fields/System\.AssignedTo'

    # SetAdoAssignee, which does write AssignedTo, is rule checked: no bypassRules. Match the query
    # string it would actually use, not the bare word, for the same reason as above: a comment
    # explaining why there is no bypass here must not read as a bypass.
    $assigneeBody = BodyOf $source 'SetAdoAssignee'
    $assigneeBody | Should -Not -Match 'bypassRules=true'
  }

  # The trigger is the MAPPED ADO state, not IsAgilityClosed: an item whose Status maps to Done gets a
  # Closed Date even if Agility still calls it active. SetAdoState gates the Closed Date on it.
  It "sets the close date only when the item lands in a closed ADO state" {
    $source = Get-Content $script:scriptPath -Raw
    $stateBody = [regex]::Match($source, "function SetAdoState\b[\s\S]*?(?=\r?\nfunction )").Value

    $stateBody | Should -Match 'IsClosedAdoState \$epic \$state'
  }

  It "asks Agility for ClosedDate on every type it migrates" {
    foreach ($type in @('Epic', 'Story', 'Defect', 'Issue'))
    {
      GetSelection $type | Should -Match 'ClosedDate' -Because "$type items cannot carry a real close date without it"
    }
  }
}

Describe "Closed date is written inside the state transition" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{
      Fields = [pscustomobject]@{ ClosedDate = "Microsoft.VSTS.Common.ClosedDate" }
      States = [pscustomobject]@{
        Epic  = [pscustomobject]@{ DefaultState = "New";   ClosedState = "Done";   Map = [pscustomobject]@{} }
        Issue = [pscustomobject]@{ DefaultState = "Open";  ClosedState = "Closed"; Map = [pscustomobject]@{} }
        Task  = [pscustomobject]@{ DefaultState = "To Do"; ClosedState = "Done";   Map = [pscustomobject]@{} }
      }
    }
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/org" } }

    function NewTransitionItem($props)
    {
      # A backdated create needs a creator; default one in, so the ChangedDate cases can drop it.
      $base = @{
        AgilityType = "Task"; ChangedByEmail = $null; ChangedByName = $null
        CreatedByEmail = "creator@example.com"; CreatedByName = $null
        CreateDate = "2020-01-01"; ChangeDate = "2020-06-01"; ClosedDate = $null
      }
      foreach ($k in $props.Keys) { $base[$k] = $props[$k] }
      return [pscustomobject]$base
    }

    # Capture the op at a given field path the transition patch would send (or $null).
    function OpAt($item, $state, $path)
    {
      $script:sent = $null
      Mock InvokeAdoRequest { $script:sent = [pscustomobject]@{ Url = $url; Body = $body } }
      SetAdoState 42 $state $item
      return @($script:sent.Body | Where-Object { $_.path -eq $path })[0]
    }
    function ClosedOp($item, $state)  { OpAt $item $state "/fields/Microsoft.VSTS.Common.ClosedDate" }
    function ChangedDateOp($item, $state) { OpAt $item $state "/fields/System.ChangedDate" }
  }

  # The transition backdates ChangedDate only when the CREATE was backdated (creator present), or
  # rev 2's past date is earlier than rev 1's server-time date and ADO rejects it with VS402625.
  It "backdates ChangedDate when the create was backdated" {
    (ChangedDateOp (NewTransitionItem @{ CreatedByEmail = "creator@example.com" }) "Done").value | Should -BeLike "2020-06-01T*Z"
  }

  # TK-01316: a real CreateDate but an EMPTY CreatedBy. The create is not backdated (rev 1 = now), so
  # a past ChangedDate would fail VS402625. It must be withheld.
  It "does not backdate ChangedDate when CreatedBy is empty, even with a real CreateDate" {
    ChangedDateOp (NewTransitionItem @{ CreatedByEmail = $null; CreatedByName = $null }) "Done" | Should -BeNullOrEmpty
  }

  It "recognises the type's closed ADO state" {
    IsClosedAdoState ([pscustomobject]@{ AgilityType = "Epic" })  "Done" | Should -BeTrue
    IsClosedAdoState ([pscustomobject]@{ AgilityType = "Issue" }) "Closed" | Should -BeTrue
  }

  It "does not treat an open ADO state as closed" {
    IsClosedAdoState ([pscustomobject]@{ AgilityType = "Epic" })  "In Progress" | Should -BeFalse
    IsClosedAdoState ([pscustomobject]@{ AgilityType = "Issue" }) "Open" | Should -BeFalse
  }

  # The whole reason the close date moved into the transition: a bypass transition to a closed state
  # leaves ClosedDate empty (bypass skips the auto-stamp), and the next rule-checked patch then
  # rejects the item with "Closed Date Required". Setting it here, in the same bypass patch, fixes it.
  It "puts the real close date in the closing transition, and marks it bypassRules" {
    $op = ClosedOp (NewTransitionItem @{ ClosedDate = "2020-05-04" }) "Done"

    $op | Should -Not -BeNullOrEmpty
    $op.value | Should -BeLike "2020-05-04T*Z"
    $script:sent.Url | Should -BeLike "*bypassRules=true*"
  }

  # Task's Done REQUIRES a non-empty close date. A closed Task with no Agility date cannot be left
  # empty, so it falls back to its last-changed date rather than failing the item.
  It "falls back to the change date for a closed Task with no Agility close date" {
    $op = ClosedOp (NewTransitionItem @{ AgilityType = "Task"; ClosedDate = $null; ChangeDate = "2020-06-01" }) "Done"

    $op | Should -Not -BeNullOrEmpty
    $op.value | Should -BeLike "2020-06-01T*Z"
  }

  # Other closed types allow an empty close date, so a no-date item gets none - which is the correct
  # "Agility had no real date" state, not a fabricated one.
  It "leaves a non-Task closed item's close date empty when Agility has none" {
    $op = ClosedOp (NewTransitionItem @{ AgilityType = "Issue"; ClosedDate = $null }) "Closed"

    $op | Should -BeNullOrEmpty
  }

  # An open transition never carries a close date at all.
  It "does not add a close date on a transition to an open state" {
    $op = ClosedOp (NewTransitionItem @{ AgilityType = "Task"; ClosedDate = "2020-05-04" }) "In Progress"

    $op | Should -BeNullOrEmpty
  }
}

Describe "Resolution routing and per-type estimate field" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{
      Fields = [pscustomobject]@{
        Estimate     = "Microsoft.VSTS.Scheduling.Effort"
        TaskEstimate = "Microsoft.VSTS.Scheduling.RemainingWork"
        Resolution   = "Microsoft.VSTS.Common.Resolution"
        ClosedDate   = "Microsoft.VSTS.Common.ClosedDate"
        Environment  = "Microsoft.VSTS.TCM.SystemInfo"
        FoundInBuild = "Microsoft.VSTS.Build.FoundIn"
      }
      States = [pscustomobject]@{
        Issue  = [pscustomobject]@{ DefaultState = "Open";  ClosedState = "Closed"; Map = [pscustomobject]@{} }
        Defect = [pscustomobject]@{ DefaultState = "New";   ClosedState = "Done";   Map = [pscustomobject]@{} }
        Task   = [pscustomobject]@{ DefaultState = "To Do"; ClosedState = "Done";   Map = [pscustomobject]@{} }
      }
      Priorities = [pscustomobject]@{ DefaultPriority = 2; Map = [pscustomobject]@{} }
    }
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ Project = "Migration" } }
    $script:numberByOid = @{}

    function NewItemOf([string]$type, $props)
    {
      $base = @{
        AgilityType = $type; Number = "X-1"; Name = "an item"; AdoType = "thing"
        AssetState = "64"; Status = $null; ClosedDate = $null; Description = ""
        OwnerNames = @(); OwnerEmails = @(); Estimate = $null; Order = $null; Priority = $null
        AreaPath = ""; Timebox = $null; Environment = $null; FoundInBuild = $null
        Resolution = $null; ResolutionReason = $null; Flattened = $false; TrueParentOid = $null
      }
      foreach ($k in $props.Keys) { $base[$k] = $props[$k] }
      return [pscustomobject]$base
    }
  }

  It "puts an Issue's Resolution in the Impediment field, which Impediment actually has" {
    $patch = BuildFieldPatch (NewItemOf 'Issue' @{ Resolution = "<p>vendor fixed it</p>" })

    ($patch | Where-Object { $_.path -eq "/fields/Microsoft.VSTS.Common.Resolution" }).value |
      Should -Be "<p>vendor fixed it</p>"
  }

  It "does not also put the Issue's Resolution in the description, which would duplicate it" {
    $result = BuildDescription (NewItemOf 'Issue' @{ Resolution = "<p>vendor fixed it</p>" })

    $result | Should -Not -BeLike "*<b>Resolution:</b>*"
  }

  # Bug has no Resolution field, so the 543 Defect resolutions must keep going where they went.
  It "still puts a Defect's Resolution in the description, since Bug has no such field" {
    $item = NewItemOf 'Defect' @{ Resolution = "<p>restarted the service</p>" }

    BuildDescription $item | Should -BeLike "*<b>Resolution:</b>*restarted the service*"
    (BuildFieldPatch $item | Where-Object { $_.path -like "*Common.Resolution*" }) | Should -BeNullOrEmpty
  }

  # Scrum's Task has no Effort field. ADO does not reject the write, and neither does validateOnly,
  # so sending Effort to a Task would lose the value on all 43,000 of them without an error.
  It "sends a Task's estimate to Remaining Work, not Effort" {
    $patch = BuildFieldPatch (NewItemOf 'Task' @{ Estimate = 3 })

    ($patch | Where-Object { $_.path -eq "/fields/Microsoft.VSTS.Scheduling.RemainingWork" }).value | Should -Be 3
    ($patch | Where-Object { $_.path -like "*Scheduling.Effort*" }) | Should -BeNullOrEmpty
  }

  It "still sends everything else's estimate to Effort" {
    $patch = BuildFieldPatch (NewItemOf 'Defect' @{ Estimate = 5 })

    ($patch | Where-Object { $_.path -eq "/fields/Microsoft.VSTS.Scheduling.Effort" }).value | Should -Be 5
    ($patch | Where-Object { $_.path -like "*RemainingWork*" }) | Should -BeNullOrEmpty
  }

  It "leaves an unestimated item's estimate field unset rather than sending zero" {
    $patch = BuildFieldPatch (NewItemOf 'Task' @{ Estimate = $null })

    ($patch | Where-Object { $_.path -like "*RemainingWork*" }) | Should -BeNullOrEmpty
  }

  # ToDo is legitimately 0 on the 40,211 completed Tasks, and 0 is not "no value".
  It "sends a zero estimate, which is a real remaining-work value" {
    $patch = BuildFieldPatch (NewItemOf 'Task' @{ Estimate = 0 })

    ($patch | Where-Object { $_.path -like "*RemainingWork*" }).value | Should -Be 0
  }
}

Describe "GetMigratedIdMap" {

  # WIQL matches System.Tags one whole tag at a time. CONTAINS 'agility:' matches nothing at all,
  # and returns zero rows rather than an error, so the map came back empty and everything looked
  # unmigrated: reruns would duplicate every item, and Stories could not find Epics from an earlier
  # run. There is no prefix or wildcard form, so the filtering has to happen on the client.
  It "does not filter tags in WIQL, which silently matches nothing" {
    # Code only. The comment above the function quotes the broken query on purpose.
    $code = Get-Content $script:scriptPath | Where-Object { $_ -notmatch '^\s*#' }

    ($code | Where-Object { $_ -match "Tags\] CONTAINS 'agility:'" }) | Should -BeNullOrEmpty
  }

  It "filters the agility tags on the client instead" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Match "function GetMigratedIdMap[\s\S]*?-like 'agility:\*'"
  }

  It "still scopes the query to the configured project" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Match "function GetMigratedIdMap[\s\S]*?System\.TeamProject"
  }

  # WIQL caps a flat query at 20,000 rows and fails the whole query rather than truncating. The
  # project is at 858 and will pass 50,000 once Tasks land, so an unpaged SELECT is a time bomb on
  # the one function whose last silent failure would have duplicated everything.
  It "does not rely on a single unpaged query, which dies at the 20,000 row cap" {
    $code = Get-Content $script:scriptPath | Where-Object { $_ -notmatch '^\s*#' }

    ($code | Where-Object { $_ -match '\$top=' })          | Should -Not -BeNullOrEmpty
    ($code | Where-Object { $_ -match 'System\.Id\] > ' }) | Should -Not -BeNullOrEmpty
    ($code | Where-Object { $_ -match 'ORDER BY \[System\.Id\]' }) | Should -Not -BeNullOrEmpty
  }
}

Describe "GetMigratedIdMap paging" {

  BeforeAll {
    $script:config = [pscustomobject]@{
      AzureDevOps = [pscustomobject]@{
        OrganizationUrl = "https://dev.azure.com/testorg"
        Project         = "Migration"
      }
    }
    $script:mappings = [pscustomobject]@{
      RequiredFields = [pscustomobject]@{
        AgilityId     = "Custom.DigitalAIID"
        AgilityStatus = "Custom.DigitalAIStatus"
      }
    }
  }

  BeforeEach {
    $script:seenQueries = @()
    $script:fakeIds = 1..250

    # Stands in for a server that will not return more than the page size, which is the whole
    # reason the watermark exists.
    Mock InvokeAdoRequest {
      if ($method -eq 'Post')
      {
        $script:seenQueries += $body.query

        $after = 0
        if ($body.query -match '\[System\.Id\] > (\d+)') { $after = [int]$Matches[1] }

        $top = 100
        if ($url -match '\$top=(\d+)') { $top = [int]$Matches[1] }

        $page = @($script:fakeIds | Where-Object { $_ -gt $after } | Select-Object -First $top)
        return [pscustomobject]@{ workItems = @($page | ForEach-Object { [pscustomobject]@{ id = $_ } }) }
      }

      # The workitems detail batch.
      $idList = ($url -replace '.*ids=([\d,]+).*', '$1') -split ','
      return [pscustomobject]@{
        value = @($idList | ForEach-Object {
          [pscustomobject]@{ id = [int]$_; fields = @{ 'System.Tags' = "agility:E-$_; other" } }
        })
      }
    }
  }

  It "walks the whole project with a System.Id watermark rather than one flat query" {
    $map = GetMigratedIdMap 100

    $map.Count | Should -Be 250
    $map['E-1']   | Should -Be 1
    $map['E-250'] | Should -Be 250
  }

  It "asks for ids above the last one it saw, so no page is fetched twice" {
    GetMigratedIdMap 100 | Out-Null

    $script:seenQueries.Count | Should -Be 3 -Because "250 ids at 100 a page is 3 pages"
    $script:seenQueries[0] | Should -Match '\[System\.Id\] > 0'
    $script:seenQueries[1] | Should -Match '\[System\.Id\] > 100'
    $script:seenQueries[2] | Should -Match '\[System\.Id\] > 200'
  }

  It "orders by id, or the watermark would skip items" {
    GetMigratedIdMap 100 | Out-Null

    foreach ($q in $script:seenQueries) { $q | Should -Match 'ORDER BY \[System\.Id\]' }
  }

  It "stops on a short page rather than querying forever" {
    # 250 is not a multiple of 100, so the third page is short and must end the walk.
    GetMigratedIdMap 100 | Out-Null

    $script:seenQueries.Count | Should -Be 3
  }

  It "stops when a full final page is followed by an empty one" {
    $script:fakeIds = 1..200

    GetMigratedIdMap 100 | Out-Null

    # 100, 100, then empty. The empty page is what ends it, and it must not loop past that.
    $script:seenQueries.Count | Should -Be 3
  }

  It "returns an empty map for an empty project rather than looping" {
    $script:fakeIds = @()

    $map = GetMigratedIdMap 100

    $map.Count | Should -Be 0
    $script:seenQueries.Count | Should -Be 1
  }

  It "still matches the agility tags on the client, not in the WIQL" {
    GetMigratedIdMap 100 | Out-Null

    foreach ($q in $script:seenQueries) { $q | Should -Not -Match 'Tags' }
  }
}

Describe "Area path creation" {

  BeforeAll {
    $script:config = [pscustomobject]@{
      AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/testorg"; Project = "Migration" }
    }
  }

  BeforeEach {
    $script:DryRun = $false
    $script:created = 0
    $script:skipped = 0
    $script:failed = 0
    $script:posted = @()
    Mock WriteLog { }
    Mock WriteErrorDetail { }
  }

  Context "GetAreaPaths" {

    It "flattens the tree into full paths, and does not include the project root" {
      Mock InvokeAdoRequest {
        return [pscustomobject]@{
          name = "Migration"
          children = @(
            [pscustomobject]@{ name = "Operations"; children = @([pscustomobject]@{ name = "Apps" }) }
            [pscustomobject]@{ name = "User Services" }
          )
        }
      }

      $paths = GetAreaPaths

      $paths.Count | Should -Be 3
      $paths.ContainsKey("operations") | Should -BeTrue
      $paths.ContainsKey("operations\apps") | Should -BeTrue
      $paths.ContainsKey("user services") | Should -BeTrue
      $paths.ContainsKey("migration") | Should -BeFalse -Because "the project root is not part of the configured path"
    }

    It "does not loop forever on a leaf" {
      # @($null) is a one element array, so a naive walk enqueues null and never terminates. This
      # previously produced 5GB of output.
      Mock InvokeAdoRequest {
        return [pscustomobject]@{
          name = "Migration"
          children = @([pscustomobject]@{ name = "Operations"; children = $null })
        }
      }

      $paths = GetAreaPaths

      $paths.Count | Should -Be 1
    }
  }

  Context "EnsureAreaPath" {

    It "skips a node that already exists" {
      $have = @{ "operations" = $true }
      Mock InvokeAdoRequest { throw "must not be called" }

      EnsureAreaPath "Operations" $have

      $script:skipped | Should -Be 1
      $script:created | Should -Be 0
    }

    It "matches case insensitively, because ADO would 409 on a case-only difference" {
      $have = @{ "operations\apps" = $true }
      Mock InvokeAdoRequest { throw "must not be called" }

      EnsureAreaPath "Operations\APPS" $have

      $script:skipped | Should -Be 1
    }

    It "posts the parent path in the url and the leaf name in the body" {
      $have = @{}
      Mock InvokeAdoRequest {
        $script:posted += [pscustomobject]@{ Url = $url; Name = $body.name }
        return [pscustomobject]@{ id = 1 }
      }

      EnsureAreaPath "Operations\Colleague" $have

      $script:posted[0].Name | Should -Be "Colleague"
      $script:posted[0].Url | Should -BeLike "*/classificationnodes/areas/Operations?*"
      $script:created | Should -Be 1
    }

    It "posts a top level node against the areas root, with no trailing parent" {
      $have = @{}
      Mock InvokeAdoRequest {
        $script:posted += [pscustomobject]@{ Url = $url; Name = $body.name }
        return [pscustomobject]@{ id = 1 }
      }

      EnsureAreaPath ".edu conversion" $have

      $script:posted[0].Name | Should -Be ".edu conversion"
      $script:posted[0].Url | Should -BeLike "*/classificationnodes/areas/?*"
    }

    It "records what it created, so a leaf sees a parent made moments earlier" {
      $have = @{}
      Mock InvokeAdoRequest { return [pscustomobject]@{ id = 1 } }

      EnsureAreaPath ".edu conversion" $have
      EnsureAreaPath ".edu conversion\Apps" $have

      $have.ContainsKey(".edu conversion") | Should -BeTrue
      $script:created | Should -Be 2
    }

    It "creates nothing on a dry run, but still tracks the path so the plan is coherent" {
      $script:DryRun = $true
      $have = @{}
      Mock InvokeAdoRequest { throw "a dry run must not write" }

      EnsureAreaPath ".edu conversion" $have

      $script:created | Should -Be 1
      $have.ContainsKey(".edu conversion") | Should -BeTrue
    }

    It "counts a failure rather than throwing, so one bad node does not kill the rest" {
      $have = @{}
      Mock InvokeAdoRequest { throw "boom" }
      Mock ReadAdoError { return "boom" }

      { EnsureAreaPath "Operations\Bad" $have } | Should -Not -Throw
      $script:failed | Should -Be 1
    }

    It "ignores an empty area path, which means the project root" {
      $have = @{}
      Mock InvokeAdoRequest { throw "must not be called" }

      EnsureAreaPath "" $have

      $script:created | Should -Be 0
      $script:skipped | Should -Be 0
    }
  }
}

Describe "Owner names and emails stay aligned" {

  # Agility null pads a missing email rather than omitting it, so the two lists arrive the same
  # length and index i is one owner. Stripping the nulls slid every later owner up a slot: 1,338
  # live items have an owner with no email.
  BeforeAll {
    function NewOwnersAsset($names, $emails)
    {
      return [pscustomobject]@{
        Assets = @(
          [pscustomobject]@{
            id = "Story:1"
            Attributes = [pscustomobject]@{
              'Number'       = [pscustomobject]@{ value = "S-21740" }
              'Owners.Name'  = [pscustomobject]@{ value = $names }
              'Owners.Email' = [pscustomobject]@{ value = $emails }
            }
          }
        )
      }
    }
  }

  It "keeps the empty slot so the lists line up, exactly as Agility sent them" {
    # The real S-21740 payload.
    $parsed = ConvertFromAgilityAssets (NewOwnersAsset `
      @("Jordan Blake", "Jamie Nolan", "Vendor") `
      @("jordan.blake@example.com", "jamie.nolan@example.com", $null)) 'Story'

    $parsed[0].OwnerNames.Count | Should -Be 3
    $parsed[0].OwnerEmails.Count | Should -Be 3 -Because "dropping the null would slide Vendor onto Jamie Nolan's email"
    $parsed[0].OwnerEmails[2] | Should -BeNullOrEmpty
  }

  It "skips an email-less owner and assigns the one ADO can actually use" {
    # 283 live items look like this: a non-person first, a real ADO identity second. Owners is in
    # Member oid order, not priority order, so there is no reason to prefer Vendor.
    $parsed = ConvertFromAgilityAssets (NewOwnersAsset `
      @("Vendor", "Chris Turner") `
      @($null, "chris.turner@example.com")) 'Story'

    ResolveAssignee $parsed[0] | Should -Be "chris.turner@example.com"
  }

  It "records the skipped owner in the owners field rather than dropping them" {
    # The old bug: assignee came from owner ONE while the owner list skipped owner ZERO's name, so
    # Vendor vanished with no record and Chris Turner was both assignee AND listed. Since
    # 2026-07-17 the non-assignee owners go to Custom.DigitalAIOwners, not the description. The index
    # alignment must survive the real parser.
    $parsed = ConvertFromAgilityAssets (NewOwnersAsset `
      @("Vendor", "Chris Turner") `
      @($null, "chris.turner@example.com")) 'Story'

    $owners = BuildOwnersField $parsed[0]
    $owners | Should -Be "Vendor" -Because "Vendor is a real owner, and Christopher is the assignee"
  }

  It "falls back to a name only when NO owner has an email" {
    $parsed = ConvertFromAgilityAssets (NewOwnersAsset @("Vendor") @($null)) 'Story'

    ResolveAssignee $parsed[0] | Should -Be "Vendor"
  }

  It "still strips empty slots from lists that are not paired" {
    # GetAttributeValues keeps its old behaviour: a null in a tag list is just noise.
    $attrs = [pscustomobject]@{ 'BlockedEpics.Number' = [pscustomobject]@{ value = @("E-1", $null, "E-2") } }

    (GetAttributeValues $attrs "BlockedEpics.Number").Count | Should -Be 2
  }
}

Describe "ResolveAssignee picks the assignee" {

  # Measured against the live org, per distinct owner: 31 of 104 resolve by email; 14 more have no
  # email in Agility at all and resolve by name; none of the 53 whose email ADO rejects resolve by
  # name. Hence email first, name only when there is no email. The owners that do NOT become the
  # assignee are recorded by BuildAgilityDetails; those tests live with it.
  BeforeAll {
    function NewOwnerItem($emails, $names, $createdByEmail = $null, $createdByName = $null)
    {
      return [pscustomobject]@{
        Number = "S-1"; OwnerEmails = @($emails); OwnerNames = @($names)
        CreatedByEmail = $createdByEmail; CreatedByName = $createdByName
      }
    }
  }

  It "prefers the email when there is one" {
    ResolveAssignee (NewOwnerItem @("alex@example.com") @("Alex Rivera")) | Should -Be "alex@example.com"
  }

  # When an item has no owner, the Created By person is used instead: they are often current staff
  # and therefore assignable, so an ownerless item still lands on someone. E-09418 is the example.
  It "falls back to the Created By email when the item has no owner" {
    ResolveAssignee (NewOwnerItem @() @() "sam.carter@example.com" "Sam Carter") | Should -Be "sam.carter@example.com"
  }

  It "falls back to the Created By name when there is no Created By email" {
    ResolveAssignee (NewOwnerItem @() @() $null "Sam Carter") | Should -Be "Sam Carter"
  }

  It "still prefers a real owner over the Created By person" {
    ResolveAssignee (NewOwnerItem @("alex@example.com") @("Alex Rivera") "sam.carter@example.com" "Sam Carter") | Should -Be "alex@example.com"
  }

  It "does not use Created By once the item is marked unassignable" {
    # The retry after ADO rejects the Created By identity too: everyone is off, including the creator.
    ResolveAssignee (AsUnassignable (NewOwnerItem @() @() "departed@example.com" "Departed Person")) | Should -BeNullOrEmpty
  }

  It "resolves nobody when there is no owner and no Created By either" {
    ResolveAssignee (NewOwnerItem @() @()) | Should -BeNullOrEmpty
  }

  It "falls back to the display name when Agility has no email for anyone" {
    ResolveAssignee (NewOwnerItem @() @("Vendor")) | Should -Be "Vendor"
  }

  It "resolves nobody when there is neither" {
    ResolveAssignee (NewOwnerItem @() @()) | Should -BeNullOrEmpty
  }

  It "resolves nobody once the item is marked unassignable, even though the owners are still on it" {
    $item = AsUnassignable (NewOwnerItem @("nobody@example.com") @("No Body"))

    ResolveAssignee $item | Should -BeNullOrEmpty
    $item.OwnerNames | Should -Contain "No Body" -Because "BuildAgilityDetails still has to record the owner it gave up on"
  }

  It "does not mutate the original when marking a copy unassignable" {
    $item = NewOwnerItem @("alex@example.com") @("Alex Rivera")
    AsUnassignable $item | Out-Null

    ResolveAssignee $item | Should -Be "alex@example.com" -Because "the retry must not disarm the assignee for every later item"
  }
}

Describe "Assignee promotion: try each owner, promote an assignable one" {

  # These tests seed $script:assignableCache directly, which IsAssignableIdentity consults BEFORE the
  # ProbeAssignability gate, so a rejection is expressed without any network call. A cleared cache
  # means "everyone assignable" (the gate returns true when probing is off), the default elsewhere.
  BeforeAll {
    function NewMultiOwner($emails, $names)
    {
      return [pscustomobject]@{ Number = "E-1"; OwnerEmails = @($emails); OwnerNames = @($names) }
    }
  }
  BeforeEach { $script:assignableCache = @{} }
  AfterEach  { $script:assignableCache = @{} }

  # The core fix: a departed first owner no longer sinks the item. This is exactly the user's case -
  # AdditionalOwners populated, Assigned To empty - now resolved by promoting the next owner.
  It "promotes the next owner when the first is a departed identity" {
    $script:assignableCache = @{ "departed@example.com" = $false }
    $item = NewMultiOwner @("departed@example.com", "current@example.com") @("Departed Person", "Current Person")

    ResolveAssignee $item      | Should -Be "current@example.com"
    ResolveAssigneeIndex $item | Should -Be 1
  }

  It "records the skipped departed owner in the owners field, not the promoted one" {
    $script:assignableCache = @{ "departed@example.com" = $false }
    $item = NewMultiOwner @("departed@example.com", "current@example.com") @("Departed Person", "Current Person")

    BuildOwnersField $item | Should -Be "Departed Person" -Because "the promoted owner is the assignee, the departed one is recorded"
  }

  It "leaves it unassigned and lists ALL owners only when NONE is assignable" {
    # Every candidate rejected, including the name fallbacks, so nobody can be assigned.
    $script:assignableCache = @{
      "a@example.com" = $false; "b@example.com" = $false; "Owner A" = $false; "Owner B" = $false
    }
    $item = NewMultiOwner @("a@example.com", "b@example.com") @("Owner A", "Owner B")

    ResolveAssignee $item  | Should -BeNullOrEmpty
    BuildOwnersField $item | Should -Be "Owner A, Owner B"
  }

  It "falls through emails before trying names, so a real identity beats a name-only non-person" {
    # Vendor (owner 0) has no email; the real identity is owner 1. Even with Vendor's name assignable
    # in this test, the email candidate is tried first and wins.
    $item = NewMultiOwner @($null, "real@example.com") @("Vendor", "Real Person")

    ResolveAssignee $item      | Should -Be "real@example.com"
    ResolveAssigneeIndex $item | Should -Be 1
  }

  It "assumes assignable without probing when the identity is not cached and probing is off" {
    # The unit-test default: no cache entry, ProbeAssignability off -> first candidate, no network.
    IsAssignableIdentity "anyone@example.com" | Should -BeTrue
  }

  It "returns the cached verdict regardless of the probe gate" {
    $script:assignableCache = @{ "known-bad@example.com" = $false }
    IsAssignableIdentity "known-bad@example.com" | Should -BeFalse
  }
}

Describe "GetMigratedIdMap matches the field OR the legacy tag" {

  # The 858 Epics and Features migrated before Custom.DigitalAIID existed carry only the
  # agility:<Number> tag. If the map stopped reading tags they would look unmigrated and a rerun
  # would duplicate every one of them, silently. Both sources, keyed by the bare Number, until the
  # 858 are backfilled.
  BeforeAll {
    $script:config = [pscustomobject]@{
      AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/testorg"; Project = "Migration" }
    }
    $script:mappings = [pscustomobject]@{
      RequiredFields = [pscustomobject]@{
        AgilityId     = "Custom.DigitalAIID"
        AgilityStatus = "Custom.DigitalAIStatus"
      }
    }
  }

  BeforeEach {
    # #1 legacy: tag only. #2 new: field only. #3 both, with the field disagreeing.
    $script:fake = @{
      1 = @{ 'System.Tags' = 'agility:E-01001; agility-team:IT' }
      2 = @{ 'Custom.DigitalAIID' = 'S-02002' }
      3 = @{ 'System.Tags' = 'agility:E-03003'; 'Custom.DigitalAIID' = 'E-09999' }
      4 = @{ 'System.Tags' = 'agility-team:IT' }
    }

    Mock InvokeAdoRequest {
      if ($method -eq 'Post')
      {
        $after = 0
        if ($body.query -match '\[System\.Id\] > (\d+)') { $after = [int]$Matches[1] }
        $page = @($script:fake.Keys | Sort-Object | Where-Object { $_ -gt $after })
        return [pscustomobject]@{ workItems = @($page | ForEach-Object { [pscustomobject]@{ id = $_ } }) }
      }

      $idList = ($url -replace '.*ids=([\d,]+).*', '$1') -split ','
      return [pscustomobject]@{
        value = @($idList | ForEach-Object { [pscustomobject]@{ id = [int]$_; fields = $script:fake[[int]$_] } })
      }
    }
  }

  It "finds an item that only has the legacy tag" {
    (GetMigratedIdMap 100)['E-01001'] | Should -Be 1
  }

  It "finds an item that only has the custom field" {
    (GetMigratedIdMap 100)['S-02002'] | Should -Be 2
  }

  It "prefers the field when an item has both, so the result cannot depend on read order" {
    $map = GetMigratedIdMap 100

    $map['E-09999'] | Should -Be 3
    $map.ContainsKey('E-03003') | Should -BeFalse
  }

  It "ignores an item with neither, rather than keying the map on nothing" {
    $map = GetMigratedIdMap 100

    $map.Count | Should -Be 3
    $map.Keys | Should -Not -Contain ''
  }

  It "keys on the bare Number, not the tag text, so callers never care which matched" {
    $map = GetMigratedIdMap 100

    $map.Keys | ForEach-Object { $_ | Should -Not -BeLike 'agility:*' }
  }
}

Describe "Parents across runs" {

  # The Epics are migrated in an earlier run, so they are not in numberByOid when the Stories run.
  # Without Super.Number the oid cannot become an agility:<Number> tag, ResolveMigratedId returns
  # null, and the Story is created with no parent and no error. 4,526 of 7,568 Stories have a Super.
  It "reads the parent Epic's Number off the Story itself" {
    GetSelection 'Story'  | Should -Match 'Super\.Number'
    GetSelection 'Defect' | Should -Match 'Super\.Number'
  }

  It "parses the parent Number so the Epic does not need loading" {
    $response = @'
{
  "Assets": [
    {
      "id": "Story:3403",
      "Attributes": {
        "Number":       { "value": "S-01548" },
        "Name":         { "value": "a story under an epic" },
        "Super":        { "value": { "idref": "Epic:2886" } },
        "Super.Number": { "value": "E-01330" }
      }
    }
  ]
}
'@ | ConvertFrom-Json

    $parsed = ConvertFromAgilityAssets $response 'Story'

    $parsed[0].SuperOid     | Should -Be "Epic:2886"
    $parsed[0].ParentNumber | Should -Be "E-01330"
  }

  It "resolves a parent migrated by an EARLIER run, which is the normal case" {
    $script:numberByOid = @{}
    # Only the Story is in this run. The Epic exists in ADO as #497 from a previous one.
    $story = [pscustomobject]@{ Oid = "Story:3403"; Number = "S-01548"; SuperOid = "Epic:2886"; ParentNumber = "E-01330" }
    $existing = @{ "E-01330" = 497 }

    # The bridge MigrateWorkitems builds before migrating.
    $script:numberByOid[$story.Oid] = $story.Number
    if ($story.SuperOid -and $story.ParentNumber) { $script:numberByOid[$story.SuperOid] = $story.ParentNumber }

    ResolveMigratedId $story.SuperOid $existing | Should -Be 497
  }

  It "leaves a Story with no Super unparented rather than guessing" {
    $script:numberByOid = @{}

    ResolveMigratedId $null @{ "E-01330" = 497 } | Should -BeNullOrEmpty
  }
}

Describe "Task parent axis" {

  # Story.Parent is the Theme and becomes the area path. Task.Parent is the Story it belongs to and
  # becomes the ADO parent link. Same attribute name, completely different meaning, and confusing
  # them is silent both ways: the Task loses its parent AND a Story's name gets pushed through the
  # theme-to-area-path lookup.
  It "reads Task.Parent as the parent work item, and its Theme from the grandparent" {
    # Task.Parent is the Story/Defect (the parent link); Task.Parent.Parent is the Story's Theme,
    # which becomes the Task's area path leaf so it lands with its parent, not at the scope root.
    $response = @'
{
  "Assets": [
    {
      "id": "Task:9001",
      "Attributes": {
        "Number":             { "value": "TK-01124" },
        "Name":               { "value": "wire up the thing" },
        "Parent":             { "value": { "idref": "Story:2722" } },
        "Parent.Number":      { "value": "S-01395" },
        "Parent.Name":        { "value": "IT - Dual Enrollment - Customer Communication" },
        "Parent.Parent.Name": { "value": "Other" }
      }
    }
  ]
}
'@ | ConvertFrom-Json

    $parsed = ConvertFromAgilityAssets $response 'Task'

    $parsed[0].SuperOid     | Should -Be "Story:2722" -Because "the Task's parent link comes from Parent, not Super"
    $parsed[0].ParentNumber | Should -Be "S-01395"
    $parsed[0].Theme        | Should -Be "Other" -Because "a Task inherits its Story's Theme via Parent.Parent"
  }

  It "asks Task for its parent's Theme, one hop up (Parent.Parent.Name)" {
    GetSelection 'Task' | Should -Match ([regex]::Escape('Parent.Parent.Name'))
  }

  It "still reads Story.Parent as the Theme" {
    $response = @'
{
  "Assets": [
    {
      "id": "Story:1",
      "Attributes": {
        "Number":        { "value": "S-1" },
        "Super":         { "value": { "idref": "Epic:5" } },
        "Super.Number":  { "value": "E-5" },
        "Parent.Name":   { "value": "Applications" }
      }
    }
  ]
}
'@ | ConvertFrom-Json

    $parsed = ConvertFromAgilityAssets $response 'Story'

    $parsed[0].SuperOid     | Should -Be "Epic:5"
    $parsed[0].ParentNumber | Should -Be "E-5"
    $parsed[0].Theme        | Should -Be "Applications"
  }

  # Scrum's Task has no Effort field, only Remaining Work. Agility's ToDo is the remaining hours.
  It "reads Task ToDo as the estimate, since that is what Remaining Work means" {
    $response = @'
{
  "Assets": [
    {
      "id": "Task:1",
      "Attributes": {
        "Number":         { "value": "TK-1" },
        "ToDo":           { "value": 3 },
        "DetailEstimate": { "value": 8 },
        "Estimate":       { "value": 99 }
      }
    }
  ]
}
'@ | ConvertFrom-Json

    (ConvertFromAgilityAssets $response 'Task')[0].Estimate | Should -Be 3
  }
}

Describe "Issue blocking links" {

  It "merges the blocked Stories/Defects and the blocked Epics into one list" {
    $response = @'
{
  "Assets": [
    {
      "id": "Issue:1",
      "Attributes": {
        "Number": { "value": "I-1" },
        "BlockedPrimaryWorkitems.Number": { "value": ["S-01", "D-02"] },
        "BlockedEpics.Number":            { "value": ["E-03"] }
      }
    }
  ]
}
'@ | ConvertFrom-Json

    $parsed = ConvertFromAgilityAssets $response 'Issue'

    $parsed[0].BlockedNumbers.Count | Should -Be 3
    $parsed[0].BlockedNumbers | Should -Contain "S-01"
    $parsed[0].BlockedNumbers | Should -Contain "E-03"
  }

  It "leaves an Issue that blocks nothing with an empty list, not a null" {
    $response = '{ "Assets": [ { "id": "Issue:2", "Attributes": { "Number": { "value": "I-2" } } } ] }' | ConvertFrom-Json

    (ConvertFromAgilityAssets $response 'Issue')[0].BlockedNumbers.Count | Should -Be 0
  }

  # Resolves straight off the Number: the blocked items are Stories, Defects and Epics, all
  # migrated before Issues, so the tag map already holds them.
  It "resolves blocked numbers to the ADO ids they were migrated as" {
    $item = [pscustomobject]@{ BlockedNumbers = @("S-01", "E-03") }
    $existing = @{ "S-01" = 111; "E-03" = 222 }

    $result = ResolveBlockedIds $item $existing

    $result.Ids.Count | Should -Be 2
    $result.Ids | Should -Contain 111
    $result.Ids | Should -Contain 222
    $result.Unresolved.Count | Should -Be 0
  }

  # A blocked item outside the configured scopes has no ADO id to point at. The link is dropped;
  # the number is not, the same way an unmigrated parent keeps its agility-parent tag.
  It "keeps a blocked item that is not in ADO as unresolved rather than dropping it" {
    $item = [pscustomobject]@{ BlockedNumbers = @("S-01", "S-99") }
    $existing = @{ "S-01" = 111 }

    $result = ResolveBlockedIds $item $existing

    $result.Ids | Should -Be @(111)
    $result.Unresolved | Should -Be @("S-99")
  }

  It "does not link the same item twice when two attributes name it" {
    $item = [pscustomobject]@{ BlockedNumbers = @("S-01", "S-01") }

    (ResolveBlockedIds $item @{ "S-01" = 111 }).Ids.Count | Should -Be 1
  }

  It "handles an Issue that blocks nothing without throwing" {
    $result = ResolveBlockedIds ([pscustomobject]@{ BlockedNumbers = @() }) @{}

    $result.Ids.Count | Should -Be 0
    $result.Unresolved.Count | Should -Be 0
  }

  # A real run creates Stories before Issues and the link resolves. A dry run writes nothing, so
  # without the pending marker every such link reports as NOT IN ADO: 245 false misses on one
  # scope alone, understating what a real run would do.
  It "separates an item this run would create from one that is genuinely missing" {
    $item = [pscustomobject]@{ BlockedNumbers = @("S-01", "S-02", "S-99") }
    $existing = @{
      "S-01" = 111
      "S-02" = $script:DryRunPendingId
    }

    $result = ResolveBlockedIds $item $existing

    $result.Ids        | Should -Be @(111)
    $result.Pending    | Should -Be @("S-02")
    $result.Unresolved | Should -Be @("S-99")
  }

  # The pending marker must never reach ADO as if it were an id.
  It "never puts the pending marker in the ids that become links" {
    $existing = @{ "S-02" = $script:DryRunPendingId }

    $result = ResolveBlockedIds ([pscustomobject]@{ BlockedNumbers = @("S-02") }) $existing

    $result.Ids | Should -Not -Contain $script:DryRunPendingId
    $result.Ids.Count | Should -Be 0
  }
}

Describe "Owners stay a list" {

  # An if used as an expression unrolls a one element array to a scalar. When that happened,
  # OwnerEmails[0] returned "j" instead of "jsmith@example.com": ADO called it an unknown identity and
  # every single owner item migrated unassigned, with only a warning. Most items have one owner.
  It "keeps a SINGLE owner as a list, not a bare string" {
    $response = @'
{
  "Assets": [
    {
      "id": "Story:1",
      "Attributes": {
        "Number":       { "value": "S-1" },
        "Name":         { "value": "one owner" },
        "Owners.Name":  { "value": ["Jane Smith"] },
        "Owners.Email": { "value": ["jsmith@example.com"] }
      }
    }
  ]
}
'@ | ConvertFrom-Json

    $parsed = ConvertFromAgilityAssets $response 'Story'

    $parsed[0].OwnerEmails[0] | Should -Be "jsmith@example.com" -Because "the first owner is the assignee, not the first character"
    $parsed[0].OwnerNames[0]  | Should -Be "Jane Smith"
    $parsed[0].OwnerEmails.Count | Should -Be 1
  }

  # Issue is a BaseAsset: its owner is the singular Owner, and Agility sends it as a bare value
  # rather than a list, so this is the case most likely to arrive unwrapped.
  It "keeps a single Issue owner as a list, which reads the singular Owner attribute" {
    $response = @'
{
  "Assets": [
    {
      "id": "Issue:1",
      "Attributes": {
        "Number":      { "value": "I-1" },
        "Name":        { "value": "one owner" },
        "Owner.Name":  { "value": "Jane Smith" },
        "Owner.Email": { "value": "jsmith@example.com" }
      }
    }
  ]
}
'@ | ConvertFrom-Json

    $parsed = ConvertFromAgilityAssets $response 'Issue'

    $parsed[0].OwnerEmails[0] | Should -Be "jsmith@example.com"
  }

  It "still keeps multiple owners in order" {
    $response = @'
{
  "Assets": [
    {
      "id": "Story:2",
      "Attributes": {
        "Number":       { "value": "S-2" },
        "Name":         { "value": "two owners" },
        "Owners.Email": { "value": ["first@example.com", "second@example.com"] }
      }
    }
  ]
}
'@ | ConvertFrom-Json

    $parsed = ConvertFromAgilityAssets $response 'Story'

    $parsed[0].OwnerEmails.Count | Should -Be 2
    $parsed[0].OwnerEmails[0] | Should -Be "first@example.com"
  }

  It "leaves an unowned item with an empty list rather than a null" {
    $response = @'
{ "Assets": [ { "id": "Story:3", "Attributes": { "Number": { "value": "S-3" } } } ] }
'@ | ConvertFrom-Json

    $parsed = ConvertFromAgilityAssets $response 'Story'

    $parsed[0].OwnerEmails.Count | Should -Be 0
  }
}

Describe "GetSelection" {

  # Attributes are per Agility type. Asking for one a type does not have is an HTTP 400 that fails
  # the entire page, not one field, so a wrong sel list kills the whole type's migration.
  It "does not ask Defect for Category, which Defect does not have" {
    # Defect.Category is "Unknown AttributeDefinition" and 400s the read. Type and
    # DeliveryCategory, its nearest equivalents, are empty on all 704 Defects.
    GetSelection 'Defect' | Should -Not -Match 'Category'
  }

  It "does not ask Epic for Estimate, which Epic does not have" {
    # Swag is the Epic estimate. This 400s the same way.
    GetSelection 'Epic' | Should -Not -Match '(^|,)Estimate'
  }

  It "asks Issue for the singular Owner, since Issue is a BaseAsset and has no Owners" {
    GetSelection 'Issue' | Should -Match 'Owner\.Email'
    GetSelection 'Issue' | Should -Not -Match 'Owners\.'
  }

  It "does not ask Issue for the Workitem-only attributes it lacks" {
    $sel = GetSelection 'Issue'

    foreach ($attr in @('Super', 'Estimate', 'Timebox'))
    {
      $sel | Should -Not -Match $attr -Because "Issue is a BaseAsset and has no $attr"
    }
  }

  # Issue DOES have a Priority attribute; meta.v1 lists it and selecting it would not 400. It is
  # left out because it is empty on all 388 Issues, not because it does not exist. The distinction
  # matters: if Priority ever gets used in Agility, this is a data gap and not a schema error.
  It "leaves Priority out of the Issue selection because it is empty, not because it is absent" {
    GetSelection 'Issue' | Should -Not -Match 'Priority'
  }

  It "asks every type for the attributes the parser and tags depend on" {
    foreach ($type in @('Epic', 'Story', 'Defect', 'Issue', 'Task'))
    {
      $sel = GetSelection $type
      foreach ($attr in @('Name', 'Number', 'Description', 'Scope', 'AssetState', 'Team.Name', 'Order'))
      {
        $sel | Should -Match ([regex]::Escape($attr)) -Because "$type needs $attr"
      }
    }
  }

  # The creator becomes the assignee for an ownerless item, so every type must select both parts.
  It "asks every type for the Created By person, the owner fallback" {
    foreach ($type in @('Epic', 'Story', 'Defect', 'Issue', 'Task'))
    {
      $sel = GetSelection $type
      $sel | Should -Match ([regex]::Escape('CreatedBy.Name'))  -Because "$type needs the creator's name"
      $sel | Should -Match ([regex]::Escape('CreatedBy.Email')) -Because "$type needs the creator's email"
    }
  }

  # Request (1,567 items) and Test (410) are real types in the instance that nothing migrates yet.
  It "throws for a type it has no selection for, rather than reading the wrong attributes" {
    { GetSelection 'Request' } | Should -Throw
    { GetSelection 'Test' }    | Should -Throw
  }

  # Selecting Task.Priority is an "Unknown token" 400 that fails the entire page, not one field.
  It "does not ask Task for Priority, which Task does not have" {
    GetSelection 'Task' | Should -Not -Match 'Priority'
  }

  # Task.Parent is the Story or Defect, so its Number is what links it in ADO. Without it the Task
  # would be created unparented and silently, exactly as Stories were before Super.Number.
  It "asks Task for its parent work item's Number" {
    GetSelection 'Task' | Should -Match 'Parent\.Number'
  }

  # 296 of 388 Issues carry a Resolution and it was never being read.
  It "asks Issue for the Resolution it has been dropping" {
    GetSelection 'Issue' | Should -Match 'Resolution'
    GetSelection 'Issue' | Should -Match 'ResolutionReason\.Name'
  }

  # A Defect's ResolutionReason (291 of 706) was dropped until 2026-07-17: Defect never selected it,
  # so it now goes to Custom.DigitalAIBugResolution and the selection has to ask for it.
  It "asks Defect for its ResolutionReason, which now feeds the Bug resolution field" {
    GetSelection 'Defect' | Should -Match 'ResolutionReason\.Name'
  }

  # The two ends of "this Issue blocks that work item". Both carry .Number so the tag map can
  # resolve them without loading the blocked items.
  It "asks Issue for the work items it blocks, with their Numbers" {
    GetSelection 'Issue' | Should -Match 'BlockedPrimaryWorkitems\.Number'
    GetSelection 'Issue' | Should -Match 'BlockedEpics\.Number'
  }

  # Found by auditing all 143 attributes the Epic type declares against the live data on 2026-07-30.
  # Each of these carries real data on Epics and was never being read.
  It "asks Epic for the attributes the field audit found carrying data" {
    $sel = GetSelection 'Epic'

    foreach ($attr in @('Source.Name', 'TaggedWith', 'ClosedBy.Name', 'ClosedBy.Email',
                        'Links.URL', 'Links.Name', 'Dependencies.Number', 'Dependants.Number'))
    {
      $sel | Should -Match ([regex]::Escape($attr)) -Because "Epic carries data in $attr"
    }
  }

  # The four that have no ADO field and go to the description instead.
  It "asks Epic for the four attributes that ride in the description" {
    $sel = GetSelection 'Epic'

    foreach ($attr in @('Custom_PersonaImpacts.Name', 'Risk', 'Reference', 'RequestedBy'))
    {
      $sel | Should -Match ([regex]::Escape($attr)) -Because "Epic carries data in $attr"
    }
  }

  # The oids drive the download; the filenames name the file in ADO. Both are needed.
  It "asks Epic for its attachments and their filenames" {
    $sel = GetSelection 'Epic'

    $sel | Should -Match '(^|,)Attachments(,|$)'
    $sel | Should -Match ([regex]::Escape('Attachments.Filename'))
  }

  ##################################################################################################
  # Parity for the other four types (2026-07-30). ClosedBy, TaggedWith, Attachments and Links exist
  # on EVERY Agility type here and carry data on all of them, so they live in the shared selection
  # rather than being repeated five times. Measured across the whole instance:
  #   ClosedBy    Story 7,274  Defect 699  Task 41,643  Issue 345
  #   TaggedWith  Story   351  Defect   5  Task    957  Issue  10
  #   Attachments Story   639  Defect  74  Task  1,294  Issue  13
  #   Links       Story   204  Defect  11  Task    167  Issue   0 (exists, empty)
  ##################################################################################################
  It "asks EVERY type for the attributes that exist on all of them" {
    foreach ($type in @('Epic', 'Story', 'Defect', 'Task', 'Issue'))
    {
      $sel = GetSelection $type
      foreach ($attr in @('ClosedBy.Name', 'ClosedBy.Email', 'TaggedWith',
                          'Attachments', 'Attachments.Filename', 'Links.URL', 'Links.Name'))
      {
        $sel | Should -Match ([regex]::Escape($attr)) -Because "$type carries $attr"
      }
    }
  }

  # Dependencies/Dependants exist ONLY on Epic, Story and Defect. Selecting one on Task or Issue is
  # an "Unknown token" 400 that fails the entire page, so this is a hard boundary, not a preference.
  It "asks Story and Defect for their dependencies, which are far bigger than Epic's" {
    foreach ($type in @('Story', 'Defect'))
    {
      GetSelection $type | Should -Match ([regex]::Escape('Dependencies.Number'))
      GetSelection $type | Should -Match ([regex]::Escape('Dependants.Number'))
    }
  }

  It "never asks Task or Issue for dependencies, which those types do not have" {
    foreach ($type in @('Task', 'Issue'))
    {
      GetSelection $type | Should -Not -Match 'Dependencies' -Because "$type has no Dependencies attribute"
      GetSelection $type | Should -Not -Match 'Dependants'   -Because "$type has no Dependants attribute"
    }
  }

  # 474 Stories name a requester and 1 carries a reference; both ride in the description block.
  It "asks Story for the requester and reference that ride in the description" {
    GetSelection 'Story' | Should -Match 'RequestedBy'
    GetSelection 'Story' | Should -Match 'Reference'
  }

  # Defect and Task have NEITHER attribute; asking is a 400.
  It "never asks Defect or Task for Risk or RequestedBy, which do not exist there" {
    foreach ($type in @('Defect', 'Task'))
    {
      GetSelection $type | Should -Not -Match 'RequestedBy' -Because "$type has no RequestedBy attribute"
      GetSelection $type | Should -Not -Match '(^|,)Risk(,|$)' -Because "$type has no Risk attribute"
    }
  }
}

##################################################################################################
# Attachments: 61 files hang off Agility Epics (21.4 MB, largest 3.3 MB, none near ADO's 60 MB cap).
# Instance wide there are 3,574, most of them on Tasks and Stories, so this is built type-agnostic.
#
# Verified live end to end before any of this was written: the Epic selection accepts the tokens, the
# aligned oid/filename lists line up, attachment.img/{numericId} returns raw bytes, ADO's attachment
# endpoint accepts them, and the attached file reads back byte-for-byte the same size.
##################################################################################################
Describe "Agility attachment identity" {

  It "takes the numeric id off an attachment oid, which is what the byte endpoint wants" {
    AgilityAttachmentId 'Attachment:243961' | Should -Be '243961'
  }

  # Oids can carry a moment suffix, exactly as asset oids do.
  It "ignores a moment suffix on the oid" {
    AgilityAttachmentId 'Attachment:243961:99' | Should -Be '243961'
  }

  It "returns nothing for an empty or unusable oid rather than building a broken url" {
    AgilityAttachmentId ''        | Should -BeNullOrEmpty
    AgilityAttachmentId $null     | Should -BeNullOrEmpty
    AgilityAttachmentId 'rubbish' | Should -BeNullOrEmpty
  }

  It "downloads from the attachment endpoint, not the data endpoint" {
    $script:config = [pscustomobject]@{ Agility = [pscustomobject]@{ BaseUrl = "https://v1host/Inst/" } }
    $script:asked = $null
    Mock InvokeAgilityDownload { $script:asked = $url; return ,([byte[]]@(1, 2, 3)) }

    $bytes = GetAgilityAttachmentBytes 'Attachment:243961'

    $script:asked | Should -Be 'https://v1host/Inst/attachment.img/243961'
    $bytes.Length | Should -Be 3
  }

  # This is the whole ball game for binary. PowerShell enumerates a collection on output, so a
  # byte[] returned normally arrives as an Object[] of boxed bytes - which has the same .Length, so
  # a length assertion cannot see the difference. Uploading THAT stringifies it: measured live, a
  # 40,593 byte .docx arrived in ADO as 134,696 bytes, roughly 3.3x, on all 9 files of E-03934.
  # Only the type assertion catches it.
  It "returns the bytes as a real byte array, not an unrolled collection" {
    $script:config = [pscustomobject]@{ Agility = [pscustomobject]@{ BaseUrl = "https://v1host/Inst" } }
    Mock InvokeAgilityDownload { return ,([byte[]]@(1, 2, 3)) }

    $bytes = GetAgilityAttachmentBytes 'Attachment:1'

    $bytes -is [byte[]]      | Should -BeTrue -Because "an Object[] of bytes uploads corrupted"
    $bytes.GetType().Name    | Should -Be 'Byte[]'
  }

  # The hop that actually broke: InvokeWithRetry hands its result back through the pipeline, which
  # enumerated the byte[] away. Mocking the web call rather than the download proves the download
  # itself preserves the array, which the test above cannot see.
  It "carries the byte array intact through the retry wrapper" {
    Mock Invoke-WebRequest { return [pscustomobject]@{ Content = [byte[]]@(9, 8, 7, 6) } }

    $bytes = InvokeAgilityDownload 'https://v1host/Inst/attachment.img/1'

    $bytes -is [byte[]]   | Should -BeTrue -Because "InvokeWithRetry enumerates a bare byte[] into Object[]"
    $bytes.GetType().Name | Should -Be 'Byte[]'
    $bytes.Length         | Should -Be 4
    $bytes[0]             | Should -Be 9
  }
}

Describe "Attachments are parsed off the item" {

  It "reads attachment oids and filenames, aligned" {
    $payload = [pscustomobject]@{ Assets = @([pscustomobject]@{ id = "Epic:1"; Attributes = [pscustomobject]@{
      'Attachments' = [pscustomobject]@{ value = @(
        [pscustomobject]@{ idref = 'Attachment:1' }, [pscustomobject]@{ idref = 'Attachment:2' }) }
      'Attachments.Filename' = [pscustomobject]@{ value = @('a.pdf', 'b.docx') }
    } }) }

    $parsed = ConvertFromAgilityAssets $payload 'Epic'

    $parsed[0].AttachmentOids  | Should -Be @('Attachment:1', 'Attachment:2')
    $parsed[0].AttachmentNames | Should -Be @('a.pdf', 'b.docx')
  }

  # Same null-padding trap as the owner lists: a file with no name must not slide the others up.
  It "keeps the lists aligned when one attachment has no filename" {
    $payload = [pscustomobject]@{ Assets = @([pscustomobject]@{ id = "Epic:1"; Attributes = [pscustomobject]@{
      'Attachments' = [pscustomobject]@{ value = @(
        [pscustomobject]@{ idref = 'Attachment:1' }, [pscustomobject]@{ idref = 'Attachment:2' },
        [pscustomobject]@{ idref = 'Attachment:3' }) }
      'Attachments.Filename' = [pscustomobject]@{ value = @('a.pdf', $null, 'c.docx') }
    } }) }

    $parsed = ConvertFromAgilityAssets $payload 'Epic'

    @($parsed[0].AttachmentOids).Count  | Should -Be 3
    @($parsed[0].AttachmentNames).Count | Should -Be 3
    @($parsed[0].AttachmentNames)[2]    | Should -Be 'c.docx'
  }

  It "has no attachments for an item that carries none" {
    $payload = [pscustomobject]@{ Assets = @([pscustomobject]@{ id = "Epic:1"; Attributes = [pscustomobject]@{} }) }

    @((ConvertFromAgilityAssets $payload 'Epic')[0].AttachmentOids).Count | Should -Be 0
  }
}

Describe "AddAdoAttachments" {

  BeforeAll {
    $script:config = [pscustomobject]@{
      Agility     = [pscustomobject]@{ BaseUrl = "https://v1host/Inst" }
      AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/org"; Project = "Migration" }
    }

    function NewAttachedItem($oids, $names)
    {
      return [pscustomobject]@{ Number = "E-1"; AttachmentOids = $oids; AttachmentNames = $names }
    }
  }

  BeforeEach {
    $script:DryRun = $false
    $script:warnings = 0
    $script:attachmentsCopied = 0
    $script:attachmentsFailed = 0
    $script:patches = @()
    $script:uploaded = @()
  }

  It "uploads each file and attaches it to the work item" {
    Mock GetAgilityAttachmentBytes { return [byte[]]@(1, 2, 3) }
    Mock NewAdoAttachment { $script:uploaded += $fileName; return "https://ado/att/$fileName" }
    Mock InvokeAdoRequest { $script:patches += ,$body }

    AddAdoAttachments 42 (NewAttachedItem @('Attachment:1', 'Attachment:2') @('a.pdf', 'b.docx'))

    $script:uploaded          | Should -Be @('a.pdf', 'b.docx')
    $script:attachmentsCopied | Should -Be 2
    @($script:patches).Count  | Should -Be 2
    $script:patches[0][0].path      | Should -Be '/relations/-'
    $script:patches[0][0].value.rel | Should -Be 'AttachedFile'
    $script:patches[0][0].value.url | Should -Be 'https://ado/att/a.pdf'
  }

  It "does nothing at all for an item with no attachments" {
    Mock GetAgilityAttachmentBytes { throw "should not be called" }
    Mock InvokeAdoRequest { throw "should not be called" }

    { AddAdoAttachments 42 (NewAttachedItem @() @()) } | Should -Not -Throw
    $script:attachmentsCopied | Should -Be 0
  }

  # A dry run writes nothing, and must not spend bandwidth downloading either.
  It "downloads and uploads nothing on a dry run" {
    $script:DryRun = $true
    Mock GetAgilityAttachmentBytes { throw "a dry run must not download" }
    Mock NewAdoAttachment { throw "a dry run must not upload" }
    Mock InvokeAdoRequest { throw "a dry run must not write" }

    { AddAdoAttachments 42 (NewAttachedItem @('Attachment:1') @('a.pdf')) } | Should -Not -Throw
  }

  # One bad file must not cost the item its other files, and must never fail the work item, which by
  # this point already exists in ADO.
  It "keeps going when one attachment fails, and counts it" {
    Mock GetAgilityAttachmentBytes {
      if ($oid -eq 'Attachment:1') { throw "download exploded" }
      return [byte[]]@(1, 2, 3)
    }
    Mock NewAdoAttachment { $script:uploaded += $fileName; return "https://ado/att/$fileName" }
    Mock InvokeAdoRequest { $script:patches += ,$body }

    { AddAdoAttachments 42 (NewAttachedItem @('Attachment:1', 'Attachment:2') @('a.pdf', 'b.docx')) } |
      Should -Not -Throw

    $script:uploaded          | Should -Be @('b.docx')
    $script:attachmentsCopied | Should -Be 1
    $script:attachmentsFailed | Should -Be 1
  }

  # ADO rejects anything over 60 MB, so skipping is the only way the rest of the item survives.
  It "skips a file bigger than ADO will accept, and warns rather than failing" {
    Mock GetAgilityAttachmentBytes { return [byte[]]::new($script:AttachmentMaxBytes + 1) }
    Mock NewAdoAttachment { throw "must not upload an oversize file" }
    Mock InvokeAdoRequest { throw "must not attach an oversize file" }

    { AddAdoAttachments 42 (NewAttachedItem @('Attachment:1') @('big.zip')) } | Should -Not -Throw

    $script:attachmentsCopied | Should -Be 0
    $script:attachmentsFailed | Should -Be 1
    $script:warnings          | Should -BeGreaterThan 0
  }

  # Filename is what names the file in ADO. Agility does not guarantee one.
  It "falls back to a usable name when the attachment has no filename" {
    Mock GetAgilityAttachmentBytes { return [byte[]]@(1) }
    Mock NewAdoAttachment { $script:uploaded += $fileName; return "https://ado/att/x" }
    Mock InvokeAdoRequest { }

    AddAdoAttachments 42 (NewAttachedItem @('Attachment:7') @($null))

    $script:uploaded[0] | Should -Not -BeNullOrEmpty
    $script:uploaded[0] | Should -Match '7'
  }

  It "posts the file to the project's attachment endpoint with the name in the query string" {
    $script:asked = $null
    Mock InvokeAdoUpload { $script:asked = $url; return [pscustomobject]@{ url = "https://ado/att/1" } }

    NewAdoAttachment 'a b.pdf' ([byte[]]@(1)) | Should -Be "https://ado/att/1"

    $script:asked | Should -BeLike '*/Migration/_apis/wit/attachments?fileName=a%20b.pdf*'
  }
}

##################################################################################################
# The four Epic attributes with no ADO field go to the description's Agility details block rather
# than to custom fields: 28 Personas, 41 Risk, 6 Reference, 6 RequestedBy.
##################################################################################################
Describe "Agility details carries the fields with no ADO home" {

  BeforeAll {
    function NewDetailItem($props)
    {
      $base = @{ Timebox = $null; Personas = @(); Risk = $null; Reference = $null; RequestedBy = $null }
      foreach ($k in $props.Keys) { $base[$k] = $props[$k] }
      return [pscustomobject]$base
    }
  }

  It "lists every persona, which is multi value in Agility" {
    BuildAgilityDetails (NewDetailItem @{ Personas = @("Traditional Student", "Employee") }) |
      Should -Match "Personas: Traditional Student, Employee"
  }

  It "carries the risk rating" {
    BuildAgilityDetails (NewDetailItem @{ Risk = 9 }) | Should -Match "Risk: 9"
  }

  It "carries the reference" {
    BuildAgilityDetails (NewDetailItem @{ Reference = "S-10474/ S-08233" }) |
      Should -Match ([regex]::Escape("Reference: S-10474/ S-08233"))
  }

  # Free text, not an identity: two of the six hold several names and one is "ESM workgroup".
  It "carries who requested it, as text" {
    BuildAgilityDetails (NewDetailItem @{ RequestedBy = "Denise Aberle-Cannata, Kelly Steely" }) |
      Should -Match ([regex]::Escape("Requested by: Denise Aberle-Cannata, Kelly Steely"))
  }

  It "puts them all in ONE Agility details block alongside the sprint" {
    $html = BuildAgilityDetails (NewDetailItem @{ Timebox = "Sprint 3"; Risk = 2; Reference = "R-1" })

    @([regex]::Matches($html, "Agility details")).Count | Should -Be 1
    $html | Should -Match "Sprint: Sprint 3"
    $html | Should -Match "Risk: 2"
  }

  It "html encodes the values so markup cannot break the description" {
    BuildAgilityDetails (NewDetailItem @{ Reference = "<b>x</b>" }) | Should -Match "&lt;b&gt;x&lt;/b&gt;"
  }

  It "still returns nothing when the item has none of them" {
    BuildAgilityDetails (NewDetailItem @{}) | Should -Be ""
  }
}

##################################################################################################
# Acceptance criteria are cloned out of the description into the real ADO field, and left in place.
#
# Measured across all 619 Epic descriptions: 100 carry an "Acceptance Criteria" heading, spelled
# that way every time (case varies, trailing colon optional). 65 run to the end of the description
# and 35 are followed by a "Constraints" heading, which is what bounds the section. There are NO
# uses of "A/C", "Definition of Done" or "DoD", and the only two standalone "AC" tokens in the whole
# corpus are prose about student records, not headings - which is why AC is matched only in heading
# position with a colon.
##################################################################################################
Describe "ExtractAcceptanceCriteria" {

  It "takes the list that follows a bold heading" {
    ExtractAcceptanceCriteria '<p>intro</p><p><strong>Acceptance Criteria:</strong></p><ul><li>a</li></ul>' |
      Should -Be '<ul><li>a</li></ul>'
  }

  It "takes the list that follows a plain paragraph heading" {
    ExtractAcceptanceCriteria '<p>Acceptance Criteria:</p><ul><li>a</li><li>b</li></ul>' |
      Should -Be '<ul><li>a</li><li>b</li></ul>'
  }

  # 35 of the 100 are followed by a Constraints heading. Everything after it belongs to that section.
  It "stops at the next bold heading, so Constraints do not become criteria" {
    ExtractAcceptanceCriteria '<p><strong>Acceptance Criteria:</strong></p><ul><li>a</li></ul><p><strong>Constraints:</strong></p><ul><li>b</li></ul>' |
      Should -Be '<ul><li>a</li></ul>'
  }

  # Constraints is written WITHOUT bold on 13 Epics, and those leaked into the criteria until the
  # plain-paragraph form was added as a terminator.
  It "stops at a plain heading paragraph that ends in a colon" {
    ExtractAcceptanceCriteria '<p>Acceptance Criteria:</p><ul><li>a</li></ul><p>Constraints:</p><ul><li>b</li></ul>' |
      Should -Be '<ul><li>a</li></ul>'
  }

  It "stops at other plain sub-headings seen in the data" {
    ExtractAcceptanceCriteria '<p>Acceptance Criteria:</p><ul><li>a</li></ul><p>NOTES:</p><p>b</p>' |
      Should -Be '<ul><li>a</li></ul>'
  }

  # The colon alone must not end a section, or a criterion written as a sentence would truncate it.
  # Only a SHORT paragraph counts as a heading.
  It "does not treat a long sentence ending in a colon as a heading" {
    $long = 'The following systems must each be verified by the operations team before release:'
    ExtractAcceptanceCriteria "<p>Acceptance Criteria:</p><p>$long</p><ul><li>a</li></ul>" |
      Should -Be "<p>$long</p><ul><li>a</li></ul>"
  }

  It "does not treat a plain paragraph with no colon as a heading" {
    ExtractAcceptanceCriteria '<p>Acceptance Criteria:</p><ul><li>a</li></ul><p>still criteria</p>' |
      Should -Be '<ul><li>a</li></ul><p>still criteria</p>'
  }

  It "runs to the end when nothing follows the section" {
    ExtractAcceptanceCriteria '<p><strong>Acceptance Criteria</strong></p><ul><li>only</li></ul>' |
      Should -Be '<ul><li>only</li></ul>'
  }

  It "matches whatever case the heading was written in" {
    ExtractAcceptanceCriteria '<p>acceptance criteria:</p><ul><li>a</li></ul>' | Should -Be '<ul><li>a</li></ul>'
    ExtractAcceptanceCriteria '<p>ACCEPTANCE CRITERIA</p><ul><li>a</li></ul>' | Should -Be '<ul><li>a</li></ul>'
  }

  It "matches a heading with no colon" {
    ExtractAcceptanceCriteria '<p><strong>Acceptance Criteria</strong></p><p>must work</p>' | Should -Be '<p>must work</p>'
  }

  # 2 of the 100 headings sit inside a nested list, so the slice begins part way out of it and the
  # section would otherwise start with closing tags it never opened. A section can never legitimately
  # begin by closing something, so a leading run of them is always orphaned.
  It "drops orphaned closing tags left by a heading inside a list" {
    ExtractAcceptanceCriteria '<ol><li>Acceptance Criteria:</li></ol><ul><li>a</li></ul>' |
      Should -Be '<ul><li>a</li></ul>'
  }

  It "trims trailing empty paragraphs" {
    ExtractAcceptanceCriteria '<p>Acceptance Criteria:</p><ul><li>a</li></ul><p><br></p><p>&nbsp;</p>' |
      Should -Be '<ul><li>a</li></ul>'
  }

  It "returns nothing when the description has no acceptance criteria" {
    ExtractAcceptanceCriteria '<p>just a description</p>' | Should -BeNullOrEmpty
  }

  It "returns nothing for an empty or missing description" {
    ExtractAcceptanceCriteria ''    | Should -BeNullOrEmpty
    ExtractAcceptanceCriteria $null | Should -BeNullOrEmpty
  }

  # A heading with nothing under it must not write an empty field.
  It "returns nothing when the section is empty" {
    ExtractAcceptanceCriteria '<p><strong>Acceptance Criteria:</strong></p><p><br></p>' | Should -BeNullOrEmpty
  }

  # The ONLY two standalone "AC" tokens in all 619 descriptions are these, both prose about student
  # record lines. Matching a bare AC would produce two false positives and zero true ones.
  It "does not mistake AC in prose for a heading" {
    ExtractAcceptanceCriteria '<p>sometimes after MTS their file stays at AC.</p><p>more text</p>' |
      Should -BeNullOrEmpty
    ExtractAcceptanceCriteria '<p>an AP line exists but no MS or AC line</p><ul><li>x</li></ul>' |
      Should -BeNullOrEmpty
  }

  # AC IS honoured in heading position, which is what the abbreviation was asked for.
  It "accepts AC as a heading when it is written as one" {
    ExtractAcceptanceCriteria '<p><strong>AC:</strong></p><ul><li>a</li></ul>' | Should -Be '<ul><li>a</li></ul>'
    ExtractAcceptanceCriteria '<p>AC:</p><ul><li>a</li></ul>'                  | Should -Be '<ul><li>a</li></ul>'
  }

  It "does not treat a lower case 'ac:' as the abbreviation" {
    ExtractAcceptanceCriteria '<p>ac: something unrelated</p><ul><li>x</li></ul>' | Should -BeNullOrEmpty
  }
}

Describe "Acceptance criteria reach the ADO field" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{
      RequiredFields = [pscustomobject]@{
        AgilityId = "Custom.DigitalAIID"; AgilityStatus = "Custom.DigitalAIStatus"
        AgilityCategory = "Custom.DigitalAICategory"; AgilityFY = "Custom.DigitalAIFY"
      }
      CustomFields = [pscustomobject]@{
        AcceptanceCriteria = [pscustomobject]@{
          Field = "Microsoft.VSTS.Common.AcceptanceCriteria"
          AdoTypes = @("Epic", "Feature", "Product Backlog Item", "Bug")
        }
      }
      Fields     = [pscustomobject]@{}
      States     = [pscustomobject]@{ Epic = [pscustomobject]@{ DefaultState = "New"; ClosedState = "Done"; Map = [pscustomobject]@{} } }
      Priorities = [pscustomobject]@{ DefaultPriority = 2; Map = [pscustomobject]@{} }
    }
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ Project = "Migration" } }

    function NewAcItem($adoType, $description)
    {
      return [pscustomobject]@{
        AgilityType = "Epic"; Number = "E-1"; Name = "epic"; AdoType = $adoType
        AssetState = 64; Status = $null; Description = $description
        OwnerNames = @(); OwnerEmails = @(); AreaPath = ""
        FiscalYears = @(); Mandates = @(); StrategicThemes = @(); AgilityTags = @()
      }
    }
    function ValueAt($patch, $path) { @($patch | Where-Object { $_.path -eq $path })[0].value }
  }

  It "clones the criteria out of the description into the field" {
    $patch = BuildFieldPatch (NewAcItem 'Epic' '<p><strong>Acceptance Criteria:</strong></p><ul><li>a</li></ul>')

    ValueAt $patch "/fields/Microsoft.VSTS.Common.AcceptanceCriteria" | Should -Be '<ul><li>a</li></ul>'
  }

  # A clone, not a move: the user asked for it to stay in the description too.
  It "leaves the criteria in the description as well" {
    $patch = BuildFieldPatch (NewAcItem 'Epic' '<p><strong>Acceptance Criteria:</strong></p><ul><li>a</li></ul>')

    ValueAt $patch "/fields/System.Description" | Should -Match ([regex]::Escape('<li>a</li>'))
    ValueAt $patch "/fields/System.Description" | Should -Match "Acceptance Criteria"
  }

  It "writes nothing when the description has no criteria" {
    $patch = BuildFieldPatch (NewAcItem 'Epic' '<p>plain</p>')

    @($patch | Where-Object { $_.path -like "*AcceptanceCriteria*" }) | Should -BeNullOrEmpty
  }

  # Task and Impediment have no such field, and ADO would accept the write and drop it silently.
  It "does not write the field on a type that does not have it" {
    $patch = BuildFieldPatch (NewAcItem 'Task' '<p>Acceptance Criteria:</p><ul><li>a</li></ul>')

    @($patch | Where-Object { $_.path -like "*AcceptanceCriteria*" }) | Should -BeNullOrEmpty
  }
}

##################################################################################################
# Follow-ups from the Epic field audit (2026-07-30). Measured against all 877 Epics in the five
# configured scopes; every count in these comments is from that measurement, not an estimate.
##################################################################################################
Describe "Multi-value fiscal year and mandate are no longer truncated" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{
      RequiredFields = [pscustomobject]@{
        AgilityId = "Custom.DigitalAIID"; AgilityStatus = "Custom.DigitalAIStatus"
        AgilityCategory = "Custom.DigitalAICategory"; AgilityFY = "Custom.DigitalAIFY"
      }
      CustomFields = [pscustomobject]@{
        Mandate = [pscustomobject]@{ Field = "Custom.DigitalAIMandate"; AdoTypes = @("Epic", "Feature") }
      }
      Fields     = [pscustomobject]@{}
      States     = [pscustomobject]@{ Epic = [pscustomobject]@{ DefaultState = "New"; ClosedState = "Done"; Map = [pscustomobject]@{} } }
      Priorities = [pscustomobject]@{ DefaultPriority = 2; Map = [pscustomobject]@{} }
    }
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ Project = "Migration" } }

    function NewFyItem($fys, $mandates)
    {
      return [pscustomobject]@{
        AgilityType = "Epic"; Number = "E-1"; Name = "epic"; AdoType = "Epic"
        AssetState = 64; Status = $null; FiscalYears = $fys; Mandates = $mandates
        OwnerNames = @(); OwnerEmails = @(); AreaPath = ""; Category = $null
        StrategicThemes = @(); AgilityTags = @()
      }
    }
    function ValueAt($patch, $path) { @($patch | Where-Object { $_.path -eq $path })[0].value }
  }

  # 42 of the 114 Epics with a fiscal year have more than one (27x2, 13x3, 2x4). Reading only the
  # first dropped 59 values; E-05100 really does carry FY 21, FY 22, FY 20 and FY 23.
  It "writes every fiscal year, not just the first" {
    ValueAt (BuildFieldPatch (NewFyItem @("FY 21", "FY 22", "FY 20") @())) "/fields/Custom.DigitalAIFY" |
      Should -Be "FY 21; FY 22; FY 20"
  }

  It "writes a single fiscal year without a separator" {
    ValueAt (BuildFieldPatch (NewFyItem @("FY 23") @())) "/fields/Custom.DigitalAIFY" | Should -Be "FY 23"
  }

  # The field is written on every item even when empty, so it always means something.
  It "still writes an empty fiscal year when there is none" {
    ValueAt (BuildFieldPatch (NewFyItem @() @())) "/fields/Custom.DigitalAIFY" | Should -Be ""
  }

  # 2 of the 90 Epics with a mandate carry two.
  It "writes every mandate, not just the first" {
    ValueAt (BuildFieldPatch (NewFyItem @() @("Vendor Requirement", "Federal"))) "/fields/Custom.DigitalAIMandate" |
      Should -Be "Vendor Requirement; Federal"
  }

  It "omits the mandate field entirely when there is no mandate" {
    @((BuildFieldPatch (NewFyItem @() @())) | Where-Object { $_.path -like "*Mandate*" }) | Should -BeNullOrEmpty
  }
}

Describe "Epic extras the audit found: parser" {

  BeforeAll {
    function EpicPayload($attributes)
    {
      return [pscustomobject]@{ Assets = @([pscustomobject]@{ id = "Epic:1"; Attributes = [pscustomobject]$attributes }) }
    }
    function Attr($value) { return [pscustomobject]@{ value = $value } }
  }

  It "reads every fiscal year and mandate as a list" {
    $parsed = ConvertFromAgilityAssets (EpicPayload @{
      'Custom_FiscalYear.Name' = Attr @("FY 21", "FY 22")
      'Custom_Mandate.Name'    = Attr @("Vendor Requirement", "Federal")
    }) 'Epic'

    $parsed[0].FiscalYears | Should -Be @("FY 21", "FY 22")
    $parsed[0].Mandates    | Should -Be @("Vendor Requirement", "Federal")
  }

  # 27 Epics carry Agility's own tag list, up to 5 tags each.
  It "reads TaggedWith, Agility's own tag list" {
    $parsed = ConvertFromAgilityAssets (EpicPayload @{ TaggedWith = Attr @("IT", "Phishing") }) 'Epic'

    $parsed[0].AgilityTags | Should -Be @("IT", "Phishing")
  }

  # 20 Epics depend on another Epic and 16 are depended on; both carry .Number.
  It "reads the dependency numbers at both ends" {
    $parsed = ConvertFromAgilityAssets (EpicPayload @{
      'Dependencies.Number' = Attr @("E-05908", "E-05909")
      'Dependants.Number'   = Attr @("E-05911")
    }) 'Epic'

    $parsed[0].DependencyNumbers | Should -Be @("E-05908", "E-05909")
    $parsed[0].DependantNumbers  | Should -Be @("E-05911")
  }

  It "reads the person who closed the Epic" {
    $parsed = ConvertFromAgilityAssets (EpicPayload @{
      'ClosedBy.Name'  = Attr "Richard Goldsberry"
      'ClosedBy.Email' = Attr "rgoldsberry@example.com"
    }) 'Epic'

    $parsed[0].ClosedByName  | Should -Be "Richard Goldsberry"
    $parsed[0].ClosedByEmail | Should -Be "rgoldsberry@example.com"
  }

  # Links.URL and Links.Name are two lists read off ONE relation, so index i must mean the same link
  # in both. This is the Owners null-padding trap: a link with no name would slide every later URL up
  # a slot if the nulls were stripped.
  It "keeps link urls and names aligned when one has no name" {
    $parsed = ConvertFromAgilityAssets (EpicPayload @{
      'Links.URL'  = Attr @("https://a", "https://b", "https://c")
      'Links.Name' = Attr @("A", $null, "C")
    }) 'Epic'

    @($parsed[0].LinkUrls).Count  | Should -Be 3
    @($parsed[0].LinkNames).Count | Should -Be 3
    @($parsed[0].LinkNames)[2]    | Should -Be "C"
  }
}

Describe "Epic extras the audit found: tags" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{ Tags = [pscustomobject]@{} }

    function NewTagItem($props)
    {
      $base = @{
        ParentUnresolved = $false; ParentNumberForTag = $null; BlockedUnresolved = @()
        Source = $null; AgilityTags = @(); DependencyUnresolved = @()
      }
      foreach ($k in $props.Keys) { $base[$k] = $props[$k] }
      return [pscustomobject]$base
    }
  }

  # Agility's own tags belong in System.Tags, which the tool already writes.
  It "carries Agility's TaggedWith values into System.Tags" {
    BuildTags (NewTagItem @{ AgilityTags = @("AV", "Classroom") }) | Should -Be "AV; Classroom"
  }

  # ADO separates tags with semicolons, so one inside a value would split it into two tags.
  It "replaces a semicolon inside an Agility tag" {
    BuildTags (NewTagItem @{ AgilityTags = @("a;b") }) | Should -Be "a,b"
  }

  # 93 Epics carry a Source. BuildTags was always type-agnostic; only the selection was missing it.
  It "tags an Epic's Source, now that the selection asks for it" {
    BuildTags (NewTagItem @{ Source = "Employees" }) | Should -Be "agility-source:Employees"
  }

  It "tags a dependency that is not in Azure DevOps, so the relationship is not lost" {
    BuildTags (NewTagItem @{ DependencyUnresolved = @("E-09999") }) | Should -Be "agility-depends:E-09999"
  }

  It "still produces nothing for an item with nothing worth tagging" {
    BuildTags (NewTagItem @{}) | Should -Be ""
  }
}

Describe "Epic dependencies become Successor and Predecessor links" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{
      LinkTypes = [pscustomobject]@{
        Parent      = "System.LinkTypes.Hierarchy-Reverse"
        Related     = "System.LinkTypes.Related"
        Blocks      = "Microsoft.VSTS.Common.Affects-Forward"
        Successor   = "System.LinkTypes.Dependency-Forward"
        Predecessor = "System.LinkTypes.Dependency-Reverse"
      }
    }
    $script:DryRun = $false
    $script:DryRunPendingId = 'would-be-created-by-this-run'

    function NewDepItem($deps, $dependants)
    {
      return [pscustomobject]@{ DependencyNumbers = $deps; DependantNumbers = $dependants }
    }
  }

  It "resolves a dependency that is already in Azure DevOps" {
    $r = ResolveDependencyIds (NewDepItem @("E-2") @()) @{ "E-2" = 101 }

    $r.Successors   | Should -Be @(101)
    $r.Predecessors | Should -BeNullOrEmpty
    $r.Unresolved   | Should -BeNullOrEmpty
  }

  It "resolves the other end as a predecessor" {
    $r = ResolveDependencyIds (NewDepItem @() @("E-3")) @{ "E-3" = 202 }

    $r.Predecessors | Should -Be @(202)
  }

  # An Epic outside the configured scopes keeps its number as a tag, the same as an unmigrated parent.
  It "reports a dependency that is not in Azure DevOps as unresolved" {
    $r = ResolveDependencyIds (NewDepItem @("E-9") @()) @{}

    $r.Successors | Should -BeNullOrEmpty
    $r.Unresolved | Should -Be @("E-9")
  }

  # A dry run creates nothing, so a target this run WOULD create must not be reported as a miss.
  It "does not count an item this run would create as unresolved" {
    $r = ResolveDependencyIds (NewDepItem @("E-4") @()) @{ "E-4" = $script:DryRunPendingId }

    $r.Unresolved  | Should -BeNullOrEmpty
    $r.Successors  | Should -BeNullOrEmpty
  }
}

##################################################################################################
# Dependency links must NOT ride in the create (fixed 2026-08-01, after it lost 4 Stories).
#
# Agility lets dependency graphs contain cycles; ADO's Dependency link type does not. A cyclic link
# inside the create patch makes ADO reject the WHOLE create with TF201035, so the work item is never
# made at all - "Adding a Successor link between work items -1 and 111216 would result in a circular
# relationship". The -1 is the item being created, which is how we know it was the create.
#
# So the links are added AFTER the item exists, in their own non-fatal patch: one call per item, and
# if that batch is rejected each link is retried alone so only the genuinely cyclic one is dropped.
##################################################################################################
Describe "Dependency links are added after the create, never inside it" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{
      LinkTypes = [pscustomobject]@{
        Parent      = "System.LinkTypes.Hierarchy-Reverse"
        Related     = "System.LinkTypes.Related"
        Blocks      = "Microsoft.VSTS.Common.Affects-Forward"
        Successor   = "System.LinkTypes.Dependency-Forward"
        Predecessor = "System.LinkTypes.Dependency-Reverse"
      }
    }
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/org" } }

    function Deps($successors, $predecessors)
    {
      return [pscustomobject]@{ Successors = $successors; Predecessors = $predecessors; Unresolved = @() }
    }
  }

  BeforeEach { $script:DryRun = $false; $script:warnings = 0; $script:patches = @() }

  # The create must be incapable of failing on a cycle, because a failed create loses the item.
  It "keeps dependency relations out of the create payload" {
    $source = Get-Content $script:scriptPath -Raw
    $body = [regex]::Match($source, "function NewAdoWorkItem\b[\s\S]*?(?=\r?\nfunction )").Value

    $body | Should -Not -Match 'LinkTypes\.Successor'   -Because "a cyclic Successor in the create kills the whole item"
    $body | Should -Not -Match 'LinkTypes\.Predecessor'
  }

  It "recognises the circular link rejection" {
    IsCircularLinkProblem 'TF201035: Adding a Successor link between work items -1 and 111216 would result in a circular relationship.' |
      Should -BeTrue
    IsCircularLinkProblem 'TF401320: Rule Error for field Closed By.' | Should -BeFalse
  }

  It "patches Successor and Predecessor links after the item exists" {
    Mock InvokeAdoRequest { $script:patches += ,$body }

    AddAdoDependencyLinks 42 ([pscustomobject]@{ Number = 'S-1' }) (Deps @(101) @(202))

    @($script:patches).Count | Should -Be 1 -Because "one batched call per item is the common case"
    $ops = $script:patches[0]
    @($ops).Count | Should -Be 2
    $ops[0].value.rel | Should -Be 'System.LinkTypes.Dependency-Forward'
    $ops[0].value.url | Should -BeLike '*101'
    $ops[1].value.rel | Should -Be 'System.LinkTypes.Dependency-Reverse'
  }

  It "does nothing when the item has no dependencies" {
    Mock InvokeAdoRequest { $script:patches += ,$body }

    AddAdoDependencyLinks 42 ([pscustomobject]@{ Number = 'S-1' }) (Deps @() @())

    @($script:patches).Count | Should -Be 0
  }

  # The whole point: a cycle must cost one LINK, not the work item and not its other links.
  It "retries links one at a time when the batch is rejected, keeping the good ones" {
    $script:attempt = 0
    Mock InvokeAdoRequest {
      $script:attempt++
      $script:patches += ,$body
      # The batch and then the link to 999 are cyclic; the others must still go in.
      if ($script:attempt -eq 1) { throw "TF201035: circular relationship" }
      if (@($body)[0].value.url -like '*999') { throw "TF201035: circular relationship" }
    }

    { AddAdoDependencyLinks 42 ([pscustomobject]@{ Number = 'S-1' }) (Deps @(101, 999, 103) @()) } |
      Should -Not -Throw

    # 1 batch + 3 individual retries.
    @($script:patches).Count | Should -Be 4
    $script:warnings | Should -BeGreaterThan 0 -Because "the dropped link must be reported"
  }

  # A failure here must never cost the item, which already exists by this point.
  It "warns rather than throwing when a link cannot be added at all" {
    Mock InvokeAdoRequest { throw "something else entirely" }

    { AddAdoDependencyLinks 42 ([pscustomobject]@{ Number = 'S-1' }) (Deps @(101) @()) } | Should -Not -Throw
    $script:warnings | Should -BeGreaterThan 0
  }

  It "writes nothing on a dry run" {
    $script:DryRun = $true
    Mock InvokeAdoRequest { $script:patches += ,$body }

    AddAdoDependencyLinks 42 ([pscustomobject]@{ Number = 'S-1' }) (Deps @(101) @())

    @($script:patches).Count | Should -Be 0
  }
}

Describe "Epic links and closer reach Azure DevOps" {

  BeforeAll {
    $script:mappings = [pscustomobject]@{
      Fields    = [pscustomobject]@{ ClosedBy = "Microsoft.VSTS.Common.ClosedBy" }
      LinkTypes = [pscustomobject]@{
        Parent      = "System.LinkTypes.Hierarchy-Reverse"
        Related     = "System.LinkTypes.Related"
        Blocks      = "Microsoft.VSTS.Common.Affects-Forward"
        Successor   = "System.LinkTypes.Dependency-Forward"
        Predecessor = "System.LinkTypes.Dependency-Reverse"
      }
    }
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/org" } }
    # Off, so an uncached identity is assumed assignable and no probe is attempted.
    $script:ProbeAssignability = $false
    $script:assignableCache = @{}
  }

  # 3 of the 5 links are https; the other two are I:\ file-share paths, which ADO's Hyperlink
  # relation cannot take. They must not be silently dropped.
  It "makes a hyperlink out of an http url" {
    # Wrapped, because a one element array unrolls to the bare hashtable on the way out.
    $ops = @(BuildHyperlinkOps ([pscustomobject]@{ LinkUrls = @("https://example.com/doc"); LinkNames = @("A doc") }))

    $ops.Count          | Should -Be 1
    $ops[0].path        | Should -Be "/relations/-"
    $ops[0].value.rel   | Should -Be "Hyperlink"
    $ops[0].value.url   | Should -Be "https://example.com/doc"
    $ops[0].value.attributes.comment | Should -Be "A doc"
  }

  It "does not try to hyperlink a file share path, which ADO would reject" {
    BuildHyperlinkOps ([pscustomobject]@{ LinkUrls = @("I:\IT Private\EAS"); LinkNames = @("Share") }) |
      Should -BeNullOrEmpty
  }

  It "keeps an unlinkable path in the description instead of dropping it" {
    $description = BuildDescription ([pscustomobject]@{
      Description = "body"; Number = "E-1"
      LinkUrls = @("I:\IT Private\EAS"); LinkNames = @("Share")
    }) $null

    $description | Should -Match ([regex]::Escape("I:\IT Private\EAS"))
  }

  It "does not add a links block when every link became a hyperlink" {
    $description = BuildDescription ([pscustomobject]@{
      Description = "body"; Number = "E-1"
      LinkUrls = @("https://example.com"); LinkNames = @("A")
    }) $null

    $description | Should -Not -Match "Agility links"
  }

  # Microsoft.VSTS.Common.ClosedBy exists on Epic and Feature and is writable, verified live. It is
  # an IDENTITY field, so it goes in a rule-checked patch: under bypassRules ADO would store a
  # departed closer as an unresolvable historical identity, exactly the AssignedTo hazard.
  It "prefers the closer's email over their name" {
    ResolveClosedBy ([pscustomobject]@{ ClosedByEmail = "a@example.com"; ClosedByName = "A B" }) |
      Should -Be "a@example.com"
  }

  It "falls back to the closer's name when there is no email" {
    ResolveClosedBy ([pscustomobject]@{ ClosedByEmail = $null; ClosedByName = "A B" }) | Should -Be "A B"
  }

  # 406 of the 773 closers are not org members (Brittney Trimmer alone closed 311). Writing one would
  # fail the patch, so an unassignable closer is skipped and the item keeps everything else.
  It "returns nothing for a closer Azure DevOps will not accept" {
    $script:assignableCache = @{ "gone@example.com" = $false }

    ResolveClosedBy ([pscustomobject]@{ ClosedByEmail = "gone@example.com"; ClosedByName = $null }) |
      Should -BeNullOrEmpty
  }

  # Closed By is READ ONLY under process rules, so a rule-checked patch is rejected outright with
  # TF401320 "ReadOnly, AllowsOldValue, InvalidNotOldValue". That failed 161 Epics on a real run: the
  # item was created, transitioned, assigned, and only then died on this field.
  #
  # It therefore rides in the bypassRules CREATE, which is verified to persist through the later
  # transition and the rule-checked assignee patch after it. What makes bypass safe here is
  # ResolveClosedBy: bypass skips identity validation, so the assignability filter is the only thing
  # standing between a departed closer and an unresolvable stored identity. Do not remove it.
  It "carries the closer in the bypassRules create" {
    $op = BuildClosedByOp ([pscustomobject]@{ ClosedByEmail = "a@example.com"; ClosedByName = $null })

    $op.path  | Should -Be "/fields/Microsoft.VSTS.Common.ClosedBy"
    $op.value | Should -Be "a@example.com"
  }

  It "produces no closer op when there is nobody usable" {
    BuildClosedByOp ([pscustomobject]@{ ClosedByEmail = $null; ClosedByName = $null }) | Should -BeNullOrEmpty
  }

  It "produces no closer op for an identity Azure DevOps rejects" {
    $script:assignableCache = @{ "gone@example.com" = $false }

    BuildClosedByOp ([pscustomobject]@{ ClosedByEmail = "gone@example.com"; ClosedByName = $null }) |
      Should -BeNullOrEmpty
  }

  # A rule-checked validateOnly REJECTS Closed By (verified live: "AllowsOldValue, InvalidNotEmpty"),
  # and BuildFieldPatch is shared with the dry run. Putting it there would make every dry run report
  # INVALID on every closed item.
  It "keeps the closer OUT of the shared field patch, which the dry run validates rule-checked" {
    $source = Get-Content $script:scriptPath -Raw
    function BodyOf($src, $name) { [regex]::Match($src, "function $name\b[\s\S]*?(?=\r?\nfunction )").Value }

    (BodyOf $source 'BuildFieldPatch') | Should -Not -Match 'Fields\.ClosedBy' `
      -Because "a rule-checked validateOnly rejects Closed By outright"
  }

  It "adds the closer op to the create, which is the bypass payload" {
    $source = Get-Content $script:scriptPath -Raw
    function BodyOf($src, $name) { [regex]::Match($src, "function $name\b[\s\S]*?(?=\r?\nfunction )").Value }

    $create = BodyOf $source 'NewAdoWorkItem'
    $create | Should -Match 'BuildClosedByOp'
    $create | Should -Match 'bypassRules=true'
  }

  # The whole point of the rewrite: nothing may patch Closed By outside the bypass create.
  It "has no rule-checked patch of the closer left anywhere" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Not -Match 'function SetAdoClosedBy' `
      -Because "the separate rule-checked patch is what TF401320 rejected"
  }
}

Describe "Logging" {

  BeforeAll {
    # A temp directory per test run, so these never touch the repo's own logs/ folder.
    $script:tempLogDir = Join-Path ([IO.Path]::GetTempPath()) ("agility-log-tests-" + [Guid]::NewGuid().ToString('N'))
    $script:realLogDir = $script:logDir
  }

  AfterEach {
    StopLog
    $script:logDir = $script:realLogDir
  }

  AfterAll {
    StopLog
    if (Test-Path $script:tempLogDir) { Remove-Item $script:tempLogDir -Recurse -Force -ErrorAction SilentlyContinue }
  }

  It "creates the log directory and a file named for the moment the run started" {
    $script:logDir = $script:tempLogDir
    StartLog

    $script:logPath | Should -Not -BeNullOrEmpty
    Test-Path $script:logPath | Should -BeTrue
    (Split-Path $script:logPath -Leaf) | Should -Match '^Migrate-Agility-\d{8}-\d{6}\.log$'
  }

  It "gives each run its own file rather than appending to the last one" {
    $script:logDir = $script:tempLogDir

    StartLog
    $first = $script:logPath
    WriteLog "from the first run"

    # The name is stamped to the second, so a same second restart would collide. Force a distinct
    # name the way a real second run would get one, and assert the writer moved.
    Start-Sleep -Milliseconds 1100
    StartLog
    $second = $script:logPath
    WriteLog "from the second run"

    $second | Should -Not -Be $first
    (Get-Content $first -Raw)  | Should -Match 'from the first run'
    (Get-Content $first -Raw)  | Should -Not -Match 'from the second run'
    (Get-Content $second -Raw) | Should -Match 'from the second run'
  }

  It "writes to the file what it writes to the console" {
    $script:logDir = $script:tempLogDir
    StartLog

    WriteLog "  WOULD   Bug      D-01966 something happened"
    WriteLog "  FAIL    S-1 broke" Red

    $content = Get-Content $script:logPath -Raw
    $content | Should -Match 'WOULD   Bug      D-01966 something happened'
    $content | Should -Match 'FAIL    S-1 broke'
  }

  # The README's summary greps anchor on the item text. A timestamp or level prefix on every line
  # would break every one of them, so the log is a faithful copy, not a reformatted one.
  It "does not prefix lines, so the log greps exactly like the console output" {
    $script:logDir = $script:tempLogDir
    StartLog

    WriteLog "  WOULD   Bug      D-1 x"

    $line = (Get-Content $script:logPath) | Where-Object { $_ -match 'D-1' }
    $line | Should -Be "  WOULD   Bug      D-1 x"
  }

  It "flushes each line, so a run killed mid flight still has a readable log" {
    $script:logDir = $script:tempLogDir
    StartLog

    WriteLog "written but not closed"

    # Deliberately no StopLog: the content must already be on disk.
    (Get-Content $script:logPath -Raw) | Should -Match 'written but not closed'
  }

  It "keeps error detail out of the console but in the file" {
    $script:logDir = $script:tempLogDir
    StartLog

    WriteLogDetail "detail only"

    (Get-Content $script:logPath -Raw) | Should -Match 'detail only'
  }

  # ReadAdoError returns only the human message. Without the rest, a failed run leaves nothing to
  # diagnose once the error record is gone.
  It "records the status, the raw ADO body, and the stack behind a one line failure" {
    $script:logDir = $script:tempLogDir
    StartLog

    $rec = [pscustomobject]@{
      Exception        = [Exception]::new("boom")
      ErrorDetails     = [pscustomobject]@{ Message = '{"message":"Rule Error for field Closed Date","errorCode":600171}' }
      ScriptStackTrace = "at NewAdoWorkItem, Migrate-Agility.ps1: line 900`nat MigrateItem, Migrate-Agility.ps1: line 870"
    }

    WriteErrorDetail $rec "Story S-1 -> Product Backlog Item"

    $content = Get-Content $script:logPath -Raw
    $content | Should -Match 'error detail: Story S-1 -> Product Backlog Item'
    $content | Should -Match 'boom'
    $content | Should -Match 'Rule Error for field Closed Date'
    $content | Should -Match 'line 900'
  }

  # A migration that is otherwise succeeding must not die because a log line could not be written.
  It "carries on with the console when the log cannot be opened" {
    # A path under a file cannot be a directory, so New-Item fails.
    $blocker = Join-Path ([IO.Path]::GetTempPath()) ("agility-blocker-" + [Guid]::NewGuid().ToString('N'))
    Set-Content -Path $blocker -Value "not a directory"
    $script:logDir = Join-Path $blocker "logs"

    { StartLog } | Should -Not -Throw
    $script:logPath | Should -BeNullOrEmpty

    # And the progress calls must still be safe with no writer behind them.
    { WriteLog "still talking" } | Should -Not -Throw
    { WriteLogDetail "still recording" } | Should -Not -Throw

    Remove-Item $blocker -Force -ErrorAction SilentlyContinue
  }

  It "is safe to stop a log that was never started" {
    StopLog
    { StopLog } | Should -Not -Throw
  }

  # A Write-Host inside a run prints a line that never reaches the log, so the log quietly stops
  # being the record of what happened. That is invisible from the outside, because the console
  # still looks right. Only three regions may legitimately bypass WriteLog:
  #   Main            - its banner prints before Migrate opens a log
  #   the Logging block - WriteLog is built out of Write-Host, so it has to call it
  #   the dot source guard - not part of any run
  # Everything between them is a run, and a run's output belongs in the log.
  It "routes every progress line through WriteLog, so the console and the log cannot drift" {
    $lines = Get-Content $script:scriptPath

    $inMain = $false
    $inLogging = $false
    $inGuard = $false
    $offenders = @()

    for ($i = 0; $i -lt $lines.Count; $i++)
    {
      $line = $lines[$i]

      # Region tracking. Section banners and top level function declarations are the boundaries.
      if ($line -match '^function Main\s*$')      { $inMain = $true }
      elseif ($line -match '^function \w+')       { $inMain = $false }

      if ($line -match '^# Logging\s*$')                  { $inLogging = $true }
      if ($line -match '^# Configuration and secrets\s*$') { $inLogging = $false }

      if ($line -match '^if \(\$global:AgilityEpicsLoadFunctionsOnly\)') { $inGuard = $true }

      if ($line -notmatch 'Write-Host') { continue }
      if ($line -match '^\s*#') { continue }
      if ($inMain -or $inLogging -or $inGuard) { continue }

      $offenders += "line $($i + 1): $($line.Trim())"
    }

    $offenders | Should -BeNullOrEmpty -Because "these should call WriteLog: $($offenders -join ' | ')"
  }

  # The guard above is only worth having if it actually fires, and a region based check is easy to
  # write so loosely that it excludes the whole file. Prove it still catches a real offender.
  It "would catch a Write-Host added to the migration path" {
    $lines = @(
      'function Main',
      '  Write-Host "banner"',
      'function MigrateItem($epic)',
      '  Write-Host "  CREATE  sneaky"'
    )

    $inMain = $false
    $offenders = @()

    foreach ($line in $lines)
    {
      if ($line -match '^function Main\s*$') { $inMain = $true }
      elseif ($line -match '^function \w+')  { $inMain = $false }

      if ($line -notmatch 'Write-Host') { continue }
      if ($inMain) { continue }

      $offenders += $line.Trim()
    }

    $offenders.Count | Should -Be 1
    $offenders[0] | Should -BeLike '*sneaky*'
  }
}

Describe "Agility is read only" {

  It "hard codes -Method Get in the only function that calls Agility" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Match 'function InvokeAgilityGet[\s\S]*?-Method Get'
  }

  # Attachments need raw bytes, which the JSON reader cannot return, so there is a SECOND door to
  # Agility. It carries the same guarantee: Get is hard coded and there is no method parameter.
  It "hard codes -Method Get in the attachment download too" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Match 'function InvokeAgilityDownload[\s\S]*?-Method Get'
    $source | Should -Not -Match 'function InvokeAgilityDownload\([^)]*\$method'
  }

  It "never sends a write verb to the attachment endpoint" {
    $lines = Get-Content $script:scriptPath

    @($lines | Where-Object { $_ -match 'attachment\.img' -and $_ -match '-Method\s+(Post|Put|Delete|Patch)' }) |
      Should -BeNullOrEmpty
  }

  It "has no Agility call site outside InvokeAgilityGet" {
    # Any Agility write would have to construct a non Get call against the rest-1.v1 endpoint.
    # Assert that rest-1.v1 only ever appears on a URL built for InvokeAgilityGet.
    $lines = Get-Content $script:scriptPath

    $writeVerbs = $lines | Where-Object { $_ -match 'rest-1\.v1' -and $_ -match '-Method\s+(Post|Put|Delete|Patch)' }

    $writeVerbs | Should -BeNullOrEmpty
  }

  It "never sends a write verb to Agility from the retry wrapper" {
    $source = Get-Content $script:scriptPath -Raw

    # InvokeAgilityGet must not take a method parameter that a caller could set to Post.
    $source | Should -Not -Match 'function InvokeAgilityGet\([^)]*\$method'
  }
}

Describe "MaterializeOwners: add recoverable owners to the org as free Stakeholders" {

  BeforeAll {
    $script:config = [pscustomobject]@{
      AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/contoso"; Project = "Migration" }
      Agility     = [pscustomobject]@{ BaseUrl = "https://v1host/YourInstance"; Scopes = @([pscustomobject]@{ Scope = "Scope:1" }) }
    }
  }

  # The Member Entitlement Management endpoint returns HTTP 200 EVEN ON FAILURE, with the real verdict
  # in operationResult. Reading the status code alone would call every failure a success.
  Context "EntitleStakeholder reads operationResult, not the HTTP status" {

    It "reports 'added' when the entitlement succeeds" {
      Mock InvokeAdoRequest { [pscustomobject]@{ operationResult = [pscustomobject]@{ isSuccess = $true; userId = "guid-1" } } }
      (EntitleStakeholder "alex@example.com").Status | Should -Be "added"
    }

    # A user removed from Entra: the API returns 200 but isSuccess=false. That is who stays unassigned.
    It "reports 'failed' on a 200-with-error body" {
      Mock InvokeAdoRequest { [pscustomobject]@{ operationResult = [pscustomobject]@{ isSuccess = $false; errors = @([pscustomobject]@{ value = "The user could not be found in the directory." }) } } }
      $r = EntitleStakeholder "departed@example.com"
      $r.Status | Should -Be "failed"
      $r.Detail | Should -BeLike "*could not be found*"
    }

    It "treats an already-entitled member as 'exists', so a rerun is safe" {
      Mock InvokeAdoRequest { [pscustomobject]@{ operationResult = [pscustomobject]@{ isSuccess = $false; errors = @([pscustomobject]@{ value = "The user already has an entitlement." }) } } }
      (EntitleStakeholder "member@example.com").Status | Should -Be "exists"
    }

    It "reports 'failed' when the call itself throws, e.g. a 401 from an under-scoped PAT" {
      Mock InvokeAdoRequest { throw "401 Unauthorized" }
      (EntitleStakeholder "x@example.com").Status | Should -Be "failed"
    }

    It "requests a free Stakeholder entitlement by principalName, never a billable Basic seat" {
      $script:sentBody = $null
      Mock InvokeAdoRequest { $script:sentBody = $Body; [pscustomobject]@{ operationResult = [pscustomobject]@{ isSuccess = $true } } }
      EntitleStakeholder "alex@example.com" | Out-Null

      $script:sentBody.accessLevel.accountLicenseType | Should -Be "stakeholder"
      $script:sentBody.user.principalName | Should -Be "alex@example.com"
    }
  }

  Context "GetDistinctOwners" {

    It "dedups an owner across items by email, counts them, and skips an email-less owner" {
      # One page of two assets, then an empty page to stop. Sara appears twice; Vendor has no email.
      $script:page = 0
      Mock InvokeAgilityGet {
        $script:page++
        if ($script:page -eq 1)
        {
          return [pscustomobject]@{ Assets = @(
            [pscustomobject]@{ Attributes = [pscustomobject]@{
              'Owners.Name'  = [pscustomobject]@{ value = @("Alex Rivera", "Vendor") }
              'Owners.Email' = [pscustomobject]@{ value = @("alex@example.com", $null) } } },
            [pscustomobject]@{ Attributes = [pscustomobject]@{
              'Owners.Name'  = [pscustomobject]@{ value = "Alex Rivera" }
              'Owners.Email' = [pscustomobject]@{ value = "alex@example.com" } } }
          ) }
        }
        return [pscustomobject]@{ Assets = @() }
      }

      $owners = GetDistinctOwners @('Story')

      @($owners).Count | Should -Be 1 -Because "Sara is one person and Vendor has no email to add by"
      $owners[0].Email | Should -Be "alex@example.com"
      $owners[0].Count | Should -Be 2
    }
  }

  # The org-add token is deliberately separate from the migration's work-item PAT. When none is
  # configured it must fall back rather than break, so a user who only wants -DryRun is not blocked.
  It "falls back to the work-item credential target when no admin target is configured" {
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ CredentialTarget = "ado-workitem-pat" } }
    Mock GetSecret { "the-pat" } -ParameterFilter { $credentialTarget -eq "ado-workitem-pat" }

    BuildAdoAdminHeaders | Should -Not -BeNullOrEmpty
    Should -Invoke GetSecret -Times 1 -ParameterFilter { $credentialTarget -eq "ado-workitem-pat" }
  }
}

##################################################################################################
# The delete helpers: one per ADO work item type, over a shared core.
#
# What must never regress is what the type filter is FOR. These destroy permanently, so a query that
# lost its type clause would take the whole project with it - the same class of hazard as the
# AssetState filter on the Agility side, where dropping it would have migrated 18 templates.
##################################################################################################
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
}
