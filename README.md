# agility-to-azuredevops

A PowerShell tool that migrates work items one way, from [digital.ai Agility](https://digital.ai/products/agility/) (formerly VersionOne) into [Azure DevOps](https://azure.microsoft.com/en-us/products/devops). It reads from Agility and creates work items in an Azure DevOps project, preserving hierarchy, links, history, and traceability.

Agility is only ever read from. Every Agility call goes through a single function that hard codes `-Method Get`, so the tool has no code path that can modify anything in Agility. A test asserts this.

## What it does

- Migrates Epics, Stories, Defects, Tasks, and Issues from an Agility instance via its REST API.
- Maps Agility work item types, fields, states, and links to their Azure DevOps equivalents.
- Preserves the **hierarchy** (parent/child), **Affects** links, area and iteration paths, and a **backdated two-point revision history** (created-by and last-changed-by, at their real dates).
- Records each item's Agility number in a custom field, so reruns are **idempotent** and resumable.
- Always validates a payload with a `-DryRun` (`validateOnly=true`) before writing.

## Work item type mapping

| digital.ai Agility | Azure DevOps (Scrum) |
|---|---|
| Epic (Portfolio Item), top level | Epic |
| Epic (Portfolio Item), nested | Feature |
| Story (Backlog Item) | Product Backlog Item |
| Defect | Bug |
| Task | Task |
| Issue | Impediment |

Field, state, and value-map configuration lives in `mappings.json` and can be customized without editing the script. States are keyed per type, because ADO's states are per type (an Impediment has no `Done`; an Epic has no `Approved`).

## Field mapping (overview)

| Agility | Azure DevOps |
|---|---|
| `Name` | `System.Title` (truncated at 255; full text kept in the description) |
| `Number` | `Custom.DigitalAIID` (drives idempotency) and a description footer |
| `Description` | `System.Description` (HTML passed through) |
| `Status` | `System.State` per type (closed-in-source lands closed); raw status kept in `Custom.DigitalAIStatus` |
| `Super` | parent link (Related link when flattened) |
| `Scope` + `Theme` | `System.AreaPath` (scope path + Theme leaf; Tasks inherit their parent's Theme) |
| `Timebox` | `System.IterationPath` |
| `Owners` | `System.AssignedTo` (first *assignable* owner); the rest to `Custom.DigitalAIOwners` |
| `CreatedBy`/`CreateDate`, `ChangedBy`/`ChangeDate` | backdated `System.CreatedBy/CreatedDate` and `ChangedBy/ChangedDate` (two-point history) |
| `ClosedDate` | `Microsoft.VSTS.Common.ClosedDate`, written inside the closing transition |
| `Order` | `Microsoft.VSTS.Common.BacklogPriority` |
| `Category`, `Custom_FiscalYear`, `Team`, `Custom_Mandate`, `StrategicThemes`, `ResolutionReason` | `Custom.DigitalAI*` fields (see `mappings.json` `CustomFields`) |
| unmigrated parent / blocked item / Defect source | `agility-parent:` / `agility-blocks:` / `agility-source:` tags |

`docs/design.md` has the full field audit and the reasoning behind these decisions.

### Why nested Epics become Features

Agility lets an Epic parent another Epic, to any depth. Azure DevOps does **not** reject an Epic parented to an Epic - it accepts the link and then [silently breaks the backlog](https://learn.microsoft.com/en-us/azure/devops/boards/backlogs/resolve-backlog-reorder-issues?view=azure-devops): reordering is disabled and intermediate items vanish from sprint backlogs. Because there is no error to catch, the tool resolves the hierarchy before writing: every Epic below the top level becomes a **Feature** under the top-level Epic. Epics nested 3+ deep are flattened onto the root, with the real parent preserved as a **Related** link and named in the description.

### Close dates and the revision history

The Scrum process owns `Closed Date` (auto-stamped on entry to a closed state). To keep the *real* historical date, and to backdate the created/changed revisions, the tool uses `bypassRules` on the create and the state transition. The close date is written **inside** the closing transition, so it is present before the rule-checked assignee patch runs (Task's `Done` requires a non-empty close date). `System.AssignedTo` is never sent in a `bypassRules` payload - it is set by a separate rule-checked patch, so a departed identity is rejected rather than stored. This needs a PAT whose identity holds bypass rights.

### Owners and identities

Owners are matched by **email** (emails are not reliably derivable from names). ADO only accepts `AssignedTo` identities that are members of your organization, so the tool probes each owner (cached `validateOnly`) and assigns the **first one ADO accepts**, trying each owner then the item's creator. Owners it can't assign go to `Custom.DigitalAIOwners`. A directory user who is not yet an org member is rejected by the REST API even though the web picker can assign them (which quietly adds them to the org); the `MaterializeOwners` helper can add such owners as free Stakeholders up front if you want them assigned.

## Prerequisites

- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) or later
- A digital.ai Agility **access token** (Agility → member profile → Applications)
- An Azure DevOps **PAT** with Work Items (Read & Write) scope. `Closed Date` and the backdated history need an identity with **bypass rules** rights.
- [CredentialManager](https://www.powershellgallery.com/packages/CredentialManager) if you store tokens in Windows Credential Manager: `Install-Module CredentialManager -Scope CurrentUser`
- [Pester](https://pester.dev) 5+ for the tests: `Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -SkipPublisherCheck`

## Configuration

Two config files are gitignored so your instance-specific details stay out of source control. Copy the samples and fill in your values:

```
cp appsettings.sample.json appsettings.json
cp mappings.sample.json mappings.json
```

| File | Committed | Holds |
|---|---|---|
| `appsettings.sample.json` | Yes | Placeholder instance URLs, scopes, org, project. |
| `appsettings.json` | No (gitignored) | Your real instance details. **No tokens** - only credential-target names. |
| `mappings.sample.json` | Yes | Generic type/field/state config + example value maps. |
| `mappings.json` | No (gitignored) | Your type/field/state config and your instance's value maps. |

### Tokens

Tokens resolve from an environment variable first, then Windows Credential Manager:

| Token | Environment variable | Credential Manager target |
|---|---|---|
| Agility access token | `AGILITY_ACCESS_TOKEN` | the `Agility.CredentialTarget` value |
| Azure DevOps PAT | `ADO_PAT` | the `AzureDevOps.CredentialTarget` value |

Store a token in Windows Credential Manager from your own terminal (keeps it out of shell history):

```powershell
Import-Module CredentialManager
$token = Read-Host "Token" -AsSecureString
New-StoredCredential -Target "ADO-YourOrg-PAT" -UserName "pat" `
  -SecurePassword $token -Persist LocalMachine -Type Generic
```

## Usage

The script takes no parameters. Edit the calls in `Main` (the control panel) and run it:

```powershell
./src/Migrate-Agility.ps1
```

`Main` exposes a menu of operations you uncomment one at a time:

```powershell
# CreateAreaPaths -DryRun            # list the area nodes the scopes/Themes need
# CreateAreaPaths                    # create them (run before migrating Stories/Defects/Tasks)
# Migrate -DryRun -IncludeClosed     # preview everything, writes nothing
# Migrate -IncludeClosed             # the real migration, all types, all scopes
# Migrate -IncludeClosed -Types Task # one type
# MaterializeOwners -DryRun          # optional: preview adding owners to the org as Stakeholders
# DeleteAllTasks -DryRun             # count Tasks (a delete helper for re-running just Tasks)
```

| Switch | Effect |
|---|---|
| `-DryRun` | Print what would happen. Writes nothing to Azure DevOps. |
| `-IncludeClosed` | Include closed items (excluded by default). Never includes "Dead" placeholder templates. |
| `-Scope` | Narrow to one configured scope. Cross-scope parents will not resolve. |
| `-Types` | Which Agility types to migrate. Defaults to all five. Order is always Epic → Story → Defect → Task → Issue regardless of what you pass, so children find their parents. |

**`Migrate` without `-DryRun` writes to Azure DevOps.** Preview first.

Before the first create, the tool checks every mapped state and field against what ADO reports for each type, so a mapping mistake fails on call one, not on item one of tens of thousands. It's idempotent and resumable: items are matched by `Custom.DigitalAIID` and skipped, so an interrupted run just continues.

### Area paths

Each scope maps to an ADO area path; Stories/Defects add a Theme leaf below it. **The nodes must exist** or ADO rejects the item (`TF401347`). `CreateAreaPaths` builds exactly the nodes your data needs (derived live, closed items included) - run it after adding a scope or a `ThemeAreaPaths` entry, before the migration that needs them.

## Validate before you migrate

**Run `-DryRun` first.** It prints the type, title, parent link, area path, state, priority, and assignee for every item, asks ADO to validate each payload (`validateOnly=true`) so field problems surface as `INVALID` before any write, and writes nothing to either system. A dry run validates the create; the state transition, links, and close date need a real item, so they aren't covered - but the states themselves are checked against ADO's own list on every run.

The parser has been validated against a live instance, but Agility response shapes vary by version. `ConvertFromAgilityAssets` is the only function that knows the wire format.

## Tests

```powershell
Invoke-Pester -Path tests -Output Detailed
```

## Limitations

- One-way migration only (Agility to Azure DevOps).
- `Closed Date` and the backdated history need a PAT identity with rule-bypass rights.
- Targets the **Scrum** process; the Agile process needs `mappings.json` changes (User Story, StoryPoints).
- Epics nested 3+ deep are flattened onto the top-level Epic, with the real parent kept as a Related link.
- Custom fields must be created in your ADO process and listed in `mappings.json`.
- Attachments, comments, and full change history are not migrated (two-point history only, since Agility's full-history endpoint is not always available).
- Agility descriptions are passed through as HTML without sanitizing.

## License

[MIT](LICENSE)
