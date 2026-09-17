##################################################################################################
# Tests for the dependency direction repair.
#
# The migration wrote every Successor/Predecessor link backwards until 2026-09-16, and a link cannot
# be flipped one item at a time because ADO checks the whole graph for cycles on every add. So the
# repair is two passes over a whole project - remove every dependency link, then add every one back
# the other way round - and the tests here are about the ways that can go wrong: a link missed by
# the inventory, a patch landing on an item someone else changed, pass 2 starting while pass 1 left
# links behind, a cyclic pair poisoning a whole batch, a rerun re-adding what is already there, and
# a verification that trusts a counter instead of comparing the graph link by link.
#
# Every test is hermetic. Nothing here resolves a credential, queries the live org, or writes a log
# or inventory file outside a temp directory.
##################################################################################################

BeforeAll {
  $script:scriptPath  = Join-Path $PSScriptRoot ".." "src" "Repair-DependencyDirection.ps1"
  $script:migratePath = Join-Path $PSScriptRoot ".." "src" "Migrate-Agility.ps1"
  $script:removePath  = Join-Path $PSScriptRoot ".." "src" "Remove-WorkItems.ps1"

  $global:RepairDependencyDirectionLoadFunctionsOnly = $true
  . $script:scriptPath

  function CodeLines([string]$path) { return @(Get-Content $path | Where-Object { $_ -notmatch '^\s*#' }) }

  $script:FWD = 'System.LinkTypes.Dependency-Forward'
  $script:REV = 'System.LinkTypes.Dependency-Reverse'

  function Rel([string]$rel, [int]$to) { return [pscustomobject]@{ rel = $rel; url = "https://dev.azure.com/contoso/_apis/wit/workItems/$to"; attributes = [pscustomobject]@{ comment = "x" } } }
  function Edge([int]$from, [int]$to) { return [pscustomobject]@{ From = $from; To = $to } }
}

Describe "Inventory: every dependency link, read once, from the link query" {

  # A link query returns one row per SOURCE item with no rel, then one row per link. The rows with
  # no rel are not links and must not be counted; on Training that was 7,051 rows for 4,371 links.
  It "keeps only rows that carry a rel, as From -> To integers" {
    $rows = @(
      [pscustomobject]@{ rel = $null; source = $null; target = [pscustomobject]@{ id = 10 } },
      [pscustomobject]@{ rel = $script:FWD; source = [pscustomobject]@{ id = 10 }; target = [pscustomobject]@{ id = 20 } },
      [pscustomobject]@{ rel = $script:FWD; source = [pscustomobject]@{ id = 10 }; target = [pscustomobject]@{ id = 30 } },
      $null
    )

    $edges = @(ParseLinkRows $rows)

    $edges.Count | Should -Be 2
    $edges[0].From | Should -Be 10
    $edges[0].To   | Should -Be 20
    $edges[0].From | Should -BeOfType [int]
  }

  It "drops a duplicate row rather than counting a link twice" {
    $rows = @(
      [pscustomobject]@{ rel = $script:FWD; source = [pscustomobject]@{ id = 1 }; target = [pscustomobject]@{ id = 2 } },
      [pscustomobject]@{ rel = $script:FWD; source = [pscustomobject]@{ id = 1 }; target = [pscustomobject]@{ id = 2 } })

    @(ParseLinkRows $rows).Count | Should -Be 1
  }

  # ADO stores each link once and shows it from both ends. Reading the Successor side and the
  # Predecessor side must give the SAME count; if they differ the store is inconsistent and nothing
  # should be touched.
  It "refuses an inventory whose two ends disagree" {
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/contoso" } }
    Mock InvokeAdoRequest {
      $n = if ($body.query -match 'Dependency-Forward') { 3 } else { 2 }
      return [pscustomobject]@{ workItemRelations = @(1..$n | ForEach-Object { [pscustomobject]@{ rel = $script:FWD; source = [pscustomobject]@{ id = $_ }; target = [pscustomobject]@{ id = $_ + 100 } } }) }
    }

    { ReadLinkInventory 'Training' } | Should -Throw -ExpectedMessage "*3*2*"
  }

  It "accepts an inventory whose two ends agree, and returns the Successor side" {
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/contoso" } }
    Mock InvokeAdoRequest {
      return [pscustomobject]@{ workItemRelations = @(1..3 | ForEach-Object { [pscustomobject]@{ rel = $script:FWD; source = [pscustomobject]@{ id = $_ }; target = [pscustomobject]@{ id = $_ + 100 } } }) }
    }

    $edges = @(ReadLinkInventory 'Training')

    $edges.Count | Should -Be 3
    $edges[2].From | Should -Be 3
    $edges[2].To   | Should -Be 103
  }

  It "scopes the link query to the project at BOTH ends and to the Successor link type" {
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/contoso" } }
    $script:queries = @()
    Mock InvokeAdoRequest { $script:queries += $body.query; return [pscustomobject]@{ workItemRelations = @() } }

    ReadLinkInventory 'Training' | Out-Null

    $script:queries[0] | Should -Match "\[Source\]\.\[System\.TeamProject\] = 'Training'"
    $script:queries[0] | Should -Match "\[Target\]\.\[System\.TeamProject\] = 'Training'"
    $script:queries[0] | Should -Match 'Dependency-Forward'
    $script:queries[0] | Should -Match 'MODE \(MustContain\)'
  }

  It "round trips the inventory through a file, so a killed run can resume from what it saw" {
    $path = Join-Path ([IO.Path]::GetTempPath()) "dep-inventory-test-$([guid]::NewGuid()).json"
    try
    {
      SaveInventory @((Edge 1 2), (Edge 3 4)) $path
      $back = @(LoadInventory $path)

      $back.Count | Should -Be 2
      $back[1].From | Should -Be 3
      $back[1].To   | Should -Be 4
      $back[1].From | Should -BeOfType [int]
    }
    finally { Remove-Item $path -ErrorAction SilentlyContinue }
  }
}

Describe "Pass 1: remove every dependency link, guarded by the item's revision" {

  BeforeAll {
    $script:item = [pscustomobject]@{
      id = 7; rev = 15
      relations = @((Rel 'System.LinkTypes.Hierarchy-Reverse' 1), (Rel $script:FWD 20), (Rel 'System.LinkTypes.Related' 3), (Rel $script:REV 40), (Rel $script:FWD 50))
    }
  }

  # The rev test op makes the patch fail if anyone changed the item between our read and our
  # write, instead of removing relations by an index that no longer means what we think it means.
  It "tests the revision first, then removes dependency relations highest index first" {
    $ops = @(BuildRemoveOps $script:item)

    $ops[0].op    | Should -Be 'test'
    $ops[0].path  | Should -Be '/rev'
    $ops[0].value | Should -Be 15
    @($ops | Where-Object { $_.op -eq 'remove' } | ForEach-Object { $_.path }) | Should -Be @('/relations/4', '/relations/3', '/relations/1')
  }

  It "leaves every other relation alone" {
    $ops = @(BuildRemoveOps $script:item)

    @($ops | Where-Object { $_.op -eq 'remove' }).Count | Should -Be 3
    $ops.path | Should -Not -Contain '/relations/0'
    $ops.path | Should -Not -Contain '/relations/2'
  }

  It "returns nothing for an item with no dependency relations, so it is not patched at all" {
    $none = [pscustomobject]@{ id = 8; rev = 2; relations = @((Rel 'System.LinkTypes.Related' 3)) }

    @(BuildRemoveOps $none).Count | Should -Be 0
  }

  It "survives an item whose relations property is absent or a single null" {
    @(BuildRemoveOps ([pscustomobject]@{ id = 9; rev = 1 })).Count | Should -Be 0
    @(BuildRemoveOps ([pscustomobject]@{ id = 9; rev = 1; relations = $null })).Count | Should -Be 0
  }

  # THE defect of the first live run (Training, 2026-09-16, 1,130 items failed, 326 patches removed
  # the wrong relation). Removing a link from item A also removes its mirror from item B, so B's
  # relation INDEXES from a read taken before A was patched are stale - and B's revision does NOT
  # move when its mirror goes, so the revision test cannot catch it. The only safe index is one from
  # a read taken immediately before the patch, on the same item.
  Context "RemoveDependencyLinks reads fresh and checks what it removed" {

    BeforeEach {
      $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/contoso"; Project = "Training" } }
      Mock WriteLog { }
      Mock WriteLogDetail { }
      Mock WriteErrorDetail { }
    }

    It "builds the remove ops from a single-item read made right before the patch, never from an earlier snapshot" {
      $script:calls = @()
      Mock InvokeAdoRequest {
        $script:calls += @{ method = $method; url = $url; body = $body }
        if ($method -eq 'Get')
        {
          # Fresh state: the mirror at old index 1 is already gone, so the only dependency relation is now index 2.
          return [pscustomobject]@{ id = 7; rev = 15; relations = @((Rel 'System.LinkTypes.Hierarchy-Reverse' 1), (Rel 'System.LinkTypes.Related' 3), (Rel $script:FWD 50)) }
        }
        return [pscustomobject]@{ id = 7; rev = 16; relations = @((Rel 'System.LinkTypes.Hierarchy-Reverse' 1), (Rel 'System.LinkTypes.Related' 3)) }
      }

      $r = RemoveDependencyLinks 'Training' 7

      $script:calls[0].method | Should -Be 'Get'
      $script:calls[0].url | Should -Match '/workitems/7\?'
      $patch = $script:calls[1]
      $patch.method | Should -Be 'Patch'
      @($patch.body | Where-Object { $_.op -eq 'remove' } | ForEach-Object { $_.path }) | Should -Be @('/relations/2')
      @($patch.body | Where-Object { $_.op -eq 'test' })[0].value | Should -Be 15
      $r.Ok | Should -BeTrue
      $r.Removed | Should -Be 1
    }

    It "reports a patch whose response lost a relation that was NOT a dependency link, as a failure" {
      Mock InvokeAdoRequest {
        if ($method -eq 'Get') { return [pscustomobject]@{ id = 7; rev = 15; relations = @((Rel 'System.LinkTypes.Hierarchy-Reverse' 1), (Rel $script:FWD 50)) } }
        # The parent link is gone and the dependency link is still there: the wrong index was removed.
        return [pscustomobject]@{ id = 7; rev = 16; relations = @((Rel $script:FWD 50)) }
      }

      $r = RemoveDependencyLinks 'Training' 7

      $r.Ok | Should -BeFalse
      $r.Message | Should -Match 'Hierarchy-Reverse'
    }

    It "reports a patch that left a dependency relation behind" {
      Mock InvokeAdoRequest {
        if ($method -eq 'Get') { return [pscustomobject]@{ id = 7; rev = 15; relations = @((Rel $script:FWD 50), (Rel $script:REV 60)) } }
        return [pscustomobject]@{ id = 7; rev = 16; relations = @((Rel $script:REV 60)) }
      }

      $r = RemoveDependencyLinks 'Training' 7

      $r.Ok | Should -BeFalse
      $r.Message | Should -Match 'still has 1'
    }

    It "does nothing, and reports Ok, for an item that has no dependency relation any more" {
      Mock InvokeAdoRequest {
        if ($method -eq 'Get') { return [pscustomobject]@{ id = 7; rev = 15; relations = @((Rel 'System.LinkTypes.Related' 3)) } }
        throw "must not patch"
      }

      $r = RemoveDependencyLinks 'Training' 7

      $r.Ok | Should -BeTrue
      $r.Removed | Should -Be 0
      Should -Invoke InvokeAdoRequest -ParameterFilter { $method -eq 'Patch' } -Times 0 -Exactly
    }

    It "is what pass 1 calls, item by item, instead of patching from the pre-run snapshot" {
      $source = Get-Content $script:scriptPath -Raw
      $body = [regex]::Match($source, "function RepairDependencyDirection\b[\s\S]*?(?=\r?\nfunction )").Value

      $body | Should -Match 'RemoveDependencyLinks \$Project \$id'
      $body | Should -Not -Match 'BuildRemoveOps \$item' -Because "pass 1 must not build removes from the earlier snapshot"
    }
  }

  # The keys of everything that is NOT a dependency link, so the verification can prove those did
  # not change. Compared as a set, because the removes shift indexes.
  It "fingerprints the non-dependency relations so they can be compared after the repair" {
    $keys = @(NonDependencyRelationKeys $script:item.relations)

    $keys.Count | Should -Be 2
    $keys | Should -Contain 'System.LinkTypes.Hierarchy-Reverse|https://dev.azure.com/contoso/_apis/wit/workItems/1'
    $keys | Should -Contain 'System.LinkTypes.Related|https://dev.azure.com/contoso/_apis/wit/workItems/3'
  }
}

Describe "Pass 2: add every link back the other way round" {

  # Old: A has Successor B, meaning ADO thinks A comes before B. Agility meant the opposite: A
  # depends on B, so B comes first. Written back from A's side as a PREDECESSOR link to B, which is
  # the same link ADO shows on B as a Successor to A. One write per link, from the old source end.
  It "writes each old Successor link as a Predecessor from the same item to the same target" {
    $ops = @(BuildAddOps 7 15 @(20, 50) 'S-7')

    $ops[0].op | Should -Be 'test'
    $ops[0].path | Should -Be '/rev'
    $adds = @($ops | Where-Object { $_.op -eq 'add' })
    $adds.Count | Should -Be 2
    $adds[0].path | Should -Be '/relations/-'
    $adds[0].value.rel | Should -Be $script:REV
    $adds[0].value.url | Should -Match '/workItems/20$'
    $adds[1].value.url | Should -Match '/workItems/50$'
  }

  # The migration's own comment wording, which was itself the wrong way round before the fix: a
  # Predecessor link means "this item depends on that one".
  It "labels the link as a dependency of the item it is written from" {
    $ops = @(BuildAddOps 7 15 @(20) 'S-7')

    @($ops | Where-Object { $_.op -eq 'add' })[0].value.attributes.comment | Should -Be 'Agility dependency of S-7.'
  }

  It "groups the inventory by the item each link is written from" {
    $groups = GroupEdgesByWriter @((Edge 1 2), (Edge 1 3), (Edge 4 2))

    $groups.Keys.Count | Should -Be 2
    @($groups[1]) | Should -Be @(2, 3)
    @($groups[4]) | Should -Be @(2)
  }

  It "recognises ADO's circular link rejection, which comes back as an HTTP 500" {
    $rec = [pscustomobject]@{ ErrorDetails = [pscustomobject]@{ Message = '{"message":"TF201035: Adding a Successor link between work items 1 and 2 would result in a circular relationship."}' }; Exception = [pscustomobject]@{ Message = '500' } }

    IsCircularLinkProblem $rec | Should -BeTrue
    IsCircularLinkProblem ([pscustomobject]@{ ErrorDetails = [pscustomobject]@{ Message = 'TF401320: Rule Error' }; Exception = [pscustomobject]@{ Message = '400' } }) | Should -BeFalse
  }

  Context "AddFlippedLinks" {

    BeforeEach {
      $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/contoso"; Project = "Training" } }
      Mock WriteLog { }
      Mock WriteLogDetail { }
      Mock WriteErrorDetail { }
    }

    It "writes all of an item's links in ONE patch when nothing is cyclic" {
      Mock InvokeAdoRequest { return [pscustomobject]@{ rev = 16 } }

      $r = AddFlippedLinks 7 15 @(20, 50) 'S-7'

      Should -Invoke InvokeAdoRequest -Times 1 -Exactly
      @($r.Refused).Count | Should -Be 0
      $r.Written | Should -Be 2
    }

    # One cyclic link must cost only itself. The batch is refused as a whole, so each link is then
    # tried alone: the good ones land, the cyclic one is recorded.
    It "falls back to one link at a time when the batch is refused as circular, and keeps the rest" {
      $script:calls = 0
      Mock InvokeAdoRequest {
        $script:calls++
        $adds = @($body | Where-Object { $_.op -eq 'add' })
        $cyclic = @($adds | Where-Object { $_.value.url -match '/workItems/50$' })
        if ($cyclic.Count -gt 0)
        {
          $err = [System.Management.Automation.ErrorRecord]::new([Exception]::new("500"), "x", 'InvalidOperation', $null)
          $err.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"message":"TF201035: would result in a circular relationship."}')
          throw $err
        }
        return [pscustomobject]@{ rev = 16 }
      }

      $r = AddFlippedLinks 7 15 @(20, 50, 60) 'S-7'

      # 1 batch attempt + 3 individual = 4
      $script:calls | Should -Be 4
      @($r.Refused) | Should -Be @(50)
      $r.Written | Should -Be 2
    }

    # A refused REVISION test is not a cycle and not transient: someone changed the item. That is a
    # failure to report, never something to retry link by link.
    It "reports a non-cyclic rejection as a failure without retrying" {
      Mock InvokeAdoRequest {
        $err = [System.Management.Automation.ErrorRecord]::new([Exception]::new("409"), "x", 'InvalidOperation', $null)
        $err.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"message":"VS403351: Test Operation for path /rev failed"}')
        throw $err
      }

      $r = AddFlippedLinks 7 15 @(20, 50) 'S-7'

      Should -Invoke InvokeAdoRequest -Times 1 -Exactly
      $r.Failed | Should -BeTrue
      $r.Written | Should -Be 0
    }
  }

  # A rerun after a crash must add only what is not there yet, or every link would be doubled.
  It "on a rerun, writes only the expected links that are not already present" {
    $expected = @((Edge 1 2), (Edge 1 3), (Edge 4 2))
    $present  = @((Edge 1 2))

    $todo = @(EdgesToWrite $expected $present)

    $todo.Count | Should -Be 2
    ($todo | ForEach-Object { "$($_.From)>$($_.To)" }) | Should -Be @('1>3', '4>2')
  }
}

Describe "Verification: the new graph is exactly the old one reversed" {

  # Old edge A->B (A has Successor B) must now exist as B->A (B has Successor A), which the link
  # query reports from the Successor side as From=B, To=A.
  It "passes when every old link exists reversed and nothing else does" {
    $old = @((Edge 1 2), (Edge 3 4))
    $new = @((Edge 2 1), (Edge 4 3))

    $v = VerifyFlip $old $new @()

    $v.Missing.Count   | Should -Be 0
    $v.Extra.Count     | Should -Be 0
    $v.Unflipped.Count | Should -Be 0
    $v.Ok | Should -BeTrue
  }

  It "reports a link that is still the old way round as unflipped, not as missing plus extra" {
    $v = VerifyFlip @((Edge 1 2), (Edge 3 4)) @((Edge 2 1), (Edge 3 4)) @()

    $v.Unflipped | Should -Be @('3>4')
    $v.Missing.Count | Should -Be 0
    $v.Extra.Count   | Should -Be 0
    $v.Ok | Should -BeFalse
  }

  It "reports a link that vanished as missing and a link that appeared as extra" {
    $v = VerifyFlip @((Edge 1 2), (Edge 3 4)) @((Edge 2 1), (Edge 9 8)) @()

    $v.Missing | Should -Be @('4>3')
    $v.Extra   | Should -Be @('9>8')
    $v.Ok | Should -BeFalse
  }

  # A pair ADO refused as circular is expected to be absent; it is not a defect of the repair.
  It "does not count a link ADO refused as circular as missing" {
    $v = VerifyFlip @((Edge 1 2), (Edge 3 4)) @((Edge 2 1)) @((Edge 3 4))

    $v.Missing.Count | Should -Be 0
    $v.Ok | Should -BeTrue
    $v.Refused | Should -Be @('3>4')
  }

  It "compares the non-dependency relations of a touched item as a set and flags any change" {
    $before = @{ 7 = @('a|u1', 'b|u2') }
    $after  = @{ 7 = @('b|u2', 'a|u1') }
    @(CompareOtherRelations $before $after).Count | Should -Be 0

    $after2 = @{ 7 = @('a|u1') }
    @(CompareOtherRelations $before $after2) | Should -Be @('#7 non-dependency relations changed: before 2, after 1')
  }
}

Describe "The run as a whole" {

  BeforeAll {
    $script:testConfig = [pscustomobject]@{
      AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/contoso"; Project = "IT"; CredentialTarget = "x" }
    }
    # Two links: 1->2 and 3->2. Items 1 and 3 hold the Successor end.
    function LinkRows($edges) { return [pscustomobject]@{ workItemRelations = @($edges | ForEach-Object { [pscustomobject]@{ rel = $script:FWD; source = [pscustomobject]@{ id = $_.From }; target = [pscustomobject]@{ id = $_.To } } }) } }
    function Item([int]$id, [int]$rev, $rels) { return [pscustomobject]@{ id = $id; rev = $rev; fields = [pscustomobject]@{ 'Custom.DigitalAIID' = "S-$id" }; relations = @($rels) } }
    # A single-item read (the fresh read before a patch) answered from the same item list.
    function OneOf($items, [string]$url) { $id = [int]([regex]::Match($url, '/workitems/(\d+)\?').Groups[1].Value); return @($items | Where-Object { $_.id -eq $id })[0] }
  }

  BeforeEach {
    Mock GetConfig       { return $script:testConfig }
    Mock BuildAdoHeaders { return @{ Authorization = "Basic test" } }
    Mock StartLog        { }
    Mock WriteLog        { }
    Mock WriteLogDetail  { }
    Mock WriteErrorDetail { }
    Mock SaveInventory   { }
    Mock SaveRelationSnapshot { }
    $script:totalFailed = 0
    $script:phase = 'before'
  }

  It "on a dry run reads everything and patches nothing" {
    Mock InvokeAdoRequest {
      if ($method -eq 'Patch') { throw "dry run must not write" }
      if ($url -match 'wiql')  { return (LinkRows @((Edge 1 2), (Edge 3 2))) }
      $items = @((Item 1 5 @((Rel $script:FWD 2))), (Item 2 5 @((Rel $script:REV 1), (Rel $script:REV 3))), (Item 3 5 @((Rel $script:FWD 2))))
      if ($method -eq 'Get') { return (OneOf $items $url) }
      return [pscustomobject]@{ value = $items }
    }

    { RepairDependencyDirection -Project 'Training' -DryRun } | Should -Not -Throw
    Should -Invoke InvokeAdoRequest -ParameterFilter { $method -eq 'Patch' } -Times 0 -Exactly
    $script:totalFailed | Should -Be 0
  }

  # The stop rule. If pass 1 left anything behind, pass 2 would add flipped links beside old ones
  # and ADO would refuse them as cycles (or worse, accept a contradictory pair).
  It "does not start pass 2 when links remain after pass 1" {
    $script:patches = @()
    Mock InvokeAdoRequest {
      if ($method -eq 'Patch') { $script:patches += $url; return [pscustomobject]@{ rev = 6; relations = @() } }
      if ($url -match 'wiql')  { return (LinkRows @((Edge 1 2))) }   # never reaches zero
      $items = @((Item 1 5 @((Rel $script:FWD 2))), (Item 2 5 @((Rel $script:REV 1))))
      if ($method -eq 'Get') { return (OneOf $items $url) }
      return [pscustomobject]@{ value = $items }
    }

    RepairDependencyDirection -Project 'Training'

    # Pass 1 patched items 1 and 2 (both hold an end of the link); pass 2 never ran, so no third patch.
    @($script:patches | Where-Object { $_ -match '/workitems/1\?' }).Count | Should -Be 1
    @($script:patches | Where-Object { $_ -match '/workitems/2\?' }).Count | Should -Be 1
    $script:patches.Count | Should -Be 2
    $script:totalFailed | Should -BeGreaterThan 0
  }

  It "removes, re-checks, adds flipped, and verifies, ending with zero failures on a clean graph" {
    $script:patches = @()
    Mock InvokeAdoRequest {
      if ($method -eq 'Patch')
      {
        $script:patches += @{ url = $url; ops = $body }
        # Item 1 keeps its parent link; everything else has nothing but dependency links.
        $keep = if ($url -match '/workitems/1\?') { @((Rel 'System.LinkTypes.Hierarchy-Reverse' 9)) } else { @() }
        return [pscustomobject]@{ rev = 6; relations = $keep }
      }
      if ($url -match 'wiql')
      {
        # Before pass 1: the two old links. After pass 1: none. After pass 2: the two flipped.
        switch ($script:phase)
        {
          'before'  { return (LinkRows @((Edge 1 2), (Edge 3 2))) }
          'removed' { return (LinkRows @()) }
          'added'   { return (LinkRows @((Edge 2 1), (Edge 2 3))) }
        }
      }
      # Item reads: before and after the repair the non-dependency relations are the same.
      $items = @(
        (Item 1 5 @((Rel 'System.LinkTypes.Hierarchy-Reverse' 9), (Rel $script:FWD 2))),
        (Item 2 5 @((Rel $script:REV 1), (Rel $script:REV 3))),
        (Item 3 5 @((Rel $script:FWD 2))))
      if ($method -eq 'Get') { return (OneOf $items $url) }
      return [pscustomobject]@{ value = $items }
    }
    Mock AfterPass { param($name) $script:phase = $name }

    RepairDependencyDirection -Project 'Training'

    $script:totalFailed | Should -Be 0
    # Pass 1: 3 removes (items 1, 2, 3 all hold a dependency relation). Pass 2: 2 adds (items 1 and 3, the old Successor ends).
    $removes = @($script:patches | Where-Object { @($_.ops | Where-Object { $_.op -eq 'remove' }).Count -gt 0 })
    $adds    = @($script:patches | Where-Object { @($_.ops | Where-Object { $_.op -eq 'add' }).Count -gt 0 })
    $removes.Count | Should -Be 3
    $adds.Count    | Should -Be 2
    foreach ($p in $script:patches) { @($p.ops | Where-Object { $_.op -eq 'test' -and $_.path -eq '/rev' }).Count | Should -Be 1 }
    @($adds | ForEach-Object { $_.ops } | Where-Object { $_.op -eq 'add' } | ForEach-Object { $_.value.rel } | Select-Object -Unique) | Should -Be @($script:REV)
  }

  # A resume after a stopped run: some items already have no links (pass 1 reached them), some still
  # hold the old link. Only the latter are patched in pass 1, and pass 2 writes only what is absent.
  It "on a resume, patches only the items still holding an old link and writes only the absent flipped links" {
    $inventory = Join-Path ([IO.Path]::GetTempPath()) "dep-resume-test-$([guid]::NewGuid()).json"
    # Written directly: SaveInventory is mocked in this Describe.
    Set-Content -Path $inventory -Value '[{"From":1,"To":2},{"From":3,"To":4}]'
    try
    {
      $script:patches = @()
      Mock InvokeAdoRequest {
        if ($method -eq 'Patch')
        {
          $script:patches += @{ url = $url; ops = $body }
          return [pscustomobject]@{ rev = 6; relations = @() }
        }
        if ($url -match 'wiql')
        {
          # Link 1->2 was already removed by the stopped run; 3->4 is still there. After pass 1 nothing;
          # after pass 2 both flipped.
          switch ($script:phase)
          {
            'before'  { return (LinkRows @((Edge 3 4))) }
            'removed' { return (LinkRows @()) }
            'added'   { return (LinkRows @((Edge 2 1), (Edge 4 3))) }
          }
        }
        $items = @((Item 1 5 @()), (Item 2 5 @()), (Item 3 5 @((Rel $script:FWD 4))), (Item 4 5 @((Rel $script:REV 3))))
        if ($method -eq 'Get') { return (OneOf $items $url) }
        return [pscustomobject]@{ value = $items }
      }
      Mock AfterPass { param($name) $script:phase = $name }

      RepairDependencyDirection -Project 'Training' -Resume $inventory

      $script:totalFailed | Should -Be 0
      $removes = @($script:patches | Where-Object { @($_.ops | Where-Object { $_.op -eq 'remove' }).Count -gt 0 })
      $adds    = @($script:patches | Where-Object { @($_.ops | Where-Object { $_.op -eq 'add' }).Count -gt 0 })
      @($removes | ForEach-Object { $_.url }) | Should -Not -Match '/workitems/[12]\?' -Because "items 1 and 2 had nothing left to remove"
      $removes.Count | Should -Be 2
      $adds.Count    | Should -Be 2 -Because "both links are absent after pass 1 and must be written flipped"
    }
    finally { Remove-Item $inventory -ErrorAction SilentlyContinue }
  }

  # Blast radius. The first live run kept going through 3,860 items after the first wrong removal.
  # Now the first patch that takes anything but a dependency link stops pass 1 on the spot.
  It "stops pass 1 at the first patch that removed a non-dependency relation, and never starts pass 2" {
    $script:patches = @()
    Mock InvokeAdoRequest {
      if ($method -eq 'Patch')
      {
        $script:patches += $url
        # The very first patch comes back having lost the parent link.
        return [pscustomobject]@{ rev = 6; relations = @() }
      }
      if ($url -match 'wiql') { return (LinkRows @((Edge 1 2), (Edge 3 4))) }
      $items = @((Item 1 5 @((Rel 'System.LinkTypes.Hierarchy-Reverse' 9), (Rel $script:FWD 2))), (Item 2 5 @((Rel $script:REV 1))), (Item 3 5 @((Rel $script:FWD 4))), (Item 4 5 @((Rel $script:REV 3))))
      if ($method -eq 'Get') { return (OneOf $items $url) }
      return [pscustomobject]@{ value = $items }
    }

    RepairDependencyDirection -Project 'Training'

    $script:patches.Count | Should -Be 1 -Because "the run must halt after the first wrong removal"
    $script:totalFailed | Should -BeGreaterThan 0
  }

  # The on-disk record that makes any mistake recoverable without the revision history: every
  # touched item's complete relation list, written BEFORE the first patch.
  It "writes a full relation snapshot of every touched item before the first write, and not on a dry run" {
    $script:snapshots = @()
    Mock SaveRelationSnapshot { $script:snapshots += @{ path = $path; count = @($items.Keys).Count } }
    $script:order = @()
    Mock InvokeAdoRequest {
      if ($method -eq 'Patch') { $script:order += 'patch'; return [pscustomobject]@{ rev = 6; relations = @() } }
      if ($url -match 'wiql')
      {
        switch ($script:phase) { 'before' { return (LinkRows @((Edge 1 2))) } 'removed' { return (LinkRows @()) } 'added' { return (LinkRows @((Edge 2 1))) } }
      }
      $items = @((Item 1 5 @((Rel $script:FWD 2))), (Item 2 5 @((Rel $script:REV 1))))
      if ($method -eq 'Get') { return (OneOf $items $url) }
      return [pscustomobject]@{ value = $items }
    }
    Mock AfterPass { param($name) $script:phase = $name }

    RepairDependencyDirection -Project 'Training' -DryRun
    $script:snapshots.Count | Should -Be 0 -Because "a dry run writes nothing, not even a snapshot"

    $script:phase = 'before'
    RepairDependencyDirection -Project 'Training'
    $script:snapshots.Count | Should -Be 1
    $script:snapshots[0].count | Should -Be 2 -Because "both ends of the link are touched items"
    $script:snapshots[0].path | Should -Match 'RelationSnapshot-Training-'
  }

  It "round trips a relation snapshot through a file with every relation intact" {
    $path = Join-Path ([IO.Path]::GetTempPath()) "rel-snapshot-test-$([guid]::NewGuid()).json"
    try
    {
      $items = @{ 7 = (Item 7 3 @((Rel 'System.LinkTypes.Hierarchy-Reverse' 1), (Rel $script:FWD 2))); 8 = (Item 8 4 @()) }
      & (Get-Command SaveRelationSnapshot -CommandType Function) $items $path
      $back = Get-Content $path -Raw | ConvertFrom-Json

      @($back).Count | Should -Be 2
      $seven = @($back | Where-Object { $_.Id -eq 7 })[0]
      $seven.Rev | Should -Be 3
      @($seven.Relations).Count | Should -Be 2
      @($seven.Relations)[0].rel | Should -Be 'System.LinkTypes.Hierarchy-Reverse'
      @($seven.Relations)[0].url | Should -Match '/workItems/1$'
    }
    finally { Remove-Item $path -ErrorAction SilentlyContinue }
  }

  # Pass 2 follows the same rule as pass 1: the revision in the test op comes from a read of that
  # item made right before its own patch, never from a batch read made earlier.
  It "builds each pass 2 patch from a single-item read made right before it" {
    $script:calls = @()
    Mock InvokeAdoRequest {
      $script:calls += @{ method = $method; url = $url; body = $body }
      if ($method -eq 'Patch') { return [pscustomobject]@{ rev = 8; relations = @() } }
      if ($url -match 'wiql')
      {
        switch ($script:phase) { 'before' { return (LinkRows @((Edge 1 2))) } 'removed' { return (LinkRows @()) } 'added' { return (LinkRows @((Edge 2 1))) } }
      }
      $items = @((Item 1 5 @((Rel $script:FWD 2))), (Item 2 5 @((Rel $script:REV 1))))
      if ($method -eq 'Get')
      {
        # The single read reports a NEWER revision than the batch read did.
        $one = OneOf $items $url
        return [pscustomobject]@{ id = $one.id; rev = 7; fields = $one.fields; relations = $one.relations }
      }
      return [pscustomobject]@{ value = $items }
    }
    Mock AfterPass { param($name) $script:phase = $name }
    Mock SaveRelationSnapshot { }

    RepairDependencyDirection -Project 'Training'

    $adds = @($script:calls | Where-Object { $_.method -eq 'Patch' -and @($_.body | Where-Object { $_.op -eq 'add' }).Count -gt 0 })
    $adds.Count | Should -Be 1
    @($adds[0].body | Where-Object { $_.op -eq 'test' })[0].value | Should -Be 7 -Because "the rev must come from the fresh single read"
    # And that read happened right before the patch, on the same item.
    $idx = [array]::IndexOf($script:calls, $adds[0])
    $script:calls[$idx - 1].method | Should -Be 'Get'
    $script:calls[$idx - 1].url | Should -Match '/workitems/1\?'
  }

  It "totals failures rather than exiting, so the bottom of the script can turn them into an exit code" {
    $source = Get-Content $script:scriptPath -Raw
    $body = [regex]::Match($source, "function RepairDependencyDirection\b[\s\S]*?(?=\r?\nfunction )").Value

    $body | Should -Match '\$script:totalFailed \+='
    $body | Should -Not -Match '(?m)^\s*exit\b'
  }
}

Describe "Self contained, and it can only touch links" {

  It "loads no other script and is named by none" {
    $code = CodeLines $script:scriptPath
    @($code | Where-Object { $_ -match 'Migrate-Agility|Remove-WorkItems|Create-Iterations' }) | Should -BeNullOrEmpty
    @($code | Where-Object { $_ -match '^\s*\.\s+[''"$]' }) | Should -BeNullOrEmpty
    @((CodeLines $script:migratePath) | Where-Object { $_ -match 'Repair-DependencyDirection' }) | Should -BeNullOrEmpty
    @((CodeLines $script:removePath)  | Where-Object { $_ -match 'Repair-DependencyDirection' }) | Should -BeNullOrEmpty
  }

  # It removes RELATIONS. It never deletes a work item, and it has no door to Agility.
  It "never deletes a work item and never reaches Agility" {
    $source = Get-Content $script:scriptPath -Raw
    $code = CodeLines $script:scriptPath

    $source | Should -Not -Match 'destroy=true'
    @($code | Where-Object { $_ -match '(?i)-Method\s+["'']?Delete' -or $_ -match '(?i)InvokeAdoRequest\s+\S+\s+["'']Delete' }) | Should -BeNullOrEmpty
    $source | Should -Not -Match 'rest-1\.v1'
    $source | Should -Not -Match 'AGILITY_ACCESS_TOKEN'
    $source | Should -Not -Match 'InvokeAgility'
  }

  # The only field-shaped path it may patch is /relations. A /fields/ path here would mean it has
  # started editing work item data.
  It "patches only relations and the revision test, never a field" {
    $code = CodeLines $script:scriptPath

    @($code | Where-Object { $_ -match '/fields/' }) | Should -BeNullOrEmpty
  }

  It "writes its own log file name and guards its entry point with its own flag" {
    $source = Get-Content $script:scriptPath -Raw

    $source | Should -Match 'Repair-DependencyDirection-\{0\}'
    $source | Should -Match '\$global:RepairDependencyDirectionLoadFunctionsOnly'
    $source | Should -Not -Match 'AgilityEpicsLoadFunctionsOnly'
    $source | Should -Not -Match 'RemoveWorkItemsLoadFunctionsOnly'
    @((CodeLines $script:scriptPath) | Where-Object { $_ -match '\$MyInvocation\.InvocationName' }) | Should -BeNullOrEmpty
  }

  It "ships with a dry run as the live line in Main" {
    $source = Get-Content $script:scriptPath -Raw
    $main = [regex]::Match($source, "function Main\b[\s\S]*?(?=\r?\n#{10,})").Value
    $live = @(($main -split "`r?`n") | Where-Object { $_ -match '^\s*RepairDependencyDirection\b' })

    $live.Count | Should -Be 1
    $live[0] | Should -Match '-DryRun'
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
      if ($line -match '^if \(\$global:RepairDependencyDirectionLoadFunctionsOnly\)') { $inGuard = $true }
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

  # The circular link rejection is an HTTP 500 that is NOT transient. Retrying it three times per
  # cyclic link is what the migration used to do; this script must not.
  It "does not treat a circular link rejection as transient" {
    $err = [System.Management.Automation.ErrorRecord]::new([Exception]::new("500"), "x", 'InvalidOperation', $null)
    $err.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"message":"TF201035: would result in a circular relationship."}')
    IsTransientFailure $err | Should -BeFalse
  }

  It "gives up immediately on a permanent failure" {
    Mock IsTransientFailure { return $false }
    $script:attempts = 0
    { InvokeWithRetry { $script:attempts++; throw "bad request" } -attempts 3 -fixedDelay 0 } | Should -Throw
    $script:attempts | Should -Be 1
  }

  It "never sleeps longer than the cap" {
    $script:MaxRetryDelaySeconds | Should -Be 120
  }
}
