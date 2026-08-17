# Agility Discussions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate digital.ai Agility `Expression` assets into Azure DevOps work item comments, backdated to when they were written and attributed to who wrote them.

**Architecture:** One extra Agility read pass builds an oid-to-thread map before the type loop. Per item, the thread is split around the state transition so every comment keeps its true date, and each comment is written as a `bypassRules` `System.History` patch. All formatting and ordering logic lives in pure functions that are tested without the network.

**Tech Stack:** PowerShell 7, Pester 5, Agility `rest-1.v1`, Azure DevOps REST 7.1.

**Spec:** `docs/superpowers/specs/2026-08-11-agility-discussions-design.md`

## Global Constraints

- **Agility is read only.** Every Agility call goes through `InvokeAgilityGet`, which hard codes `-Method Get`. Do not add a method parameter. Do not call `Invoke-RestMethod` against Agility anywhere else.
- **Style:** Allman braces, 2 space indent, PascalCase function names without hyphens, typed inline params (`function Foo([int]$id, $epic)`), camelCase variables, `$script:` scope for shared state.
- **`WriteLog` for progress, never `Write-Host`.** A bare `WriteLog` prints a blank line.
- **No em-dashes or en-dashes anywhere**, including code comments. Use hyphens or rephrase.
- **No `param()` blocks and no CLI switches.** `Main` is the control panel.
- **Do not commit.** Richard handles all commits himself. Leave every change in the working tree and tell him what changed.
- Run the full suite with `Invoke-Pester -Path tests -Output Detailed`. It must stay at 0 failures; it was 491 passing before this work.
- Tests must be hermetic: no live credentials, no network, no files written to `logs/`.

---

### Task 1: HTML-safe comment bodies

The single most dangerous detail in the feature. 14,933 of the 15,228 bodies are plain text, and ADO renders a comment as HTML, so an unescaped `<` or `&` mangles or truncates the comment with no error anywhere.

**Files:**
- Modify: `src/Migrate-Agility.ps1` (new functions near `BuildMigrationNote`)
- Test: `tests/Migrate-Agility.Tests.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `EscapeHtmlText([string]$text)` returns string; `FormatCommentDate($value)` returns string; `BuildCommentBody($comment)` returns string. `$comment` is a PSCustomObject with `AuthorName`, `AuthorEmail`, `AuthoredAt`, `Content`, `InReplyToAuthor`, `InReplyToAt`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Migrate-Agility.Tests.ps1`:

```powershell
##################################################################################################
# Agility discussions become ADO comments. The escaping is the part that fails silently: Agility
# stores these as plain text (14,933 of 15,228 measured), ADO renders them as HTML, so an
# unescaped < or & is a mangled or truncated comment that no counter would ever report.
##################################################################################################
Describe "BuildCommentBody" {

  It "escapes HTML so plain text survives intact" {
    $c = [pscustomobject]@{
      AuthorName = "Sara Matson"; AuthoredAt = "2019-03-04T16:12:00"
      Content = "Use a < b & c > d in the filter"; InReplyToAuthor = $null; InReplyToAt = $null
    }

    $body = BuildCommentBody $c
    $body | Should -BeLike "*Use a &lt; b &amp; c &gt; d in the filter*"
  }

  It "escapes the ampersand first, so an escaped entity is not double escaped" {
    EscapeHtmlText "a < b" | Should -Be "a &lt; b"
    EscapeHtmlText "Tom & Jerry" | Should -Be "Tom &amp; Jerry"
    EscapeHtmlText "&lt;" | Should -Be "&amp;lt;"
  }

  It "converts newlines to breaks, or the comment arrives as one run-on paragraph" {
    EscapeHtmlText "one`r`ntwo`nthree" | Should -Be "one<br>two<br>three"
  }

  It "carries an attribution header with the Agility author and date" {
    $c = [pscustomobject]@{
      AuthorName = "Brittney Trimmer"; AuthoredAt = "2019-03-04T16:12:00"
      Content = "Input please."; InReplyToAuthor = $null; InReplyToAt = $null
    }

    BuildCommentBody $c | Should -BeLike "*<b>Brittney Trimmer</b> wrote in Agility on 4 March 2019:*"
  }

  It "adds a reply marker naming the parent author and date" {
    $c = [pscustomobject]@{
      AuthorName = "Shannon Grimsley"; AuthoredAt = "2019-03-05T14:40:00"
      Content = "Test the credit card case."
      InReplyToAuthor = "Brittney Trimmer"; InReplyToAt = "2019-03-04T16:12:00"
    }

    BuildCommentBody $c | Should -BeLike "*in reply to Brittney Trimmer (4 March 2019):*"
  }

  It "omits the reply marker on a topic starter" {
    $c = [pscustomobject]@{
      AuthorName = "Sara Matson"; AuthoredAt = "2019-03-04T16:12:00"
      Content = "Kicking this off."; InReplyToAuthor = $null; InReplyToAt = $null
    }

    BuildCommentBody $c | Should -Not -BeLike "*in reply to*"
  }

  It "escapes the author name too, since it also lands in HTML" {
    $c = [pscustomobject]@{
      AuthorName = "Ben & Co <IT>"; AuthoredAt = "2019-03-04T16:12:00"
      Content = "x"; InReplyToAuthor = $null; InReplyToAt = $null
    }

    BuildCommentBody $c | Should -BeLike "*Ben &amp; Co &lt;IT&gt;*"
  }

  It "still produces a body when the author is missing, because 3 expressions have none" {
    $c = [pscustomobject]@{
      AuthorName = $null; AuthoredAt = "2019-03-04T16:12:00"
      Content = "Orphaned comment."; InReplyToAuthor = $null; InReplyToAt = $null
    }

    BuildCommentBody $c | Should -BeLike "*Orphaned comment.*"
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Invoke-Pester -Path tests -Output Detailed -TagFilter @() 2>&1 | Select-String "BuildCommentBody" -Context 0,2`

Expected: FAIL, `The term 'BuildCommentBody' is not recognized`.

- [ ] **Step 3: Write the implementation**

Add to `src/Migrate-Agility.ps1`, immediately after `BuildMigrationNote`:

```powershell
##################################################################################################
# Agility discussions
#
# Agility keeps conversation in Expression assets: an author, a date, some text, and a Mentions
# link to whatever the thread is about. They become ADO comments, backdated and attributed.
#
# The bodies are PLAIN TEXT - 14,933 of 15,228 measured on 2026-08-11 - and an ADO comment is
# rendered as HTML. So the text must be escaped: a comment containing "a < b" would otherwise lose
# everything from the < onwards, silently, with a perfectly successful HTTP 200 behind it.
##################################################################################################

function EscapeHtmlText([string]$text)
{
  if (-not $text) { return "" }

  # Ampersand FIRST. Escaping it after the others would turn the & of "&lt;" into "&amp;lt;".
  $escaped = $text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')

  # Agility stores real newlines. HTML collapses them, so without this every comment arrives as a
  # single run-on paragraph. CRLF before LF, or a CRLF becomes two breaks.
  $escaped = $escaped -replace "`r`n", "<br>"
  $escaped = $escaped -replace "`n", "<br>"
  $escaped = $escaped -replace "`r", "<br>"

  return $escaped
}

# A human date for the body text, not the wire format. FormatDate is the wire one.
function FormatCommentDate($value)
{
  if (-not $value) { return "an unknown date" }

  try { return ([datetime]$value).ToString('d MMMM yyyy', [cultureinfo]::InvariantCulture) }
  catch { return "an unknown date" }
}

# The header is always present, by decision on 2026-08-11. ADO stores the real author in
# createdOnBehalfOf, but whether the Discussion tab renders it was never verified, and if it does
# not then this line is the only record of who wrote the comment.
function BuildCommentBody($comment)
{
  $author = if ($comment.AuthorName) { $comment.AuthorName } else { "An unknown author" }
  $header = "<b>$(EscapeHtmlText $author)</b> wrote in Agility on $(FormatCommentDate $comment.AuthoredAt)"

  # ADO comments are flat, so the InReplyTo relationship would be lost entirely without this line.
  if ($comment.InReplyToAuthor)
  {
    $header += ", in reply to $(EscapeHtmlText $comment.InReplyToAuthor) ($(FormatCommentDate $comment.InReplyToAt))"
  }

  # ${header} rather than $header: a colon straight after a variable name is read as a scope
  # qualifier and the string would come out empty.
  return "$($header):<br><br>$(EscapeHtmlText $comment.Content)"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: PASS, and the pre-existing tests still at 0 failures.

- [ ] **Step 5: Leave the change uncommitted**

Do not run `git commit`. Report the files touched.

---

### Task 2: Author, date and the comment patch

**Files:**
- Modify: `src/Migrate-Agility.ps1` (after `BuildCommentBody`)
- Test: `tests/Migrate-Agility.Tests.ps1`

**Interfaces:**
- Consumes: `BuildCommentBody($comment)` from Task 1; `FormatDate($value)` which already exists and returns `yyyy-MM-ddTHH:mm:ssZ`.
- Produces: `ResolveCommentAuthor($comment)` returns string or `$null`; `ResolveCommentDate($comment, $createDate)` returns a wire-format string or `$null`; `BuildCommentPatch($comment, $createDate)` returns an array of patch operation hashtables.

- [ ] **Step 1: Write the failing tests**

```powershell
Describe "BuildCommentPatch" {

  BeforeAll {
    $script:plainComment = [pscustomobject]@{
      AuthorName = "Sara Matson"; AuthorEmail = "sara.matson@cwi.edu"
      AuthoredAt = "2019-03-04T16:12:00"; Content = "Hello"
      InReplyToAuthor = $null; InReplyToAt = $null
    }
  }

  It "prefers the author email, because that is what ADO resolves an identity from" {
    ResolveCommentAuthor $script:plainComment | Should -Be "sara.matson@cwi.edu"
  }

  It "falls back to the display name when there is no email" {
    $c = [pscustomobject]@{ AuthorName = "Vendor"; AuthorEmail = $null }
    ResolveCommentAuthor $c | Should -Be "Vendor"
  }

  It "returns null when there is no author at all" {
    ResolveCommentAuthor ([pscustomobject]@{ AuthorName = $null; AuthorEmail = $null }) | Should -BeNullOrEmpty
  }

  It "sends History, ChangedBy and ChangedDate" {
    $patch = BuildCommentPatch $script:plainComment $null
    $paths = @($patch | ForEach-Object { $_.path })

    $paths | Should -Contain "/fields/System.History"
    $paths | Should -Contain "/fields/System.ChangedBy"
    $paths | Should -Contain "/fields/System.ChangedDate"
  }

  It "omits ChangedBy for an author-less comment rather than dropping the comment" {
    $c = [pscustomobject]@{
      AuthorName = $null; AuthorEmail = $null; AuthoredAt = "2019-03-04T16:12:00"
      Content = "Orphaned"; InReplyToAuthor = $null; InReplyToAt = $null
    }

    $patch = BuildCommentPatch $c $null
    @($patch | ForEach-Object { $_.path }) | Should -Not -Contain "/fields/System.ChangedBy"
    @($patch | ForEach-Object { $_.path }) | Should -Contain "/fields/System.History"
  }

  # ADO rejects a revision dated before the previous one (VS402625). An expression older than the
  # item itself would therefore be refused outright, so the date is clamped up rather than lost.
  It "clamps a comment older than the item's create date up to the create date" {
    $old = [pscustomobject]@{
      AuthorName = "Sara Matson"; AuthorEmail = "sara.matson@cwi.edu"
      AuthoredAt = "2015-01-01T00:00:00"; Content = "Ancient"
      InReplyToAuthor = $null; InReplyToAt = $null
    }

    $patch = BuildCommentPatch $old "2019-02-01T17:00:00"
    $when = ($patch | Where-Object { $_.path -eq "/fields/System.ChangedDate" }).value

    $when | Should -Be (FormatDate "2019-02-01T17:00:00")
  }

  It "leaves a comment newer than the create date alone" {
    $patch = BuildCommentPatch $script:plainComment "2019-02-01T17:00:00"
    $when = ($patch | Where-Object { $_.path -eq "/fields/System.ChangedDate" }).value

    $when | Should -Be (FormatDate "2019-03-04T16:12:00")
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: FAIL, `ResolveCommentAuthor` not recognized.

- [ ] **Step 3: Write the implementation**

```powershell
# Email first, then the display name. No assignability probe: these ride in a bypassRules patch,
# which accepts an identity that is not an org member - verified live 2026-08-11 - so a departed
# author is credited here even though the same person can never be an assignee.
function ResolveCommentAuthor($comment)
{
  if ($comment.AuthorEmail) { return $comment.AuthorEmail }
  if ($comment.AuthorName)  { return $comment.AuthorName }

  return $null
}

# ADO refuses a revision dated earlier than the one before it (VS402625), so an expression written
# before its own work item existed cannot go in at its real date. Clamped up to the create date
# rather than sent undated, because an undated comment lands on migration day, which is further
# from the truth. Two revisions may share a timestamp; that was verified.
function ResolveCommentDate($comment, $createDate)
{
  $authored = FormatDate $comment.AuthoredAt
  if (-not $authored) { return $null }

  $created = FormatDate $createDate
  if (-not $created) { return $authored }

  if (([datetime]$authored) -lt ([datetime]$created)) { return $created }

  return $authored
}

function BuildCommentPatch($comment, $createDate)
{
  $patch = @(
    @{ op = "add"; path = "/fields/System.History"; value = (BuildCommentBody $comment) }
  )

  # An expression with no author keeps its text. Three of them exist, and the words are the point.
  $author = ResolveCommentAuthor $comment
  if ($author) { $patch += @{ op = "add"; path = "/fields/System.ChangedBy"; value = $author } }

  $when = ResolveCommentDate $comment $createDate
  if ($when) { $patch += @{ op = "add"; path = "/fields/System.ChangedDate"; value = $when } }

  return $patch
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: PASS.

- [ ] **Step 5: Leave the change uncommitted**

---

### Task 3: Splitting the thread around the state transition

**Files:**
- Modify: `src/Migrate-Agility.ps1`
- Test: `tests/Migrate-Agility.Tests.ps1`

**Interfaces:**
- Consumes: `FormatDate($value)`.
- Produces: `SplitDiscussionAtTransition($comments, $transitionDate)` returns a PSCustomObject with `Before` and `After`, each an array.

- [ ] **Step 1: Write the failing tests**

```powershell
##################################################################################################
# The migration writes rev 1 at CreateDate and the state transition at ChangeDateUTC. ADO requires
# each revision to be dated later than the last, so a comment older than the transition MUST be
# applied before it. This is the only reason MigrateItem's ordering changed.
##################################################################################################
Describe "SplitDiscussionAtTransition" {

  BeforeAll {
    $script:thread = @(
      [pscustomobject]@{ Content = "one";   AuthoredAt = "2019-03-04T16:12:00" }
      [pscustomobject]@{ Content = "two";   AuthoredAt = "2020-05-05T18:30:00" }
      [pscustomobject]@{ Content = "three"; AuthoredAt = "2023-01-09T09:00:00" }
    )
  }

  It "puts comments at or before the transition first and the rest after" {
    $split = SplitDiscussionAtTransition $script:thread "2020-06-01T00:00:00"

    @($split.Before | ForEach-Object { $_.Content }) | Should -Be @("one", "two")
    @($split.After  | ForEach-Object { $_.Content }) | Should -Be @("three")
  }

  It "treats a comment exactly on the transition date as before it" {
    $split = SplitDiscussionAtTransition $script:thread "2020-05-05T18:30:00"

    @($split.Before | ForEach-Object { $_.Content }) | Should -Be @("one", "two")
  }

  It "returns everything in one group when there is no transition" {
    $split = SplitDiscussionAtTransition $script:thread $null

    @($split.Before).Count | Should -Be 3
    @($split.After).Count  | Should -Be 0
  }

  It "returns two empty groups for an empty thread" {
    $split = SplitDiscussionAtTransition @() "2020-06-01T00:00:00"

    @($split.Before).Count | Should -Be 0
    @($split.After).Count  | Should -Be 0
  }

  It "puts a comment with no date first, where it cannot be rejected for being out of order" {
    $split = SplitDiscussionAtTransition @([pscustomobject]@{ Content = "x"; AuthoredAt = $null }) "2020-06-01T00:00:00"

    @($split.Before).Count | Should -Be 1
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: FAIL, `SplitDiscussionAtTransition` not recognized.

- [ ] **Step 3: Write the implementation**

```powershell
# Pure, so the ordering rule can be tested without a work item. The caller applies Before, then
# transitions the state, then applies After.
function SplitDiscussionAtTransition($comments, $transitionDate)
{
  $before = @()
  $after = @()
  $cutoff = FormatDate $transitionDate

  foreach ($comment in @($comments))
  {
    if (-not $cutoff) { $before += $comment; continue }

    $when = FormatDate $comment.AuthoredAt

    # A comment with no date goes first: it will be sent without a ChangedDate, so it must not
    # land after a revision that is already backdated past it.
    if (-not $when -or ([datetime]$when) -le ([datetime]$cutoff)) { $before += $comment }
    else { $after += $comment }
  }

  return [pscustomobject]@{ Before = @($before); After = @($after) }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: PASS.

- [ ] **Step 5: Leave the change uncommitted**

---

### Task 4: Reading the discussions from Agility

The task that decides whether the feature is right at all. A comment attaches to a work item through its **conversation**, not its own `Mentions`: of 6,464 replies, only 39 repeat the mention. Selecting on `Mentions` would migrate every question and no answer.

**Files:**
- Modify: `src/Migrate-Agility.ps1`
- Test: `tests/Migrate-Agility.Tests.ps1`

**Interfaces:**
- Consumes: `InvokeAgilityGet($url)`, `GetAttributeValue($attributes, $name)`, `GetAttributeValues($attributes, $name)`, `NormalizeOid($oid)`, `WriteLog`.
- Produces: `GetAgilityDiscussions()` fills `$script:discussionsByOid` (hashtable, key `Story:12345`, value an array of comment objects sorted by `AuthoredAt`); `DiscussionFor($epic)` returns that array or `@()`.

- [ ] **Step 1: Write the failing tests**

```powershell
##################################################################################################
# Selection is by CONVERSATION, not by the mention on the individual expression. Measured
# 2026-08-11: 8,522 expressions mention a work item and they are almost all topic starters, while
# the full threads hold 14,952. Of the 6,430 that carry no mention, 6,425 are replies. Selecting on
# Mentions alone would migrate every question and 39 of 6,464 answers, and look completely clean.
##################################################################################################
Describe "GetAgilityDiscussions" {

  BeforeAll {
    function NewExpression([string]$id, [string]$conversation, [string]$author, [string]$at,
                           [string]$content, [string]$replyTo, [string[]]$mentions)
    {
      $attributes = [pscustomobject]@{}
      Add-Member -InputObject $attributes -NotePropertyName 'Author.Name'  -NotePropertyValue ([pscustomobject]@{ value = $author })
      Add-Member -InputObject $attributes -NotePropertyName 'Author.Email' -NotePropertyValue ([pscustomobject]@{ value = "$author@cwi.edu" })
      Add-Member -InputObject $attributes -NotePropertyName 'AuthoredAt'   -NotePropertyValue ([pscustomobject]@{ value = $at })
      Add-Member -InputObject $attributes -NotePropertyName 'Content'      -NotePropertyValue ([pscustomobject]@{ value = $content })
      Add-Member -InputObject $attributes -NotePropertyName 'BelongsTo'    -NotePropertyValue ([pscustomobject]@{ value = [pscustomobject]@{ idref = $conversation } })
      Add-Member -InputObject $attributes -NotePropertyName 'InReplyTo'    -NotePropertyValue ([pscustomobject]@{ value = $(if ($replyTo) { [pscustomobject]@{ idref = $replyTo } } else { $null }) })
      Add-Member -InputObject $attributes -NotePropertyName 'Mentions'     -NotePropertyValue ([pscustomobject]@{ value = @($mentions | ForEach-Object { [pscustomobject]@{ idref = $_ } }) })

      return [pscustomobject]@{ id = $id; Attributes = $attributes }
    }
  }

  BeforeEach {
    $script:config = [pscustomobject]@{ Agility = [pscustomobject]@{ BaseUrl = "https://example.invalid/CWI" } }
    $script:discussionsByOid = @{}
  }

  It "gives a work item the WHOLE thread, including replies that carry no mention" {
    Mock InvokeAgilityGet {
      [pscustomobject]@{ Assets = @(
        (NewExpression "Expression:1" "Conversation:9" "Sara"    "2019-03-04T16:12:00" "Question" $null       @("Story:12345"))
        (NewExpression "Expression:2" "Conversation:9" "Shannon" "2019-03-05T14:40:00" "Answer"   "Expression:1" @("Member:1013"))
      ) }
    }

    GetAgilityDiscussions

    $thread = $script:discussionsByOid["Story:12345"]
    @($thread).Count | Should -Be 2
    @($thread | ForEach-Object { $_.Content }) | Should -Be @("Question", "Answer")
  }

  It "resolves the reply's parent author and date, for the reply marker" {
    Mock InvokeAgilityGet {
      [pscustomobject]@{ Assets = @(
        (NewExpression "Expression:1" "Conversation:9" "Sara"    "2019-03-04T16:12:00" "Question" $null          @("Story:12345"))
        (NewExpression "Expression:2" "Conversation:9" "Shannon" "2019-03-05T14:40:00" "Answer"   "Expression:1" @())
      ) }
    }

    GetAgilityDiscussions

    $reply = $script:discussionsByOid["Story:12345"] | Where-Object { $_.Content -eq "Answer" }
    $reply.InReplyToAuthor | Should -Be "Sara"
    $reply.InReplyToAt     | Should -Be "2019-03-04T16:12:00"
  }

  It "sorts the thread by AuthoredAt, whatever order the wire returned it in" {
    Mock InvokeAgilityGet {
      [pscustomobject]@{ Assets = @(
        (NewExpression "Expression:2" "Conversation:9" "Shannon" "2020-05-05T18:30:00" "second" $null @())
        (NewExpression "Expression:1" "Conversation:9" "Sara"    "2019-03-04T16:12:00" "first"  $null @("Story:12345"))
      ) }
    }

    GetAgilityDiscussions

    @($script:discussionsByOid["Story:12345"] | ForEach-Object { $_.Content }) | Should -Be @("first", "second")
  }

  It "posts a thread to every work item its conversation mentions" {
    Mock InvokeAgilityGet {
      [pscustomobject]@{ Assets = @(
        (NewExpression "Expression:1" "Conversation:9" "Sara" "2019-03-04T16:12:00" "Shared" $null @("Story:12345", "Defect:777"))
      ) }
    }

    GetAgilityDiscussions

    @($script:discussionsByOid["Story:12345"]).Count | Should -Be 1
    @($script:discussionsByOid["Defect:777"]).Count  | Should -Be 1
  }

  # $epic.Oid is normalized to Type:Id, but a mention idref can carry the moment as a third part.
  # Without NormalizeOid the keys never match and every lookup silently returns nothing - the same
  # shape of bug as the Int64/Int32 mismatch that made every relation read as dangling.
  It "normalizes a mention oid that carries a moment suffix" {
    Mock InvokeAgilityGet {
      [pscustomobject]@{ Assets = @(
        (NewExpression "Expression:1" "Conversation:9" "Sara" "2019-03-04T16:12:00" "Hi" $null @("Story:12345:6789"))
      ) }
    }

    GetAgilityDiscussions

    $script:discussionsByOid.ContainsKey("Story:12345") | Should -BeTrue
  }

  It "ignores a conversation that mentions nothing we migrate, which is how sample data stays out" {
    Mock InvokeAgilityGet {
      [pscustomobject]@{ Assets = @(
        (NewExpression "Expression:1" "Conversation:9" "Sample: Andre Agile" "2015-01-01T00:00:00" "Demo" $null @("Member:1013"))
      ) }
    }

    GetAgilityDiscussions

    $script:discussionsByOid.Count | Should -Be 0
  }

  It "returns an empty list for an item with no discussion" {
    $script:discussionsByOid = @{}
    @(DiscussionFor ([pscustomobject]@{ Oid = "Story:99999" })).Count | Should -Be 0
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: FAIL, `GetAgilityDiscussions` not recognized.

- [ ] **Step 3: Write the implementation**

Place after `SplitDiscussionAtTransition`:

```powershell
# One pass over every Expression in the instance, exactly like RecordAllNumbersInRun and for the
# same reason: reading them per work item would be 53,000 extra round trips on a run that already
# takes 14 hours. About 100 calls at this page size.
#
# Selection is by CONVERSATION. An expression's Mentions link names what the thread is about, and
# it is set on the topic starter; replies carry no mention at all. Of 6,464 replies measured on
# 2026-08-11, 39 repeat it. Keying off Mentions alone would migrate every question and no answer.
function GetAgilityDiscussions()
{
  $script:discussionsByOid = @{}

  $migratedTypes = @('Epic', 'Story', 'Defect', 'Task', 'Issue')
  $selection = "Author.Name,Author.Email,AuthoredAt,Content,Mentions,InReplyTo,BelongsTo"
  $pageSize = 500
  $start = 0

  $threadByConversation = @{}
  $itemsByConversation = @{}
  $commentByOid = @{}

  while ($true)
  {
    $url = "{0}/rest-1.v1/Data/Expression?sel={1}&page={2},{3}" -f `
      $script:config.Agility.BaseUrl.TrimEnd('/'),
      [uri]::EscapeDataString($selection),
      $pageSize,
      $start

    $assets = @((InvokeAgilityGet $url).Assets)
    if ($assets.Count -eq 0) { break }

    foreach ($asset in $assets)
    {
      $conversation = GetAttributeValue $asset.Attributes 'BelongsTo'
      if (-not $conversation) { continue }

      $comment = [pscustomobject]@{
        Oid             = "$($asset.id)"
        AuthorName      = GetAttributeValue $asset.Attributes 'Author.Name'
        AuthorEmail     = GetAttributeValue $asset.Attributes 'Author.Email'
        AuthoredAt      = GetAttributeValue $asset.Attributes 'AuthoredAt'
        Content         = GetAttributeValue $asset.Attributes 'Content'
        InReplyToOid    = GetAttributeValue $asset.Attributes 'InReplyTo'
        InReplyToAuthor = $null
        InReplyToAt     = $null
      }

      $commentByOid[$comment.Oid] = $comment

      if (-not $threadByConversation.ContainsKey($conversation)) { $threadByConversation[$conversation] = @() }
      $threadByConversation[$conversation] += $comment

      foreach ($mention in (GetAttributeValues $asset.Attributes 'Mentions'))
      {
        $idref = if ($mention -is [psobject] -and $mention.PSObject.Properties['idref']) { $mention.idref } else { "$mention" }

        # NormalizeOid, because a mention can carry the moment as a third part while $epic.Oid is
        # always Type:Id. Unnormalized keys match nothing and the lookup fails silently.
        $oid = NormalizeOid $idref
        if (-not $oid) { continue }
        if (($oid -split ':')[0] -notin $migratedTypes) { continue }

        if (-not $itemsByConversation.ContainsKey($conversation)) { $itemsByConversation[$conversation] = @{} }
        $itemsByConversation[$conversation][$oid] = $true
      }
    }

    if ($assets.Count -lt $pageSize) { break }
    $start += $pageSize
  }

  # Reply parents are resolved only now, because a reply can be read before the expression it
  # answers.
  foreach ($comment in $commentByOid.Values)
  {
    if (-not $comment.InReplyToOid) { continue }

    $parent = $commentByOid["$($comment.InReplyToOid)"]
    if (-not $parent) { continue }

    $comment.InReplyToAuthor = $parent.AuthorName
    $comment.InReplyToAt     = $parent.AuthoredAt
  }

  $comments = 0
  foreach ($conversation in $itemsByConversation.Keys)
  {
    # Sorted here, once, so every consumer gets chronological order without re-sorting. An
    # undated expression sorts first, where it cannot be rejected for arriving out of order.
    $thread = @($threadByConversation[$conversation] | Sort-Object {
      if ($_.AuthoredAt) { [datetime]$_.AuthoredAt } else { [datetime]::MinValue }
    })

    foreach ($oid in $itemsByConversation[$conversation].Keys)
    {
      $script:discussionsByOid[$oid] = $thread
      $comments += $thread.Count
    }
  }

  WriteLog "Read $comments Agility discussion comments for $($script:discussionsByOid.Count) work items"
  WriteLog
}

function DiscussionFor($epic)
{
  if (-not $script:discussionsByOid) { return @() }
  if (-not $epic.Oid) { return @() }

  $thread = $script:discussionsByOid["$($epic.Oid)"]
  if (-not $thread) { return @() }

  return @($thread)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: PASS.

- [ ] **Step 5: Leave the change uncommitted**

---

### Task 5: Writing the comments to Azure DevOps

**Files:**
- Modify: `src/Migrate-Agility.ps1`
- Test: `tests/Migrate-Agility.Tests.ps1`

**Interfaces:**
- Consumes: `BuildCommentPatch($comment, $createDate)`, `InvokeAdoRequest($url, $method, $body, $contentType)`, `ReadAdoError($errorRecord)`, `WriteLog`, `WriteErrorDetail`.
- Produces: `AddAdoDiscussion([int]$id, $epic, $comments)`, and the counters `$script:commentsCopied` / `$script:commentsFailed`.

- [ ] **Step 1: Write the failing tests**

```powershell
Describe "AddAdoDiscussion" {

  BeforeAll {
    $script:epicWithThread = [pscustomobject]@{
      Number = "S-12345"; Oid = "Story:12345"; CreateDate = "2019-02-01T17:00:00"
    }
    $script:twoComments = @(
      [pscustomobject]@{ AuthorName = "Sara"; AuthorEmail = "sara@cwi.edu"; AuthoredAt = "2019-03-04T16:12:00"; Content = "one"; InReplyToAuthor = $null; InReplyToAt = $null }
      [pscustomobject]@{ AuthorName = "Ann";  AuthorEmail = "ann@cwi.edu";  AuthoredAt = "2019-03-05T16:12:00"; Content = "two"; InReplyToAuthor = $null; InReplyToAt = $null }
    )
  }

  BeforeEach {
    $script:DryRun = $false
    $script:warnings = 0
    $script:commentsCopied = 0
    $script:commentsFailed = 0
    $script:config = [pscustomobject]@{ AzureDevOps = [pscustomobject]@{ OrganizationUrl = "https://dev.azure.com/org" } }
    Mock WriteLog {}
    Mock WriteErrorDetail {}
  }

  It "sends one patch per comment" {
    Mock InvokeAdoRequest {}

    AddAdoDiscussion 42 $script:epicWithThread $script:twoComments

    Should -Invoke InvokeAdoRequest -Times 2 -Exactly
    $script:commentsCopied | Should -Be 2
  }

  # bypassRules is what allows the backdating AND the departed author. Without it ADO stamps the
  # comment with the migration account and the moment of the run, which is the whole point lost.
  It "sends bypassRules on every comment patch" {
    Mock InvokeAdoRequest { $script:seenUrl = $url }

    AddAdoDiscussion 42 $script:epicWithThread @($script:twoComments[0])

    $script:seenUrl | Should -BeLike "*bypassRules=true*"
  }

  It "writes nothing on a dry run" {
    $script:DryRun = $true
    Mock InvokeAdoRequest {}

    AddAdoDiscussion 42 $script:epicWithThread $script:twoComments

    Should -Invoke InvokeAdoRequest -Times 0 -Exactly
  }

  It "does nothing for an item with no comments" {
    Mock InvokeAdoRequest {}

    AddAdoDiscussion 42 $script:epicWithThread @()

    Should -Invoke InvokeAdoRequest -Times 0 -Exactly
  }

  # The item already exists by the time comments are written, so a comment that will not post must
  # warn and move on rather than undo a perfectly good work item. Same rule as attachments.
  It "warns and continues when one comment fails, and still posts the rest" {
    $script:calls = 0
    Mock InvokeAdoRequest {
      $script:calls++
      if ($script:calls -eq 1) { throw "boom" }
    }

    { AddAdoDiscussion 42 $script:epicWithThread $script:twoComments } | Should -Not -Throw

    $script:commentsFailed | Should -Be 1
    $script:commentsCopied | Should -Be 1
    $script:warnings       | Should -Be 1
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: FAIL, `AddAdoDiscussion` not recognized.

- [ ] **Step 3: Write the implementation**

Place next to `AddAdoAttachments`:

```powershell
# The migrated conversation, one bypassRules patch per comment.
#
# bypassRules is not optional here: it is what lets the comment carry its real date and its real
# author, including an author who is no longer an org member. Verified live 2026-08-11 - the same
# address a rule-checked assignee patch rejects is accepted here and comes back as the comment's
# createdOnBehalfOf.
#
# Non fatal per comment, exactly like attachments: the work item exists by now, so a comment that
# will not post must not undo it.
function AddAdoDiscussion([int]$id, $epic, $comments)
{
  if ($script:DryRun) { return }

  $list = @($comments)
  if ($list.Count -eq 0) { return }

  $url = "{0}/_apis/wit/workitems/{1}?api-version=7.1&bypassRules=true" -f `
    $script:config.AzureDevOps.OrganizationUrl.TrimEnd('/'), $id

  foreach ($comment in $list)
  {
    try
    {
      InvokeAdoRequest $url "Patch" (BuildCommentPatch $comment $epic.CreateDate) "application/json-patch+json" | Out-Null
      $script:commentsCopied++
    }
    catch
    {
      $who = if ($comment.AuthorName) { $comment.AuthorName } else { "an unknown author" }
      WriteLog "  WARN    $($epic.Number) discussion comment from $who could not be added - $(ReadAdoError $_)" Yellow
      WriteErrorDetail $_ "discussion comment on $($epic.Number) from $who"
      $script:warnings++
      $script:commentsFailed++
    }
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: PASS.

- [ ] **Step 5: Leave the change uncommitted**

---

### Task 6: Wiring it into the run

**Files:**
- Modify: `src/Migrate-Agility.ps1` at `Migrate` (counters near line 4045, the `RecordAllNumbersInRun` call at line 184), `MigrateItem` (dry run text near line 1937, the create sequence near lines 1985-2028), and `WriteSummary` (near line 4105)
- Test: `tests/Migrate-Agility.Tests.ps1`

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: no new callable surface. Behavioural wiring only.

- [ ] **Step 1: Write the failing tests**

```powershell
Describe "Discussions are wired into the run" {

  BeforeAll {
    $script:source = Get-Content (Join-Path $PSScriptRoot ".." "src" "Migrate-Agility.ps1") -Raw
    $script:code = ($script:source -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
  }

  # Same rule as RecordAllNumbersInRun: it must run before the type loop, or every item migrates
  # before its discussion has been read and the feature does nothing at all.
  It "reads discussions before the first item is migrated" {
    $read = $script:code.IndexOf("GetAgilityDiscussions")
    $loop = $script:code.IndexOf("MigrateEpics")

    $read | Should -BeGreaterThan 0
    $read | Should -BeLessThan $loop
  }

  # The transition is backdated to ChangeDateUTC, so a comment older than it can only go in before.
  It "applies the pre-transition comments before SetAdoState and the rest after" {
    $before = $script:code.IndexOf("AddAdoDiscussion `$id `$epic `$discussion.Before")
    $state  = $script:code.IndexOf("SetAdoState `$id `$adoState `$epic")
    $after  = $script:code.IndexOf("AddAdoDiscussion `$id `$epic `$discussion.After")

    $before | Should -BeGreaterThan 0
    $before | Should -BeLessThan $state
    $after  | Should -BeGreaterThan $state
  }

  It "reads Expressions through InvokeAgilityGet, never a raw Invoke-RestMethod" {
    $script:code | Should -Not -Match 'Invoke-RestMethod[^\n]*Expression'
  }

  It "never sends a write verb to the Expression endpoint" {
    foreach ($verb in @('Post', 'Put', 'Patch', 'Delete'))
    {
      $script:code | Should -Not -Match "$verb[^\n]*rest-1\.v1/Data/Expression"
    }
  }

  It "reports the comment counters in the summary" {
    $script:code | Should -Match 'commentsCopied'
    $script:code | Should -Match 'commentsFailed'
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: FAIL on the ordering and summary assertions.

- [ ] **Step 3: Make the four edits**

**3a.** In `Migrate`, beside the attachment counters:

```powershell
  # Discussion comments moved from Agility, and the ones that would not move. Counted apart from
  # items for the same reason attachments are: a failed comment leaves a good work item.
  $script:commentsCopied = 0
  $script:commentsFailed = 0
```

**3b.** In `Migrate`, immediately after `RecordAllNumbersInRun $Types $scopes`:

```powershell
  # Every Agility conversation, read once. Before the type loop, because an item migrated before
  # this ran would get no discussion at all, and because a comment can only be backdated while its
  # item is being created - there is no second chance later.
  GetAgilityDiscussions
```

**3c.** In `MigrateItem`, replace the create sequence between `AddAdoDependencyLinks` and `SetAdoAssignee`:

```powershell
    # The conversation, split around the state transition. ADO requires each revision to be dated
    # later than the last, and the transition is backdated to ChangeDateUTC, so a comment older
    # than the transition has to go in before it or ADO rejects it outright (VS402625).
    $discussion = SplitDiscussionAtTransition (DiscussionFor $epic) $epic.ChangeDate
    AddAdoDiscussion $id $epic $discussion.Before

    # Revision 2: the state transition, backdated and attributed to the last changer. Only when the
    # mapped state differs from the create-time default, so an item that never left its default state
    # gets no empty second revision.
    $adoState = MapState $epic
    if ($adoState -ne (GetStateMap $epic).DefaultState)
    {
      SetAdoState $id $adoState $epic
    }

    AddAdoDiscussion $id $epic $discussion.After
```

**3d.** In `MigrateItem`'s dry run line, beside `$attachmentText`:

```powershell
    # Say how many comments a real run would add. Nothing is written to work this out.
    $discussionCount = @(DiscussionFor $epic).Count
    $discussionText = if ($discussionCount -gt 0) { " discussion=$discussionCount" } else { "" }
```

and append `$discussionText` to the `WOULD` line, immediately after `$attachmentText`.

**3e.** In `WriteSummary`, after the attachment block:

```powershell
  # Comments are counted apart from items for the same reason files are: one that would not post
  # leaves a warning and a perfectly good work item.
  if ($script:commentsCopied -gt 0 -or $script:commentsFailed -gt 0)
  {
    WriteLog "Comments: $script:commentsCopied copied, $script:commentsFailed failed"
  }
```

- [ ] **Step 4: Run the full suite**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: PASS, 0 failures, and the pre-existing 491 tests all still passing.

- [ ] **Step 5: Dry run against one real scope**

Run:

```powershell
# In Main, temporarily: Migrate -DryRun -Types Story -Scope "Scope:16163"
./src/Migrate-Agility.ps1
```

Expected: the header reports `Read N Agility discussion comments for M work items`, and some `WOULD` lines carry `discussion=N`. Nothing is written to either system. Restore `Main` afterwards.

- [ ] **Step 6: Leave the change uncommitted**

Report the files touched and the dry run output. Richard commits.

---

## Verification before calling this done

- [ ] `Invoke-Pester -Path tests -Output Detailed` reports 0 failures.
- [ ] A dry run over `Scope:16163` prints a non-zero discussion count and writes nothing.
- [ ] A live run against ONE small scope, checked by reading a work item back through the API: the comment count matches Agility, `createdOnBehalfOf` holds the Agility author, and `createdOnBehalfDate` holds the Agility date. Verify the DATA, not the counter - two write paths in this project have returned HTTP 200 while doing nothing.
- [ ] Update `CLAUDE.md`: move the discussions section from "researched, not implemented" to implemented, with the live numbers.
