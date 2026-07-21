# Design: agility-to-azuredevops

Status: Epic, Story, Defect, Task, and Issue are all implemented. The `Migration` project has been
wiped and re-migrated several times as scopes and fields were fixed, so treat every count below as a
snapshot, not a constant, and verify against the live instance before relying on it. `CLAUDE.md`
holds the current operational state; this file is the design reasoning behind it.

## Migration log

**COMPLETE (2026-07-18). All five types, all five scopes, closed items included: 53,450 work items**
in the ADO `Migration` project - 342 Epics, 535 Features, 7,660 Product Backlog Items, 706 Bugs,
43,817 Tasks, 390 Impediments. Every item carries the `Custom.DigitalAI*` fields, a backdated
two-point history (created-by / changed-by), area and iteration paths, and links (parent, Affects).
The 535 Features are all parented; flattened Epics carry a Related link to their true Agility parent;
no Dead template Epics leaked in. Close dates are real historical values.

The Task run took two attempts. The first full run failed all closed Tasks on `TF401320` (Closed Date
Required - see [Close dates](#close-dates)); after the fix, `DeleteAllTasks` cleared them and a Task
re-migration created 43,816 of 43,817, the one miss being `TK-01316` (empty `CreatedBy` VS402625
edge, now fixed in code). See CLAUDE.md `## State` for the current snapshot and the one imperfect
item.

## Goal

Migrate work items one way, from digital.ai Agility (formerly VersionOne) into Azure DevOps,
without ever modifying anything in Agility.

## Tech stack

PowerShell 7, using `Invoke-RestMethod` against both REST APIs. Tests are Pester 5 or later.

An earlier draft of this project specified a .NET 8 console application. That was reversed in
favour of PowerShell, because the existing scripts in this shop are PowerShell and the migration
is a one-off operation rather than a shipped binary.

## Agility is read only

This is a structural guarantee, not an intention. Every Agility call goes through a single
function, `InvokeAgilityGet`, which hard codes `-Method Get`. The function takes no method
parameter, so no caller can turn it into a write. A test asserts both properties against the
script source, so a future edit that adds a write path fails the build.

## The hierarchy problem

Agility Epics nest arbitrarily: an Epic can parent another Epic, to any depth. Azure DevOps
expects a natural hierarchy of Epic, then Feature, then Requirement, then Task.

The important finding is that **Azure DevOps does not reject a same category parent-child link**.
The REST API accepts an Epic parented to an Epic. What follows is silent damage:

- The backlog reports "You can't reorder work items and some work items might not be shown", and
  ordering is disabled for that backlog.
- Sprint backlogs and taskboards render only the leaf node of a same category chain. Intermediate
  items disappear, and Microsoft documents no workaround.

Reference:
[Resolve nest, display, and reorder issues](https://learn.microsoft.com/en-us/azure/devops/boards/backlogs/resolve-backlog-reorder-issues?view=azure-devops)

For a migration tool this is worse than an error. A naive `Epic -> Epic` migration reports every
item created, exits zero, and hands over an unusable backlog. So the hierarchy is resolved on the
client, before any write, by `ResolveEpicHierarchy`:

| Agility Epic depth | ADO type | ADO parent |
|---|---|---|
| 1 (no Epic parent) | Epic | none |
| 2 | Feature | the root Epic |
| 3 or deeper | Feature | the root Epic, flattened, with a warning |

Every Epic below the root becomes a Feature under the root, so no Epic-Epic or Feature-Feature
link is ever created. A test asserts this invariant directly: no item's parent shares its type.

This is not a rare edge case. In the data, **27 of 104 open Epics (26%) sit at depth 3 or 4**.
So flattening alone would discard the real parent of a quarter of the migrated items.

To avoid that loss, a flattened Epic also carries `TrueParentOid`, its real Agility parent, which
is written as:

- a `System.LinkTypes.Related` link to the migrated true parent, with a comment explaining why
- a line in the description footer naming the parent, as in "Agility parent: E-09341"

Related is used rather than the honest Hierarchy-Reverse because Hierarchy-Reverse to the true
parent is exactly the same category link that breaks the backlog. Related is the only lossless
option ADO allows here.

Alternatives considered and rejected:

- **Add portfolio backlog levels to the the Scrum process process.** Would map depth 1 to 4 natively with
  no loss, but the Scrum process is shared by the `IT`, `Migration`, and `Demo` projects, so it would
  reshape the backlogs of live projects.
- **Clone the process for Migration only.** Same benefit without the blast radius, but a heavier
  change than the migration warrants.

## Type mapping (Scrum process)

The target project uses the Scrum process.

| Agility | Azure DevOps |
|---|---|
| Epic (top level) | Epic |
| Epic (nested) | Feature |
| Story (Backlog Item) | Product Backlog Item |
| Defect | Bug |
| Task | Task |

### Bug behavior

`BugBehavior` in `mappings.json` records how the target team tracks bugs, which decides whether a
Task can be linked under a Bug. Azure DevOps will not report this at link time, so it is
configuration rather than discovery.

- `Requirements` (default): Bug sits in the Requirement category. Task under Bug is a cross
  category link, which is legal and renders correctly. This is the faithful mapping of Agility,
  where Defects sit on the backlog and own Tasks.
- `Tasks`: Bug sits in the Task category. Task under Bug would be same category, so those links
  are skipped and warned rather than silently breaking the backlog.

## Field mapping

Driven by `mappings.json` so it changes without editing the script. Epic has 143 attributes; the
counts below are how many of the 104 open Epics carry a value.

| Agility | Azure DevOps | Populated |
|---|---|---|
| Name | System.Title, truncated at 255 | 104 |
| Number | Custom.DigitalAIID and description footer | 104 |
| Status.Name (raw) | Custom.DigitalAIStatus, and mapped to System.State | 12 |
| Super | parent link, plus a Related link when flattened | 77 |
| Scope (+ Theme leaf) | System.AreaPath | 104 |
| Timebox | System.IterationPath, plus a "Sprint" description line | - |
| Owners | System.AssignedTo (first ASSIGNABLE owner), rest to Custom.DigitalAIOwners | 60 |
| CreatedBy / CreateDate | backdated System.CreatedBy/CreatedDate (history rev 1) | 104 |
| ChangedBy / ChangeDateUTC | backdated System.ChangedBy/ChangedDate (history rev 2) | - |
| ClosedDate | Microsoft.VSTS.Common.ClosedDate, inside the closing transition | - |
| Order | Microsoft.VSTS.Common.BacklogPriority | 104 |
| Category | Custom.DigitalAICategory | 32 |
| Custom_FiscalYear | Custom.DigitalAIFY (Epic only in Agility) | 7 |
| Team | Custom.DigitalAITeam, via a value map | 10 |
| Custom_Mandate | Custom.DigitalAIMandate (Epic/Feature) | 4 |
| StrategicThemes | Custom.DigitalAIStrategicTheme (multi-value control, Epic/Feature) | 5 |
| Source (Defect) | agility-source tag | - |
| ResolutionReason | Custom.DigitalAIBugResolution / DigitalAIImpedimentResolution | - |

State, assignee and close date are set in patches after the create (creating directly into a
non-default state often fails process validation, and the assignee is deliberately rule-checked so a
departed identity is rejected rather than stored). See [Close dates](#close-dates) and the two-point
revision history in `docs/superpowers/specs/2026-07-16-two-point-revision-history-design.md`.

### Owners and the assignee

Agility `Owners` is multi value; ADO `AssignedTo` holds one person. So one owner becomes the
assignee and the rest go to `Custom.DigitalAIOwners` (comma separated). Owners are matched to ADO by
**email**, read from `Owners.Email`, because both systems use `example.com` identities; emails are not
derivable from names (`Morgan West` is `morgan.west1@example.com`), so guessing would misassign.

**Which owner becomes the assignee: the first one ADO will actually accept.** The candidates are
every owner's email (in owner order), then every owner's name, then the Agility creator.
`IsAssignableIdentity` probes each with `validateOnly=true`, cached per identity (~104 probes for the
whole migration, not one per item), and the first accepted candidate is assigned. So a departed first
owner is **skipped** for the next assignable owner rather than sinking the item to unassigned. The
one that is assigned is the one excluded from `Custom.DigitalAIOwners`; everyone else, including the
departed ones, is recorded there.

### Owners who are not ADO identities

Many Agility owners are not members of the Azure DevOps organization (departed staff, plus
non-people like `Vendor`). On the Epic/Feature set alone, **32 of 49 distinct owners are rejected**,
including people who are still real - Dana Reyes, Pat Nolan, Casey Ford. The work-item
API rejects them for `AssignedTo` by email **and** by name; only `bypassRules` accepts them, and it
stores a degraded string identity (no linked account, no `@Me`, no notifications), so that is not
used. Such items migrate **unassigned**, with the owner preserved in `Custom.DigitalAIOwners`.

The subtlety the user hit: the web people-picker searches the whole **Entra directory** (so these
people show up and can be assigned in the UI), but the work-item write only accepts identities
**materialized as organization members**. Microsoft's own docs: *"You can assign work items to any
Microsoft Entra member who has permissions for your organization. This action also adds that member
to your organization."* So the UI assigns by **adding them to the org**; the REST write does not do
that add step.

`MaterializeOwners` exists to close that gap on request: it adds each recoverable owner to the org as
a free **Stakeholder** (via `POST vsaex/.../userentitlements`), after which the migration's probe
assigns them by email. It needs a separate token (Member Entitlement Management write scope, owned by
a Project Collection Administrator - the work-item PAT 401s). A truly departed owner (removed from
Entra) cannot be added at all; those stay unassigned by design. The user chose **not** to run it, so
the unassignable owners remain in `Custom.DigitalAIOwners`.

### Fields deliberately not mapped

Of the 143 Epic attributes, about 116 are Agility plumbing: permission booleans (`CanUpdate`,
`CheckSplit`), derived traversals (`SuperMeAndUp`, `SubsAndDown`, all computed from `Super`, which
is mapped), state duplicates (`IsClosed`, `IsDead`, `EffectiveAssetState`), and identity fields
(`Key`, `Moment`, `AssetType`).

Carrying data but intentionally skipped:

- `ChangeComment` (75) and `History`: audit chatter, low value in ADO
- `Attachments` (1), `Links` (3), `Dependencies` (1), `Requests` (2): out of scope
- `DoneDate` (3): the state mapping already conveys Done

`CreateDate` / `CreatedBy` and `ChangeDateUTC` / `ChangedBy` ARE now mapped: they backdate the two
ADO revisions (created-by then changed-by) under `bypassRules`, since Agility's full-history endpoint
`hist-1.v1` is not available on this hosted instance. See the two-point revision history spec.

`Category` is worth noting: its values are Feature (19), Sub-Feature (6), Operational Plan (6),
IT Program (1), so Agility has its own opinion about which Epics are Features. It is populated on
only 32 of 104 open Epics, so it cannot drive the type mapping, and depth is used instead. It goes
to `Custom.DigitalAIWorkItemCategory` (a field the user added), so the disagreement stays visible
and queryable. It was an `agility-category:` tag until 2026-07-16.

## Idempotency

Every created item is stamped twice with its Agility Number:

- a tag, `agility:E-01234`, which drives the skip logic
- a description footer, which survives for a human reading the item later

Before writing, one WIQL query collects every work item in the project, and the ones tagged
`agility:` become a tag to id map. A query per item would be N round trips and would invite
throttling on a real migration.

The tag filter cannot live in the query, and the filter plus the oid to Number bridge that make
this work are both subtle enough to have been wrong for a long time. See
[Finding what is already migrated](#finding-what-is-already-migrated).

Reruns skip anything already in that map, and resolve parent links against it, so a resumed run
links new children to previously migrated parents.

## Parsing

`ConvertFromAgilityAssets` is the only function that knows the `rest-1.v1` wire format. It parses
an `Assets` array, each element carrying an `id` and an `Attributes` dictionary keyed by attribute
name, each attribute holding a `value`.

**This shape is verified** against the live instance (`https://www.v1host.example/YourInstance`), as are
Bearer auth, `page=size,start` paging, and the `AssetState` filter.

Known handling:

- Oids carry an optional moment suffix (`Epic:1234:5678`). It is stripped so the same asset read
  at different moments compares equal.
- Relations such as `Super` hold an object with an `idref` rather than a scalar.
- Multi value attributes hold an array; the first entry is taken.

### Attribute names are per asset type

**Epic has no `Estimate` attribute.** Asking for it returns HTTP 400 "Unknown token: Estimate".
The Epic level estimate in Agility is `Swag`; `Estimate` exists only on Story and Defect. The
parser maps `Swag` onto the `Estimate` property.

This is not a footnote: an attribute a type does not have fails the **whole page**, not the one
field, so a wrong `sel=` list kills that type's entire migration. Hence `GetSelection`, one list
per type, and a test per known trap.

**Defect has no `Category` attribute** either, which cost a second dry run:

```
Invalid SEL parameter: Unknown AttributeDefinition: Defect.Category
```

Its nearest equivalents, `Type` and `DeliveryCategory`, are both empty on all 704 Defects, so
there is nothing to map and the field is simply absent from the Defect list. `Source` is the one
Defect-specific classifier carrying data (23 of 704: "Employees", "Student: Traditional"), and it
goes to the description's Agility details block as "Source: ..." (it was an `agility-source:` tag
until 2026-07-16). `Category` stays on Epic, Story, and Issue, which do have it, and lands in
`Custom.DigitalAIWorkItemCategory`; a Defect's field is left empty.

**Issue is a `BaseAsset`, not a `Workitem`.** It has no `Super`, `Estimate`, `Timebox`, or
`Priority`, and its owner is the singular `Owner`, not `Owners`. Its selection reflects that.

`AssetState` filters on the state name, not the number. `AssetState!='Closed'` works;
`AssetState=64` is an HTTP 400 and `AssetState!='128'` silently matches nothing.

`AssetState` filters on the state name, not the number. `AssetState!='Closed'` works;
`AssetState=64` is an HTTP 400 and `AssetState!='128'` silently matches nothing.

### AssetState and the Dead templates

Agility `AssetState` on the Epics: **64 Active** (104), **128 Closed** (754), **200 Dead** (18).

The 18 Dead Epics are placeholder templates, not deleted work: "IT - Registration Checklist -
`<insert semester>`", "Data Warehouse `< Insert Business Unit >`", "BLDG Classroom XXXX - update".
They must never migrate.

The default filter `AssetState!='Closed'` happens to exclude them, because it returns only state 64.
But `-IncludeClosed` originally dropped the where clause entirely, which would have migrated all 18.
`-IncludeClosed` therefore filters `AssetState!='Dead'` rather than passing no filter: that returns
Active plus Closed and never the templates.

There is no code path that queries Epics with no `AssetState` filter, and a test asserts it.

### State comes from AssetState, not Status

`AssetState` wins over `Status`. An Epic closed in Agility is finished regardless of what its
Status says, and Status is unreliable on closed items: of the 754 closed Epics, **385 have no
Status at all** and **6 still say "In Progress"**.

Mapping on Status alone would recreate 393 finished Epics in Azure DevOps as active work. So
`MapState` checks `IsAgilityClosed` first and returns `States.ClosedState` (Done). `AssetState` is
compared as text, because it arrives as a number and a string comparison cannot silently fall
through and mark a closed Epic active.

## States are per work item type

ADO states are not global, and `mappings.json` keys them per Agility type:

| ADO type | States |
|---|---|
| Epic, Feature | New, In Progress, Done, Removed |
| Product Backlog Item, Bug | New, **Approved**, In Progress, Done, Removed |
| Impediment | **Open, Closed** only |
| Task | **To Do**, In Progress, Done, Removed |

Confirmed against `workitemtypes/{type}/states`, not assumed. `Approved` does not exist on an Epic
and `Done` does not exist on an Impediment, so a single shared state map cannot work.

**Impediment cannot be created as `Closed`.** ADO restricts `System.State` on create to states in
the **Proposed** category, and Impediment has none: `Open` is InProgress and `Closed` is Completed.
Creating one as Closed fails with "the value 'Closed' is not in the list of supported values", so
Closed is only reachable as a transition.

This is why `SetAdoState` creates in the default state and moves the item afterwards. The comment
there used to claim that creating directly into a non default state "often fails process
validation", which is simply false: every type here accepts every one of its own states on create.
Impediment is the real reason, and it is reason enough. The other types share the path so there is
one code path rather than two.

Before writing anything, `AssertStatesExist` checks every state in `mappings.json` against what ADO
reports for that type. The create payload carries no state, so `validateOnly` never sees one, and a
typo would otherwise surface as a failed transition on item one of several thousand, after its
create had already succeeded, leaving a half migrated item behind.

## Close dates

`Microsoft.VSTS.Common.ClosedDate` is auto-stamped by the Scrum process from the server clock on
entry to a closed state, so the real Agility date has to be forced in. It is written **inside the
state transition**, in the same `bypassRules` patch that sets the state:

- `bypassRules` is required because the field is read-only under normal rules (the process owns it).
- It goes on the transition, not a later call, because it must be present **before the next
  rule-checked patch** touches the item. This is the subtle part, and it cost a whole run to learn.

**What went wrong first.** The revision history (below) made the transition a `bypassRules` patch, to
attribute the changer. `bypassRules` skips the rule that auto-stamps Closed Date, so a closed item
sat in its closed state with an **empty** Closed Date. That was fine until the very next rule-checked
patch - the assignee - re-validated every rule and rejected it:

```
TF401320: Rule Error for field Closed Date. Error code: Required, ReadOnly, SetByRule,
SetByDefaultRule, InvalidEmpty.
```

**Only Task's `Done` state *requires* a Closed Date**, so only Tasks failed - all 30,928 closed ones
in the first full run. Story/Defect/Issue/Epic allow an empty Closed Date and came through clean.
Proven on throwaways: a bypass transition to Done with an empty Closed Date, followed by any
rule-checked patch, fails; with the Closed Date set in the transition, it passes.

**The fix.** `SetAdoState`, when `IsClosedAdoState $epic $state`, adds the Closed Date to the same
bypass patch:

- the real Agility `ClosedDate` when present;
- for a closed **Task** with no Agility date, a fallback of `ChangeDate` then `CreateDate`, because
  Task's Done cannot be left empty;
- for other closed types with no date, nothing - an empty Closed Date is the correct "Agility had no
  real date" state, and `bypassRules` never auto-stamps a fake one, so there is nothing to clear.

The separate `SetAdoClosedDate` correction call (which used to overwrite the server-clock stamp, or
`op=remove` it) is **gone**: with a bypass transition there is no auto-stamp to correct.

`bypassRules` is no longer confined to one call - the history needs it on the backdated create and
transition too. The guarantee that replaces "one call site" is that **`System.AssignedTo` never
travels in a `bypassRules` payload**: bypass skips identity validation, so a departed owner on a
bypass write would be stored as an unresolvable identity instead of being rejected. The assignee is
set only by `SetAdoAssignee`, a rule-checked patch. A test asserts it.

## Field limits

`System.Title` is capped at 255 characters in ADO. Agility `Name` has no cap, and three Epics
carry a whole paragraph as their name, the longest being 391 characters. `BuildTitle` truncates to
255 and `BuildDescription` preserves the untruncated name at the top of the description, HTML
encoded. Without this, those three Epics fail on create.

## Scopes and area paths

`appsettings.json` lists scopes, each with the area path its Epics land in. The area path is
stored relative to the project; `FormatAreaPath` prefixes the project name, so `IT\Operations`
becomes `Migration\IT\Operations`.

| Agility scope | Name | ADO area path |
|---|---|---|
| `Scope:84332` | Information Technology | `Migration\IT` |
| `Scope:1547` | Information Technology OPS | `Migration\IT\Operations` |
| `Scope:2463` | IT - User Services - Operational | `Migration\IT\User Services` |

All configured scopes migrate in a single run by default. This is deliberate: Epic parents cross
scope boundaries, and only a whole set run resolves every link. `-Scope` narrows to one configured
scope, which is useful for testing but will leave cross scope parents unresolved.

## Entry point

The script takes no parameters. `Main` calls `Migrate` with switches, and the operator edits those
calls. This matches the existing scripts in this shop, where `Main` holds the settings and the
functions below it do the work. Config paths are hard coded rather than passed in.

`Migrate` copies its switches into script scope, because the helper functions read them from
there. It also resets the counters, so `Main` can call it more than once, and it never calls
`exit` for the same reason.

The three scopes above are the Agility root plus its two direct children. The other two scopes,
`Scope:2482` and `Scope:16163`, are descendants holding no open Epics, so nothing is lost by
omitting them.

Area paths must already exist in ADO. The script never creates them, because that would make
`-DryRun` write to ADO and break the guarantee that a dry run changes nothing.

## Secrets

Two values are secret: the Agility access token and the Azure DevOps PAT. Everything else
(instance URL, scope, organization, project) lives in `appsettings.json`, which is gitignored.

Resolution order is environment variable first, then Windows Credential Manager via
`Get-StoredCredential`. The environment wins so a pipeline can inject a token where no credential
store exists; the credential store is the local default, matching existing scripts in this shop.

Note that the `CredentialManager` module is Windows only and unmaintained since roughly 2016. The
environment variable path is the escape hatch if it ever stops working.

## Resilience

`InvokeWithRetry` retries 429 and 5xx three times with exponential backoff. Other status codes
fail immediately, because retrying a 401 or a 400 only wastes time. A single item failure logs and
continues. The run exits non zero if any item failed.

## Dry run

`-DryRun` reads Agility, resolves the hierarchy, queries ADO for already migrated items, prints
what it would create, and writes nothing.

It also asks ADO to **validate every payload**, via `POST .../workitems/${type}?validateOnly=true`,
which checks fields against the real process without persisting anything. Without this a dry run
only proves Agility can be read, and the first real create is the first time ADO ever sees a field
value. The validation immediately found five Epics ADO would reject on an unknown identity.

The dry run deliberately mirrors the real path's fallbacks: an unknown identity is re-validated
without the assignee and reported as a warning, because that is what a real run does. A dry run
that reported a failure where the real run succeeds would be worse than saying nothing.

`BuildFieldPatch` is shared by the validation and the real create on purpose. If they built
different payloads, the dry run would be validating something other than what gets written.

Relations are omitted from validation, because a dry run has no real parent id to point at. So the
dry run proves the fields, not the links.

Validation costs one HTTP call per item, so a dry run runs at roughly the speed of a real one. For
the 104 open Epics that is around a minute; with `-IncludeClosed` (858 Epics) it takes several
minutes. That is the price of knowing the payloads are good before writing.

## Testing

The pure functions (`ConvertFromAgilityAssets`, `ResolveEpicHierarchy`, `BuildTags`, `BuildTitle`,
`FormatDate`, `FormatAreaPath`, `ReadAdoError`) take data and return data with no I/O, so they test
directly against fixtures. The read only guarantee is tested against the script source.

Not yet covered: an end to end run with a mocked `Invoke-RestMethod`, which would exercise paging,
ordering, and the skip path.

## Iterations, from Agility Timeboxes

`Timebox` is Agility's sprint. Stories and Defects reference **142 distinct timeboxes**, all from
the single `Org - 3 weeks` schedule. All 142 were created as iteration nodes directly under
`Migration`, with their real start and end dates (Sprint 001 in 2018 through Sprint 142 in 2026).

Two traps here:

**Timebox names are not unique instance wide.** There are 295 timeboxes but only 219 distinct
names: `Sprint 1` exists 7 times, across different schedules. ADO iteration nodes must be unique
under a parent. This is safe only because every timebox our items reference comes from one
schedule, so all 142 names are unique and none collide with the default `Sprint 1-6`. **Migrating
another scope, or another schedule, would collide** and would need the schedule name as a parent
node (`Migration\Org - 3 weeks\Sprint 138`).

**Iteration dates need full ISO 8601.** `"startDate": "2026-08-26"` is **silently ignored**: the
API returns HTTP 200 and creates the node with no dates at all. `"2026-08-26T00:00:00Z"` persists.
Both look identical unless the node is re-read, so always verify dates after writing them. Dates
also cannot be set on the create call reliably; they are applied with a follow up PATCH.

## Themes: the area path source for Stories

**Story has two independent parent axes**, and this is the single most important finding for the
Story phase:

- `Story.Super` -> the **Epic** it belongs to. This becomes the ADO parent link.
- `Story.Parent` -> the **Theme** it belongs to. This is the natural **area path** source.

`Theme` is a real work item (base `Workitem`, numbered `TH-01017`), not a dropdown. Epics never use
Themes: **0 of 876 Epics** have a Theme parent. Stories use them constantly: **288 of 289** open
Stories in `Scope:1547`.

The Themes in use map onto the area paths already created in ADO:

| Agility Theme | Open stories | ADO area path |
|---|---|---|
| Applications | 160 | `Migration\IT\Operations\Apps` |
| Systems | 96 | `Migration\IT\Operations\System` |
| Networking | 32 | `Migration\IT\Operations\Networking` |
| Audio Visual | 17 | `Migration\IT\User Services\AV` |

So the deeper area paths, which the Epic migration never fills, are for Stories, mapped from Theme.

Caveats for that phase: `Scope:2463` themes only 17 of 112 open Stories, and 98 open Stories across
all scopes have no Theme at all. Theme to area path needs a fallback to the scope's own area path,
and the Theme name does not match the area node name exactly (Applications vs Apps, Systems vs
System), so it needs a map in `mappings.json` rather than a string match.

`DevOps`, `Help Desk`, and `Technical Services Support` have no matching Theme, so they stay empty
unless populated another way.

## Finding what is already migrated

Reruns and cross-run parenting both depend on one question: which Agility items are already in
Azure DevOps? `GetMigratedTagMap` answers it once per run, by reading the `agility:<Number>` tags.

The obvious query is wrong, and wrong in the worst way:

```sql
-- Returns ZERO rows. Not an error. Zero rows.
SELECT [System.Id] FROM WorkItems
WHERE [System.TeamProject] = 'Migration' AND [System.Tags] CONTAINS 'agility:'
```

WIQL matches `System.Tags` **a whole tag at a time**. `CONTAINS 'agility:E-06527'` finds that one
item, but `'agility:'` matches nothing, and neither does `'agility'`. There is no prefix or
wildcard form: `CONTAINS WORDS 'agility*'` also returns nothing, and `IS NOT EMPTY` is rejected
outright for Tags (`VS403465`).

Because it fails as an empty result rather than an error, nothing complained. The map was empty on
every run, which silently broke both things it exists for:

- **Reruns were never idempotent.** Every item looked unmigrated, so a second Epic run would have
  created 858 duplicates. The README advertised the opposite.
- **Stories could not find their Epics.** The Epics were migrated in an earlier run, so every
  Story would have been created with no parent link, and the Epic migration's whole point, the
  hierarchy, would not have survived into the Story phase.

The Epic run itself was unaffected, which is why this went unnoticed: `MigrateItem` adds each item
to the map as it creates it, so Feature-to-Epic links resolved from the in-run map. The bug only
bites across runs.

The fix is to select every work item in the project and match the tags on the client, where
`-like 'agility:*'` means what it says. That reads more rows than the tagged subset, but the target
is a migration project, and a correct answer beats a cheap wrong one. Verified against the live
instance: 0 entries before, 858 after.

### The tag map is only half of it

Loading 858 tags still parented nothing. `ResolveMigratedId` turns a parent **oid** into the
`agility:<Number>` tag it looks up, and it does that through `$script:numberByOid`, which is only
filled from the items read in the current run. A Story's Epic was migrated by an earlier run, so it
is not in that map: the lookup missed, `ResolveMigratedId` returned `$null`, and the Story would
have been created with no parent and no error.

The two bugs disguised each other. Fixing the tag map alone changes nothing observable, so it would
have been easy to declare victory on "858 previously migrated items found" and ship Stories with no
hierarchy at all.

The Story knows its own Epic's Number, so nothing needs loading: `Super` gives the oid and
`Super.Number` gives `E-01330`. `MigrateWorkitems` bridges the two before migrating, which makes
`ResolveMigratedId` work unchanged and the dry run print the real parent instead of a blank.

This matters at scale: **4,526 of 7,568 Stories and 323 of 704 Defects have a Super**, so roughly
4,849 parent links were at stake.

## Parents outside the configured scopes

When an item's parent Epic lives in a scope that is not in `appsettings.json`, that Epic is not in
ADO, so the link cannot be made and the item is created unparented. That is correct: an item cannot
link to a work item that does not exist. The parent Number survives as an `agility-parent:<Number>`
tag, so nothing is silently lost and the link can be made later if that scope is ever migrated.

The original example was `.edu conversion`: 24 Stories and 3 Defects pointed at six Closed Epics
(`E-02578`, `E-02580`, `E-02581`, `E-02582`, `E-02588`, `E-02639`) in a scope that was not
configured. That scope **is** configured now (`Scope:16163`), so those particular items resolve when
everything migrates together; the mechanism remains for any scope still left out. Adding a scope does
**not** retro-link items migrated before it existed, though: a rerun skips them, so the tag stays the
only record until they are recreated.

### The dry run used to overstate this

The dry run printed `parent E-01330` whenever the item had a `Super`, which reads as "the hierarchy
resolved". It did not mean that. The number came from `numberByOid`, but the **link** comes from
`ResolveMigratedId`, which returns null for an Epic that was never migrated. The two were never the
same thing, and the output showed the one that always succeeds.

That is how "4,525 parents resolved" got reported when the real figure was 4,501 links and 24
unparented items. A dry run that overstates what a real run will do is worse than one that stays
quiet, because it is trusted. It now prints the actual outcome:

```
[parent E-03685 -> #1201]                          the link will be created
[parent E-02588 NOT IN ADO, would be unparented]   it will not
```

## Owners arrive as a list, always

`OwnerEmails` and `OwnerNames` are always arrays, even for one owner, and the outer `@()` around
the `if` that builds them is load bearing:

```powershell
# Wrong. An if used as an expression emits to the output stream, which unrolls a one element
# array back to a scalar.
$ownerEmails = if ($type -eq 'Issue') { @(GetAttributeValues $a "Owner.Email") }
               else { @(GetAttributeValues $a "Owners.Email") }

# Right.
$ownerEmails = @(if ($type -eq 'Issue') { GetAttributeValues $a "Owner.Email" }
                 else { GetAttributeValues $a "Owners.Email" })
```

The inner `@()` looks sufficient and is not. With one owner the property became the bare string
`"jsmith@example.com"`, so `OwnerEmails[0]` returned `"j"`. ADO rejects `j` as an unknown identity, and
the existing retry then created the item unassigned with only a warning. Items with two or more
owners were unaffected, which is what made it hard to see: the failure hid on exactly the common
case, and looked like an identity problem rather than a parsing one.

A test pins each shape: one owner, one Issue owner (singular `Owner`), several owners, and none.

## The strategy layer above Epic

There is **no type above Epic** in Agility. `Epic.Super` points at `Epic`, so nested Epics *are*
the portfolio hierarchy. There is no `Initiative` asset type in the instance. This is why ADO's two
portfolio levels cannot hold a 4 level Agility tree, and why adding an ADO backlog level above Epic
would be inventing structure Agility does not have.

Beside Epic sits a strategy layer, associated many to many rather than as a parent:

| Type | Base | Assets | Linked to the 104 open Epics |
|---|---|---|---|
| `StrategicTheme` | BaseAsset (real asset) | 46 | 5 |
| `Goal` | BaseAsset (real asset) | 127 | 0 |
| `OkrObjective`, `Roadmap`, `ValueStream` | - | 0 | unused |

`StrategicTheme` and `Goal` are real assets, not picklists, but they attach many to many, so they
cannot be a portfolio level. `StrategicThemes` goes to the description's Agility details block as
"Strategic theme: ..." (it was an `agility-theme:` tag until 2026-07-16). The 127 Goals are stale
FY21 College Relations items with no scope and no link to IT work.

Distinguishing a real asset from a dropdown: check the `Base` in `meta.v1/{Type}`. `Workitem` or
`BaseAsset` with a `Number` is a real asset. `List` or `Status` with no `Number` is a picklist:
`EpicCategory`, `EpicPriority`, `EpicStatus`, `StrategicThemeLevel` are all dropdowns, which is why
they map to tags and fields rather than work items.

## Out of scope

Attachments, comments, and history. Reverse or two way sync. Test and TestSet asset types. Any UI.
