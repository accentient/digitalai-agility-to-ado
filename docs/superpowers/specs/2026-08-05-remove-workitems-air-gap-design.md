# Remove-WorkItems.ps1: an air gap between deleting and creating

Date: 2026-08-05

## Problem

`Migrate-Agility.ps1` creates work items in Azure DevOps and also permanently destroys them. The
six `DeleteAll<Type>` helpers, `DeleteAllOfType` and `GetAllIdsOfType` live in the same 3,957 line
file as `NewAdoWorkItem`, `SetAdoState` and every other write path, share its `Main`, its script
scope and its plumbing.

That is one file where a careless edit can turn a migration into a deletion. The destroy is
`destroy=true`, so there is no recycle bin and no recovery, and the largest single target is 44,030
Tasks. The two capabilities want physical separation, not just separate functions.

## Decision

Move deletion into its own script, `src/Remove-WorkItems.ps1`, that is **fully self-contained**.
Neither script dot-sources the other, neither names the other, and no third file is shared between
them. The ~200 lines of plumbing (config, secrets, ADO request, retry, logging) are duplicated
rather than shared.

Rejected alternatives:

- **A shared `src/Common.ps1` both scripts dot-source.** No duplication, but the two scripts then
  share a blast radius: an edit made for the migrator changes delete behaviour. That is an air gap
  in naming only.
- **`Remove-WorkItems.ps1` dot-sources `Migrate-Agility.ps1` with the load-functions-only flag.**
  Least code, and the worst outcome: the delete script would load every migration write path into
  memory to reuse five helpers.

The cost accepted is that a plumbing bugfix has to be applied in two places. The plumbing is stable
(unchanged since the retry hardening on 2026-08-04) and small, so the trade is worth it.

## Architecture

`src/Remove-WorkItems.ps1`, house style throughout: banner block, `Main` at the top, `Main` invoked
at the bottom behind an explicit global flag, Allman braces, 2 space indent, PascalCase functions,
no `param()` block and no CLI switches.

| Section | Functions |
| --- | --- |
| Control panel | `Main` - commented-out menu of `DeleteAll*` calls, `-DryRun` variants first |
| Delete | `DeleteAllEpics`, `DeleteAllFeatures`, `DeleteAllProductBacklogItems`, `DeleteAllBugs`, `DeleteAllTasks`, `DeleteAllImpediments` |
| | `DeleteAllOfType` - the one destroy loop, guarded by the `$script:DeletableAdoTypes` whitelist |
| | `GetAllIdsOfType` - `System.Id` watermark paging, past the 20,000 row WIQL cap |
| Logging | `StartLog`, `StopLog`, `WriteLog`, `WriteLogDetail`, `AppendLog`, `WriteErrorDetail` |
| Config | `GetConfig`, `GetSecret`, `BuildAdoHeaders` |
| Plumbing | `InvokeAdoRequest`, `InvokeWithRetry`, `IsTransientFailure`, `ResolveRetryDelay`, `ReadAdoError` |

Behaviour carried over unchanged: the whitelist throw on an unrecognised type, `destroy=true`,
`-DryRun` on every wrapper, progress every 500 items, the deleted/failed summary block, and
`$script:totalFailed` turned into an exit code at the bottom of the script.

### Four deliberate differences from the code being moved

1. **The log is `logs/Remove-WorkItems-<yyyyMMdd-HHmmss>.log`.** A delete run must never be
   mistaken for a migration run in a directory that already holds dozens of the latter.
2. **The entry guard flag is `$global:RemoveWorkItemsLoadFunctionsOnly`.** Reusing
   `AgilityEpicsLoadFunctionsOnly` would let one script's test suite suppress the other's `Main`.
3. **`IsTransientFailure` drops the `IsCircularLinkProblem` exclusion.** That exists because ADO
   returns a rejected dependency link as a non-transient HTTP 500. A delete never writes a link, so
   copying the check would import a concept this script has no use for.
4. **No Agility code at all.** No `BuildAgilityHeaders`, no `AGILITY_ACCESS_TOKEN`, no
   `InvokeAgilityGet`, no `rest-1.v1`. The delete script has no door to Agility to misuse.

No confirmation prompt is added. `-DryRun` stays the only guard, as today: parity was the
requirement, and the style rules bar interactive prompts.

## What leaves Migrate-Agility.ps1

- The whole `DeleteAllTasks` banner section: `$script:DeletableAdoTypes`, the six wrappers,
  `DeleteAllOfType`, `GetAllIdsOfType`.
- The delete paragraph from `Main`'s commented menu, replaced by a one line pointer at the new
  script.
- The `Delete helpers` Describe block in `tests/Migrate-Agility.Tests.ps1`.

Nothing else in the migrator calls any of it, so the removal is clean.

## Testing

`tests/Remove-WorkItems.Tests.ps1`, Pester 5, hermetic. `GetConfig`, `BuildAdoHeaders`, `StartLog`,
`WriteLog` and `WriteLogDetail` are all mocked, because an earlier version of these tests resolved
real credentials, queried the live project and left stray files in `logs/`.

The seven existing delete tests port across unchanged in intent:

- sends a work item type filter for every wrapper, and the right one
- never matches another type
- throws on an unknown type rather than querying without a real filter
- always scopes to the configured project as well as the type
- destroys rather than recycling
- deletes nothing on a dry run
- walks every item with a `System.Id` watermark, and asks for ids above the last one it saw
- handles a type name with spaces

Four new tests pin the air gap itself, which is otherwise invisible from the outside:

| Assertion | Why |
| --- | --- |
| `Remove-WorkItems.ps1` names no other script and dot-sources nothing | the gap is the whole point |
| `Remove-WorkItems.ps1` contains no Agility reference | it cannot reach the read-only system at all |
| `Migrate-Agility.ps1` contains no `destroy=true`, no ADO Delete call, no `DeleteAll*` name | the migrator cannot destroy |
| `Migrate-Agility.ps1` does not reference `Remove-WorkItems` | one way, both ways |

Verification is `Invoke-Pester -Path tests -Output Detailed` passing across both files. Nothing in
the suite touches the live project.

## Documentation

`README.md` (the delete helper section) and `CLAUDE.md` (the Commands section) both describe the
`DeleteAll*` helpers as part of `Migrate-Agility.ps1`. Both repoint at `./src/Remove-WorkItems.ps1`,
and the air gap is recorded as a hard rule so a later change does not quietly undo it.
