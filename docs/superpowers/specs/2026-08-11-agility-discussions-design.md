# Migrating Agility discussions into Azure DevOps comments

Design, 2026-08-11. Status: approved, not yet implemented.

Migrates digital.ai Agility `Expression` assets (the Conversations feature) into Azure DevOps work
item comments, backdated to when they were written and attributed to who wrote them.

## Why this cannot wait for a later pass

Azure DevOps enforces `VS402625: Dates must be increasing with each revision`. The migration's last
two revisions on every item (the rule-checked assignee patch, then the migration note) are stamped at
the moment of the run, so **once an item is finished, no earlier-dated comment can ever be added to
it**. There is no backfill. Discussions arrive during a full re-migration or not at all.

Proved on a throwaway: a work item created at "now" rejected four backdated comments; the same four
succeeded against an item whose create was backdated first.

## Measured scope

All figures measured live on 2026-08-11 against the CWI instance, not estimated.

| | |
| --- | ---: |
| `Expression` assets in the instance | 49,977 |
| `Conversation` assets | 24,971 |
| Conversations touching a migrated work item | 8,488 |
| **Comments this feature writes** | **15,228** |
| **Work items receiving a discussion** | **5,654** (10.5% of 53,683) |
| Longest thread on a single item | 37 |
| Distinct comment authors | 125 |
| Expressions with no author | 3 |
| Expressions with no date | 0 |
| Plain text / containing markup | 14,933 / 19 |

Per item: 2,346 items get exactly 1 comment, 2,736 get 2-5, 562 get 6-20, 10 get 21-50, none more.
Per type: Story 3,471, Task 1,450, Defect 570, Epic 104, Issue 59.

The 15,228 comments come from 14,952 distinct expressions. The difference is not an error: 79
conversations reference more than one work item, and their threads are posted to each, by decision
below.

## The finding that shapes the whole design

**A comment attaches to a work item through its CONVERSATION, not through its own `Mentions`.**

Measured: 8,522 expressions mention a migrated work item, and those are essentially all
topic-starters (8,488 conversations). The full threads hold 14,952 expressions. Of the 6,430 that do
not mention the item themselves, **6,425 are replies** - only 39 replies repeat the mention.

Selecting on `Mentions` alone would therefore migrate **every question and almost no answer**,
dropping 99.4% of replies, with nothing in the log to suggest anything was wrong. The selection rule
is the conversation closure: for any conversation that mentions a migrated work item, take the whole
thread.

## What Azure DevOps accepts, proved on throwaway items

- **The Comments API cannot backdate.** Posting with `createdDate` 2018-01-01 returns the comment
  stamped at the time of the call. Wrong door; do not use it.
- **A `System.History` patch under `bypassRules`, carrying `System.ChangedBy` and
  `System.ChangedDate`, is the right one.** It writes an attributed revision and populates
  `createdOnBehalfOf` / `createdOnBehalfDate` on the comment record.
- **It accepts an author who is not an org member.** Verified with an address that does not exist,
  which came back as both the revision's `ChangedBy` and the comment's `createdOnBehalfOf`. This is
  the opposite of `System.AssignedTo`, where 59 owners of 23,253 items are unassignable. Departed
  staff can be credited on comments, so no identity probe and no `MaterializeOwners` dependency.
- Same-second comments are accepted. Out-of-order ones are rejected. HTML bodies round-trip.
- **Unverified:** whether the Discussion tab renders `createdOnBehalfOf`. The API stores it; nobody
  has looked at the UI. This is why the body carries its own attribution header (see below).

## Components

Each is small, single-purpose, and testable without the network.

### `GetAgilityDiscussions` (new)

One pass over `rest-1.v1/Data/Expression` at `page=500`, through the existing `InvokeAgilityGet` so
the read-only guarantee holds. Selection:
`Author.Name,Author.Email,AuthoredAt,Content,Mentions,Mentions.Name,InReplyTo,BelongsTo,IsTopic`.

Groups expressions by `BelongsTo`; for each conversation mentioning one or more migrated work items,
sorts the thread by `AuthoredAt` and assigns it to **every** mentioned oid. Returns
`$script:discussionsByOid`, keyed by Agility oid (`Story:12345`).

Called from `Migrate` **before the type loop**, beside `RecordAllNumbersInRun`, for the same reason
that walk exists separately: reading the assets a second time would add hours to a 14 hour run. About
100 calls, 3 to 4 minutes.

**There is deliberately NO demo-content filter.** Agility's shipped sample conversations
(`Sample: Andre Agile`, `Sample: Claus Customer`) exist - 24 expressions across 8 conversations - but
measured 2026-08-11, **none of them reaches a migrated work item**, so the conversation-closure rule
already excludes every one. A `Sample: ` prefix filter would remove nothing today while standing
ready to silently drop a genuine comment that happens to open with that word. Do not add one without
new evidence.

### `BuildCommentBody` (new, pure)

Produces the HTML body for one expression:

```
<b>Brittney Trimmer</b> wrote in Agility on 4 March 2019:
<br><br>
Now that we have this Order Check Epic, I would like your input on the different pieces.
```

and for a reply:

```
<b>Shannon Grimsley</b> wrote in Agility on 5 March 2019, in reply to Brittney Trimmer (4 March 2019):
```

- **The content is HTML-escaped and newlines converted.** This is load bearing, not cosmetic: 14,933
  of the 15,228 bodies are plain text, so any `<` or `&` in one would render mangled or swallow the
  rest of the comment, and a green run would not show it.
- The attribution header is always present, by decision on 2026-08-11, because the Discussion tab's
  handling of `createdOnBehalfOf` is unverified. If the UI does render it, the header is one
  redundant line; if it does not, the header is the only record of who wrote the comment.

### `ResolveCommentAuthor` (new, pure)

Email first, then display name, then nothing. No assignability probe: `bypassRules` accepts
non-members, which is the whole reason attribution works here. The 3 expressions with no author omit
`System.ChangedBy` and keep their text rather than being dropped.

### `SplitDiscussionAtTransition` (new, pure)

Given an ordered comment list and the state transition's date (`ChangeDateUTC`, the same value
`SetAdoState` backdates to), returns two lists: comments whose `AuthoredAt` is **at or before** that
date, and those after it. When there is no transition, everything comes back in the first list. Pure,
so the ordering rule is testable without a work item.

### `AddAdoDiscussion` (new)

Applies an ordered list to one work item, one `bypassRules` patch per comment. Non-fatal per comment,
exactly like `AddAdoAttachments`: the item exists by then, so a comment that will not post warns,
increments `$script:commentsFailed`, and the run continues.

When an expression's `AuthoredAt` is earlier than the item's own Agility `CreateDate`, the comment's
`System.ChangedDate` is clamped up to that create date and a warning is logged. Clamping rather than
sending no date, because an undated comment lands on migration day, which is further from the truth
than being a few hours early; and never dropping the comment, because the text is the point. ADO
accepts two revisions sharing a timestamp, verified, so a clamped comment cannot collide with the
create.

How often this fires is **not yet measured** - it needs each item's `CreateDate`, which only the
migration itself holds. The rule is therefore defensive by design: without it, such a comment is
rejected outright by `VS402625`.

### `MigrateItem` (changed)

The only change to existing logic, and it is deliberate rather than incidental:

```
rev 1   NewAdoWorkItem          dated CreateDate
        AddAdoDependencyLinks
        AddAdoDiscussion  <before>          <- new
rev n   SetAdoState             dated ChangeDateUTC
        AddAdoDiscussion  <after>           <- new
rev n+1 SetAdoAssignee          dated now
        AddAdoAttachments
rev n+2 AddAdoMigrationComment  dated now
```

When the item has no state transition (its mapped state equals the type's default), the whole list is
applied in one call.

## Decisions taken

- **Attribution header always.** See `BuildCommentBody`.
- **Reply marker line**, not quoted parent text and not bare chronology. `InReplyTo` is real data and
  would otherwise be dropped; quoting duplicates text that averages 179 characters.
- **Merged timeline** rather than applying every comment on one side of the transition. It is the
  only option under which every comment keeps its true date.
- **Threads on multi-item conversations are duplicated.** 79 conversations reference more than one
  work item; posting to only the first would silently drop the discussion from the others.
- **No new switch.** Discussions migrate as part of a normal run. `-IncludeClosed` was removed from
  this tool because every real run used it, and the same reasoning applies.
- **Dry run writes nothing** and prints `discussion=N`, mirroring attachments.

## Not migrated

- Thread shape beyond the reply marker. ADO comments are flat.
- @person mentions as real ADO mentions: 54,583 of them, and a real mention needs an identity GUID.
  They stay as the plain text the author typed.
- The ~35,000 expressions in conversations that never touch a migrated work item, including all
  `Request` (2,983 mentions) and `Test` (36) conversation.
- `ExpressionImages` (inline images), which would need the attachment pipeline pointed at them.
- Agility's shipped sample conversations, which fall out of scope on their own. See
  `GetAgilityDiscussions`.

## Testing

Pester 5, in `tests/Migrate-Agility.Tests.ps1`, matching the existing style. Every rule above that
could fail silently gets a test:

1. Content is HTML-escaped and newlines converted; a body containing `<` and `&` survives intact.
2. The attribution header is present and carries the author and the Agility date.
3. A reply carries the marker naming its parent's author and date; a topic-starter does not.
4. **A reply with no `Mentions` still lands on the work item** - the conversation-closure rule, and
   the single most valuable test here, since without it 6,425 replies vanish and nothing complains.
5. A conversation mentioning two work items produces the thread on both.
6. A conversation that mentions no migrated work item produces nothing, which is what keeps Agility's
   sample data out without a text filter.
7. `SplitDiscussionAtTransition` puts pre-transition comments before and post-transition after, and
   returns everything in one group when there is no transition.
8. A comment predating the item's create date is clamped, not dropped and not left undated.
9. An expression with no author omits `System.ChangedBy` and still posts its text.
10. Every comment patch carries `bypassRules`, `System.History`, and (where known) `ChangedBy` and
    `ChangedDate`.
11. A failing comment warns and increments the counter without failing the item.
12. `Migrate` calls `GetAgilityDiscussions` once, before the type loop.
13. The new read goes through `InvokeAgilityGet`; no new `Invoke-RestMethod` against Agility, and no
    write verb, preserving the read-only rule.

## Cost and risk

Roughly 15,228 extra patches, plus one 3 to 4 minute Agility pass. Budget 45 to 75 minutes on top of
the ~14 hour run.

The risk that matters is that this edits `MigrateItem`'s revision sequencing, which is the most load
bearing code in the tool and the source of the `TF401320 Closed Date` failure that killed 30,928
Tasks in July. The mitigations are that the ordering lives in a pure, separately tested function
rather than inline, that comment failures cannot fail an item, and that a dry run over a real scope
is run before any live run.
