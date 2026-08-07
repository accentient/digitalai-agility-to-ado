# Migration reference

The detail behind the summary in the [README](../README.md): the full field mapping, and why the
tool behaves the way it does where that behavior is not obvious. `docs/design.md` covers the design
rationale and the field audits.

## Contents

- [Field mapping](#field-mapping)
- [Why nested Epics become Features](#why-nested-epics-become-features)
- [Close dates and the revision history](#close-dates-and-the-revision-history)
- [Archiving long-finished work](#archiving-long-finished-work)
- [Acceptance criteria are recovered from the description](#acceptance-criteria-are-recovered-from-the-description)
- [Attachments](#attachments)
- [Owners and identities](#owners-and-identities)
- [Area paths](#area-paths)

## Field mapping

| Agility | Azure DevOps |
|---|---|
| `Name` | `System.Title` (truncated at 255; full text kept in the description) |
| `Number` | `Custom.DigitalAIID` (drives idempotency) and a Discussion comment on the migrated item |
| `Description` | `System.Description` (HTML passed through) |
| `Status` | `System.State` per type (closed-in-source lands closed, and long-finished work lands `Removed` - see below); raw status kept in `Custom.DigitalAIStatus` |
| `Super` | parent link (Related link when flattened) |
| `Scope` + `Theme` (+ `Team`) | `System.AreaPath` (scope path + Theme leaf; Tasks inherit their parent's Theme; the Team places items that would otherwise land at the project root) |
| `Timebox` | `System.IterationPath` |
| `Owners` | `System.AssignedTo` (first *assignable* owner); the rest to `Custom.DigitalAIOwners` |
| `CreatedBy`/`CreateDate`, `ChangedBy`/`ChangeDate` | backdated `System.CreatedBy/CreatedDate` and `ChangedBy/ChangedDate` (two-point history) |
| `ClosedDate` | `Microsoft.VSTS.Common.ClosedDate`, written inside the closing transition |
| `Order` | `Microsoft.VSTS.Common.BacklogPriority` |
| `Category`, `Custom_FiscalYear`, `Team`, `Custom_Mandate`, `StrategicThemes`, `ResolutionReason` | `Custom.DigitalAI*` fields (see `mappings.json` `CustomFields`); the multi-value ones are joined with `; ` |
| `ClosedBy` | `Microsoft.VSTS.Common.ClosedBy`, in a rule-checked patch, only when ADO accepts the identity |
| `TaggedWith` | `System.Tags` |
| `Dependencies` / `Dependants` | Successor / Predecessor links (`System.LinkTypes.Dependency-*`) |
| `Links` | `Hyperlink` relations (non-URL locations go to the description) |
| `Attachments` | files downloaded from the source and uploaded to ADO as `AttachedFile` relations |
| an "Acceptance Criteria" heading inside `Description` | `Microsoft.VSTS.Common.AcceptanceCriteria` (cloned, not moved - see below) |
| `Personas`, `Risk`, `Reference`, `RequestedBy` | the description's "Agility details" block (no ADO field exists for these) |
| `Category` | `Custom.DigitalAICategory`, collapsed onto the values that field accepts - plus a `Digital.ai category: <raw>` note at the bottom of the description for every item that has one |
| `Issue.BlockedPrimaryWorkitems` / `BlockedEpics` ("blocks") | `Affects` links (`Microsoft.VSTS.Common.Affects-Forward`) |
| `Issue.PrimaryWorkitems` ("relates to") | `Related` links (`System.LinkTypes.Related`) - the weaker association, so not `Affects` |
| unmigrated parent / blocked item / related item / dependency / source | `agility-parent:` / `agility-blocks:` / `agility-relates:` / `agility-depends:` / `agility-source:` tags |

Field, state, and value-map configuration lives in `mappings.json` and can be customized without
editing the script. States are keyed per type, because ADO's states are per type (an Impediment has
no `Done`; an Epic has no `Approved`).

## Why nested Epics become Features

Agility lets an Epic parent another Epic, to any depth. Azure DevOps does **not** reject an Epic
parented to an Epic - it accepts the link and then
[silently breaks the backlog](https://learn.microsoft.com/en-us/azure/devops/boards/backlogs/resolve-backlog-reorder-issues?view=azure-devops):
reordering is disabled and intermediate items vanish from sprint backlogs. Because there is no error
to catch, the tool resolves the hierarchy before writing: every Epic below the top level becomes a
**Feature** under the top-level Epic. Epics nested 3+ deep are flattened onto the root, with the real
parent preserved as a **Related** link and named in the description.

## Close dates and the revision history

The Scrum process owns `Closed Date` (auto-stamped on entry to a closed state). To keep the *real*
historical date, and to backdate the created/changed revisions, the tool uses `bypassRules` on the
create and the state transition. The close date is written **inside** the closing transition, so it
is present before the rule-checked assignee patch runs (Task's `Done` requires a non-empty close
date). `System.AssignedTo` is never sent in a `bypassRules` payload - it is set by a separate
rule-checked patch, so a departed identity is rejected rather than stored. This needs a PAT whose
identity holds bypass rights.

## Archiving long-finished work

Set `StaleAfterDays` in `mappings.json` and work that finished longer ago than that is created in its
type's `StaleState` (`Removed`) instead of its `ClosedState`, so a decade of finished work doesn't
arrive looking like a live backlog. The rule is deliberately narrow:

- It only ever applies to an item that would **otherwise land in its closed state**. Nothing active
  or in progress is touched, however old it is.
- It only applies to a type that **has** a `StaleState`. Impediment has no `Removed` state, so
  `Issue` is given none - the exclusion is missing config, not a hard-coded type check, and
  `AssertStatesExist` fails the run up front if anyone adds one.
- Age comes from `ClosedDate`, falling back to `ChangeDate` then `CreateDate`. An item with **no date
  at all is never archived**: no evidence of age is not the same as being old.
- The cutoff is resolved **once per run**, so every item is measured against the same instant.
- The real close date still rides along on the transition. `Removed` accepts `Closed Date` and does
  not require it (verified live on Epic, PBI, Bug and Task), so nothing is lost and no date is ever
  fabricated for it.

Omit the key, or set it to zero or less, and the rule is off. **Azure DevOps hides `Removed` items
from backlogs, boards, and default queries** - that is the point of archiving, but it is worth
knowing before a run puts most of your items there. `-DryRun` prints `state=` per item and the
summary counts how many would be removed, so check that number before writing.

## Acceptance criteria are recovered from the description

Agility has **no acceptance criteria attribute on any type** - people write them into the description
under a heading. The tool finds that heading and **clones** the section into
`Microsoft.VSTS.Common.AcceptanceCriteria`, leaving the text in the description as well, so nothing
moves and nothing is lost.

The section runs from the heading to the next heading (a real `<h1-6>`, a paragraph that is only
short bold text, or a short plain paragraph ending in a colon - all three occur in real data), or to
the end of the description. Orphaned closing tags and trailing spacer paragraphs are trimmed, and a
heading with nothing under it writes no field at all.

`Acceptance Criteria` is matched case-insensitively with an optional colon. `AC` is honoured **only
in heading position** - preceded by a block tag and followed by a colon - because in the measured
corpus every standalone `AC` in prose was something else entirely ("no MS or `AC` line"). Matching it
loosely would be all false positives. The field only exists on Epic, Feature, Product Backlog Item
and Bug, so Task and Impediment are skipped rather than having the write silently dropped.

## Attachments

Files are **copied**, not referenced: the source keeps them behind an authenticated endpoint, so each
one is downloaded and re-uploaded into the ADO project's attachment store, then linked as an
`AttachedFile` relation with a comment naming the source item.

Copying is deliberately non-fatal. The work item already exists by then, so a file that won't move
produces a warning and a count rather than losing the item, and each file is handled independently.
Anything over 60 MB (ADO's default cap) is skipped with a warning. A `-DryRun` downloads nothing and
just reports `attachments=N` per item; the run summary reports files copied and failed separately
from item counts.

The binary path is worth one note for anyone modifying it: PowerShell enumerates a collection on
output, so a `byte[]` returned through a pipeline silently becomes an `Object[]` of boxed bytes with
an identical `.Length`, and uploading that corrupts the file. `InvokeAgilityDownload` guards against
this and a test asserts the returned value really is a `byte[]`.

## Owners and identities

Owners are matched by **email** (emails are not reliably derivable from names). ADO only accepts
`AssignedTo` identities that are members of your organization, so the tool probes each owner (cached
`validateOnly`) and assigns the **first one ADO accepts**, trying each owner then the item's creator.
Owners it can't assign go to `Custom.DigitalAIOwners`. A directory user who is not yet an org member
is rejected by the REST API even though the web picker can assign them (which quietly adds them to
the org); the `MaterializeOwners` helper can add such owners as free Stakeholders up front if you
want them assigned.

## Area paths

Each scope maps to an ADO area path; Stories/Defects add a Theme leaf below it. **The nodes must
exist** or ADO rejects the item (`TF401347`). `CreateAreaPaths` builds exactly the nodes your data
needs (derived live, closed items included) - run it after adding a scope, a `ThemeAreaPaths` entry,
or a `TeamAreaPaths` target, before the migration that needs them.

**`AreaPathRemap` folds the composed path onto a fixed tree.** After the scope and Theme produce a
path, an ordered rule list in `mappings.json` remaps it onto the tree you actually want, so the
migration never creates nodes outside it (`CreateAreaPaths` applies the same remap). Rules carry
their own kind - `Exact`, `Prefix` ("this node or below"), or `Contains` - and are evaluated in
order, first match wins, so a specific exception can be written above a general rule. That ordering
is load bearing: an exact rule for a `Networking - COVID` node has to sit above a `Contains COVID`
rule, or the general rule swallows it. An unrecognised rule kind throws rather than silently matching
nothing. This is applied *after* composition rather than by editing `ThemeAreaPaths`, because a
target can depend on the scope as well as the Theme - the same Theme under two scopes can need two
different destinations.

Resolution order is **scope, then Theme, then Team**. The Team is a last resort: it is consulted only
when an item would otherwise land at the bare project root, which happens when its scope has no area
path of its own and it carries no Theme. `TeamAreaPaths` is matched **exactly**, never by prefix or
substring - team names frequently contain node names (a team called `User Services - Sprint` contains
the node name `User Services`), so a text match looks right and then mis-files the first team named
after something that is not a node. Derive the entries from where each team's work actually lives,
and leave a team out when the data doesn't say; an unmapped team stays at the root, exactly like an
unmapped Theme.
