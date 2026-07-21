# Two-point revision history

Give each migrated ADO work item a backdated revision history that reflects what Agility actually
records: who created it and when, and (when different) who last changed it and when. Not full
field-level history, which this instance cannot provide.

## Why two points, not full history

Agility's `hist-1.v1` endpoint, the only one that streams every revision of an asset, returns 404
across the board on the hosted instance (`www.v1host.example/YourInstance`): bare root, per-type,
per-oid, Epic and Story alike. The historical store exists (an `asof=<date>` read on `rest-1.v1`
returns a moment-stamped snapshot), but there is no way to enumerate *when* the changes happened
without `hist-1.v1`, so reconstruction would mean binary-searching dates per item, which is
imprecise and infeasible across 43k+ Tasks.

What every asset does expose, on both `rest-1.v1` and `query.v1`:

- **Creation:** `CreatedBy.Name` / `CreatedBy.Email` / `CreateDate` (already read for the assignee
  fallback).
- **Last modification:** `ChangedBy.Name` / `ChangedBy.Email` / `ChangeDateUTC`.

Two honest points. That is the whole feature. No intermediate state or author is ever invented.

## The core constraint

A dated timeline requires **rev 1 itself to be in the past**. ADO enforces `VS402625: Dates must be
increasing with each revision`, so once a normal (rule-checked) create stamps rev 1's `ChangedDate`
to *now*, no later revision can be backdated before it. Backdating `CreatedBy`/`CreatedDate` *after*
a normal create was tested and **silently ignored** (HTTP 200, values unchanged): creation cannot
move into the past once it exists.

Therefore rev 1 must be created with `bypassRules`, carrying its historical dates from the start.
This was verified end to end: a bypass create dated 4/23/2026 followed by a bypass patch dated
5/15/2026 (by a departed identity) produced exactly two revisions with the right authors and dates.

### Why this is safe for identities

A bypassRules create **skips identity validation**: it accepts a departed `AssignedTo`
(`jordan.blake@example.com`) and stores it as an unresolvable identity. That would defeat the user's
decision to migrate departed-owner items *unassigned* rather than to a dead identity.

The resolution: **`AssignedTo` never appears on the bypass create.** It is set afterward through a
separate **rule-checked** patch, which validates the identity exactly as today. A departed identity
is rejected there, caught, and the item is left unassigned with the owner recorded in the
description, reusing the existing fallback. The create carries backdated content and no identity
risk; the assignee carries validation and no date requirement.

## The revision story per item

1. **rev 1 (bypass create, backdated to `CreateDate`):** `System.CreatedBy` / `System.CreatedDate` /
   `System.ChangedBy` / `System.ChangedDate` all set to creator @ create date. Item in its default
   state. All content fields (title, description, area/iteration path, custom fields, tags, business
   value, etc.). **No `System.AssignedTo`.**
2. **rev 2 (bypass patch, backdated to `ChangeDateUTC`)** - only when the item was modified after
   creation (`ChangeDateUTC` > `CreateDate`, or a different `ChangedBy`): `System.ChangedBy` = last
   modifier (departed identities are fine here, since this is bypass and never touches `AssignedTo`),
   carrying the item into its final mapped state. This is the state-transition call that
   `SetAdoState` performs today, now backdated and attributed.
3. **rev 3 (rule-checked patch, "now"):** sets `System.AssignedTo` to the resolved assignee.
   **Skipped entirely when `ResolveAssignee` returns null** (nobody to assign) - no empty revision
   is created. If ADO rejects the identity, catch and leave unassigned; the owner is already
   recorded in the description by `BuildAgilityDetails`. `ChangedDate` here is migration-time, which
   is >= rev 2's date, so monotonicity holds. Its `ChangedBy` is the migration account, which is
   accurate: the migration is what assigned it.
4. **Closed-date correction (bypass), unchanged:** `SetAdoClosedDate` still writes or clears
   `Microsoft.VSTS.Common.ClosedDate` after the item reaches a closed state.

### Degenerate cases

- **Never modified after creation** (`ChangeDateUTC` == `CreateDate` and same person) **and the
  mapped state is the default state**: no rev 2, nothing to transition. If the mapped state differs
  from the default (e.g. a closed item), rev 2 is still needed purely for the state transition; it
  is dated at `ChangeDateUTC` (the real close moment) and attributed to the last changer.
- **Impediment cannot be created Closed** (only Proposed-category states are legal on a normal
  create). Under bypassRules this restriction may lift, but the safe path is unchanged: create in
  Open, then a backdated bypass transition to Closed as rev 2.
- **Item with no creator and no change data:** falls back to today's behavior (create-time dates).
  Should not occur - every asset has a `CreateDate` - but the code must not throw on a null.

## What changes in the code

- **Hard rule revised.** "`bypassRules` belongs to `SetAdoClosedDate` and nowhere else" becomes:
  bypassRules owns the backdated create, the backdated last-modified/state revision, and the
  closed-date correction. Identity safety is preserved not by rule-checking the create but by
  routing `AssignedTo` through its own rule-checked patch. The test that asserts a single
  `bypassRules` call site is replaced by one asserting `AssignedTo` is never sent on a bypass call.
- **Parser** already exposes `CreatedByName`/`CreatedByEmail`; add `ChangedByName` / `ChangedByEmail`
  / `ChangeDate` (from `ChangeDateUTC`).
- **`GetSelection`** `$common` gains `ChangeDateUTC,ChangedBy.Name,ChangedBy.Email`. Verified live to
  select cleanly on Epic, Story, Defect, Issue, Task (they are BaseAsset attributes).
- **New building block** (working name `BuildCreateFields` / `BuildHistoryHeader`): produces the
  backdated `System.CreatedBy/CreatedDate/ChangedBy/ChangedDate` ops for rev 1, and the
  `ChangedBy/ChangedDate` ops for rev 2. A person resolves to an ADO identity string the same way
  `ResolveAssignee` does (email preferred), but here a departed identity is acceptable because
  bypass accepts it and no validation is wanted.
- **`MigrateItem` reorders:** bypass-create (backdated, no assignee) -> optional backdated
  last-modified/state rev -> rule-checked assignee patch -> closed-date correction. The create no
  longer carries `AssignedTo`; `SetAdoState` folds into rev 2.
- **`FormatDate`** already emits the ISO 8601 `...ss'Z'` form ADO needs and pins Kind to Local; it
  is reused for `CreateDate` and `ChangeDateUTC`. `ChangeDateUTC` is already UTC (the `Z` suffix in
  its name), so confirm it is not double-converted - it may need a UTC-aware branch or to be passed
  through untouched.

## Scale

Net writes per item are about the same as today, +1 for the assignee split (`AssignedTo` moved out
of the create into its own patch) and +1 only when the item was modified after creation (rev 2,
which today is the `SetAdoState` call anyway - so often +0 net there). Across 43k Tasks this is a
real but not step-change increase, governed by the existing retry policy (3 attempts at 2s/4s).
Reruns stay safe: `GetMigratedIdMap` still matches migrated items and `MigrateItem` still skips
them.

## Testing (TDD)

- Parser reads `ChangedByName`/`ChangedByEmail`/`ChangeDate` from a fixture.
- `GetSelection` asks every type for `ChangeDateUTC` and `ChangedBy.*`.
- The history-header builder emits backdated `CreatedBy/CreatedDate/ChangedBy/ChangedDate` for rev 1
  from `CreatedBy*` + `CreateDate`.
- A person with only a name resolves to the name; email preferred when present; departed identities
  pass through unchanged (no validation here).
- No rev 2 is produced when `ChangeDate` == `CreateDate`, the changer equals the creator, and the
  mapped state is the default state; rev 2 IS produced (dated at `ChangeDate`) when a state
  transition is needed even if nothing else changed.
- The assignee patch is skipped when `ResolveAssignee` returns null (no empty revision).
- **`AssignedTo` is never present in any bypassRules payload** (the replacement for the single-call-
  site test). Assert it appears only in a non-bypass patch.
- The assignee patch still falls back to unassigned on an identity rejection, leaving the owner in
  the description.
- Dates flow through `FormatDate`; `ChangeDateUTC` is not double-converted.

## Out of scope

- Full field-level history (unavailable on this instance).
- Backfilling the 858 already-migrated Epics: they would need re-migration to gain history. Decide
  separately; do not backfill without the user's word, consistent with the close-date decision.
