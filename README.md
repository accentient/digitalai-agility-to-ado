# Digital.ai Agility to Azure DevOps Migrator

[![Tests](https://github.com/accentient/digitalai-agility-to-ado/actions/workflows/tests.yml/badge.svg)](https://github.com/accentient/digitalai-agility-to-ado/actions/workflows/tests.yml)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A PowerShell tool that migrates work items one way, from [Digital.ai Agility](https://digital.ai/products/agility/)
(formerly VersionOne and CollabNet VersionOne) into [Azure DevOps](https://azure.microsoft.com/products/devops).
It reads from Agility and creates work items in an Azure DevOps project, preserving hierarchy, links,
attachments, history, and traceability.

It has migrated **53,683 work items in a single run** - all types, all scopes, closed items included.

> **Agility is only ever read from.** Every Agility call goes through a single function that hard
> codes `-Method Get`, so the tool has no code path that can modify anything in the source. Tests
> assert this in both directions.

## Features

- Migrates **Epics, Stories, Defects, Tasks, and Issues** through Agility's REST API.
- Maps work item types, fields, states, and links to their Azure DevOps equivalents, all configurable
  in `mappings.json` without editing the script.
- Preserves the **hierarchy**, dependency and Affects links, attachments, comments, area and
  iteration paths, and a **backdated two-point revision history** (created-by and last-changed-by, at
  their real dates).
- Records each item's Agility number in a custom field, so runs are **idempotent and resumable** -
  an interrupted migration just continues.
- Validates every mapped state and field against Azure DevOps **before the first create**, so a
  mapping mistake fails on call one rather than on item one of tens of thousands.
- **`-DryRun` on everything.** Preview the whole migration without writing.

## Supported versions

Compatibility is governed by the API surface the tool uses, not by the product's branding. It calls
only `rest-1.v1/Data` and `attachment.img` with an access token (Bearer auth) - a surface that has
been stable across the product's entire rebranding history and carries no deprecation notice.

### Source: Digital.ai Agility and its predecessors

| Product name | Era | Status |
|---|---|---|
| **Digital.ai Agility** | Apr 2020 - present (20.x - 26.x) | **Verified** on 26.1.6.5, SaaS (`v1host.com`) |
| CollabNet VersionOne | 2017 - Apr 2020 (17.x - 20.1) | Expected to work, not tested |
| VersionOne / VersionOne Lifecycle | through 2017 | Expected to work, not tested |

The product has been renamed twice: CollabNet merged with VersionOne in 2017, and on 15 April 2020
CollabNet VersionOne, XebiaLabs, and Arxan combined as Digital.ai, making the product Digital.ai
Agility. Versions are numbered `YY.Q` (three major releases a year through 24.3, four a year from
25.0), and were also given season names in the VersionOne era - Winter 2018 is 18.1, Summer 2018 is
18.2, Fall 2018 is 18.3.

Digital.ai supports the current major release plus the two preceding it, so as of August 2026 only
**26.2, 26.1, and 26.0** are vendor-supported and 25.3 and earlier are end of life. See the
[Agility support matrix](https://docs.digital.ai/agility/docs/agility/support-matrix). The tool does
not require a vendor-supported version.

### Target: Azure DevOps

| Platform | Status |
|---|---|
| **Azure DevOps Services**, Scrum process | **Verified** |
| Azure DevOps Server | Expected to work, not tested |
| Agile process | Needs `mappings.json` changes (User Story, StoryPoints) |

## What gets migrated

| Digital.ai Agility | Azure DevOps (Scrum) |
|---|---|
| Epic (Portfolio Item), top level | Epic |
| Epic (Portfolio Item), nested | Feature |
| Story (Backlog Item) | Product Backlog Item |
| Defect | Bug |
| Task | Task |
| Issue | Impediment |

**Your UI may not use these names.** Agility instances can rename asset types, and the API only ever
reports the internal one - no endpoint exposes the alias. The reliable tell is the work item's
**Number prefix**: `E-` Epic, `S-` Story, `D-` Defect, `TK-` Task, `I-` Issue, `AT-` Test, `R-`
Request. On one instance we migrated, the UI called an `Issue` a *Challenge* and called a `Defect` an
*Issue* - so "Challenges become Impediments" and "Issues become Bugs" were already exactly what the
table above says.

**[docs/migration-reference.md](docs/migration-reference.md)** has the full field mapping and the
reasoning behind the non-obvious behavior: why nested Epics become Features, how close dates and the
revision history are preserved, archiving long-finished work, recovering acceptance criteria from
descriptions, attachments, identity resolution, and area path rules. **[docs/design.md](docs/design.md)**
has the design rationale and the field audits.

## Getting started

### Prerequisites

- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) or later
- A Digital.ai Agility **access token** (Agility → member profile → Applications)
- An Azure DevOps **PAT** with Work Items (Read & Write) scope. Close dates and the backdated history
  need an identity with **bypass rules** rights.
- [CredentialManager](https://www.powershellgallery.com/packages/CredentialManager), if you store
  tokens in Windows Credential Manager: `Install-Module CredentialManager -Scope CurrentUser`

### Configuration

Two config files are gitignored so your instance-specific details stay out of source control. Copy
the samples and fill in your values:

```powershell
cp appsettings.sample.json appsettings.json
cp mappings.sample.json mappings.json
```

| File | Committed | Holds |
|---|---|---|
| `appsettings.sample.json` | Yes | Placeholder instance URLs, scopes, org, project. |
| `appsettings.json` | No | Your real instance details. **No tokens** - only credential-target names. |
| `mappings.sample.json` | Yes | Generic type/field/state config and example value maps. |
| `mappings.json` | No | Your type/field/state config and your instance's value maps. |

Tokens are never stored in the repo. They resolve from an environment variable first, then Windows
Credential Manager:

| Token | Environment variable | Credential Manager target |
|---|---|---|
| Agility access token | `AGILITY_ACCESS_TOKEN` | the `Agility.CredentialTarget` value |
| Azure DevOps PAT | `ADO_PAT` | the `AzureDevOps.CredentialTarget` value |

To store one in Windows Credential Manager from your own terminal (keeping it out of shell history):

```powershell
Import-Module CredentialManager
$token = Read-Host "Token" -AsSecureString
New-StoredCredential -Target "ADO-YourOrg-PAT" -UserName "pat" `
  -SecurePassword $token -Persist LocalMachine -Type Generic
```

### Usage

The script takes no parameters. `Main` is the control panel: edit the calls, then run it.

```powershell
./src/Migrate-Agility.ps1
```

```powershell
# CreateAreaPaths -DryRun            # list the area nodes your scopes/Themes need
# CreateAreaPaths                    # create them (run before migrating Stories/Defects/Tasks)
# Migrate -DryRun                    # preview everything, writes nothing
# Migrate                            # the real migration, all types, all scopes
# Migrate -Types Task                # one type
# MaterializeOwners -DryRun          # optional: preview adding owners to the org as Stakeholders
# RepairDependencyTags -DryRun       # find dependency tags whose partner has since been migrated
```

| Switch | Effect |
|---|---|
| `-DryRun` | Print what would happen. Writes nothing to Azure DevOps. |
| `-Scope` | Narrow to one configured scope. Cross-scope parents will not resolve. |
| `-Types` | Which Agility types to migrate. Defaults to all five. Order is always Epic → Story → Defect → Task → Issue regardless of what you pass, so children find their parents. |

**Run `-DryRun` first.** It prints the type, title, parent link, area path, state, priority, and
assignee for every item and asks Azure DevOps to validate each payload (`validateOnly=true`), so
field problems surface as `INVALID` before anything is written. A dry run validates the create; the
state transition, links, and close date need a real item, so they are not covered.

**Closed items always migrate.** There is no switch for it - every real run wanted them, so the
option was removed rather than left as a trap. Items whose source `AssetState` is *Dead* are the one
exclusion; those are placeholder templates and are never created.

## Tracking tags

The migration can add its own tags to `System.Tags` to record things it could not link or file: the
number of a parent, blocked item, related item or dependency that is not in Azure DevOps, and the
source item's Source value. The source system has no such tags, and every one becomes a permanent tag
definition in the project, so they are **off by default**. Set `"WriteTrackingTags": true` in
`mappings.json` to write them. The source's own tag list is always copied regardless.

## Area paths and iteration paths

Azure DevOps rejects an unknown area or iteration path outright (`TF401347`), so both have to exist
before the migration writes an item to one.

**Area paths are handled for you.** `CreateAreaPaths` in `Main` walks your configured scopes, works
out which nodes the scopes and Themes need, and creates them. Run it before migrating.

**Iteration nodes are not.** Each Story, Defect and Task that sits in an Agility Timebox is written
to `<Project>\<Timebox name>`, and this script never creates those nodes - create them yourself, one
flat node per distinct Timebox name under the project root, before the migration runs.

One trap if you script that: Agility's timebox end date is **exclusive** (it is the day the next
sprint starts) while Azure DevOps' finish date is **inclusive**. Copy the end date verbatim and every
sprint overlaps its successor by a day. A three week sprint starting on a Wednesday should finish on
the Tuesday, with the next starting the following Wednesday.

## Tests

```powershell
Invoke-Pester -Path tests -Output Detailed
```

The suite is hermetic: nothing resolves a credential, queries a live instance, or writes a log file,
so it runs anywhere. It also runs on every push and pull request (see the badge above).

## Limitations

- One-way migration only, Agility to Azure DevOps. There is no sync and no delta mode: an
  already-migrated item is skipped before any field is compared, so later source edits are not
  brought across.
- Close dates and the backdated history need a PAT identity with rule-bypass rights.
- Targets the **Scrum** process; the Agile process needs `mappings.json` changes.
- Epics nested 3+ deep are flattened onto the top-level Epic, with the real parent kept as a Related
  link.
- Custom fields must be created in your Azure DevOps process and listed in `mappings.json`.
- Full change history is not migrated. History is two-point only - created-by/date and
  changed-by/date - because Agility's full-history endpoint is not available on every hosted
  instance. Attachments and comments **are** migrated.
- Comments can only be backdated while an item is being created, so they arrive on a full migration
  or not at all. There is no way to add them to items a previous run already created.
- Dependency links that form a cycle are rejected by Azure DevOps (`TF201035`). Each is skipped on
  its own, so the work items still migrate; only that one link is lost.
- Agility descriptions are passed through as HTML without sanitizing.

## Migration consulting

A migration of any size is rarely just a script run - scoping, field mapping, process design, and
deciding what *not* to bring across are usually the hard parts. If you would like help planning or
running one, get in touch.

**Richard Hundhausen** · [richard@accentient.com](mailto:richard@accentient.com) · [Accentient](https://accentient.com)

## Contributing

Bug reports and pull requests are welcome through
[GitHub Issues](https://github.com/accentient/digitalai-agility-to-ado/issues). When reporting a
problem, please include your Agility version, the relevant section of your `mappings.json` with any
instance-specific values removed, and the log excerpt from `logs/` - **never a token**.

## License

[MIT](LICENSE)
