# Design: professionalize the public repo

Date: 2026-08-07
Repo: https://github.com/accentient/digitalai-agility-to-ado

## Goal

Make the public GitHub project read like a supported product rather than a working notebook, using
[solidify/jira-azuredevops-migrator](https://github.com/solidify/jira-azuredevops-migrator) as the
model. Four outcomes:

1. A shorter README (about 125 lines, down from 253) that a stranger can skim in two minutes.
2. A **Supported versions** section covering the product's whole lineage - VersionOne, CollabNet
   VersionOne, Digital.ai Agility - because that is what people search for.
3. Migration consulting contact for Richard Hundhausen.
4. No client-identifying content and no stray run artifacts in the public tree.

There is **no paid or pro tier**. The solidify README's pricing table is deliberately not copied.

## Research: product lineage and versions

Established from vendor documentation, not assumed. Sources listed at the bottom.

| Era | Product name | Version scheme |
| --- | --- | --- |
| through 2017 | VersionOne, VersionOne Lifecycle | `YY.Q` plus a season name |
| 2017 - Apr 2020 | CollabNet VersionOne | same (Winter 2018 = 18.1, Summer 2018 = 18.2, Fall 2018 = 18.3) |
| Apr 2020 - present | Digital.ai Agility | 3 majors/year through 24.3, then 4/year from 25.0 |

CollabNet merged with VersionOne in 2017. On 15 April 2020 CollabNet VersionOne, XebiaLabs, and
Arxan combined as Digital.ai, and the product became Digital.ai Agility.

**Vendor support policy**: the current major release plus the two immediately preceding majors. As of
2026-08-07 that is **26.2** (released 2026-07-25), **26.1** (2026-04-25), and **26.0** (2026-01-24,
end of support 2026-10-24). **25.3 and earlier are end of life.**

**What actually governs compatibility for this tool** is not the product version but the API surface
it touches, which is narrow and long-stable:

- `GET {base}/rest-1.v1/Data/{AssetType}?sel=&where=&page=size,start`
- `GET {base}/attachment.img/{numericId}`
- `Authorization: Bearer <access token>`

Verified against the source: `Migrate-Agility.ps1` hits only those two endpoints. It does not use
`query.v1`, `api/asset`, or `hist-1.v1`. The official VersionOne API docs still document `rest-1.v1`,
`meta.v1`, and access-token Bearer auth, and their own worked examples run against build `18.2.5.14`,
so this surface is unchanged at least back to 18.x and carries no deprecation notice.

**Therefore the README claims exactly two tiers, and no more:**

- **Verified**: Digital.ai Agility 26.1.6.5, SaaS (`v1host.com`). This is the instance the tool was
  built and run against.
- **Expected, not tested**: any release exposing `rest-1.v1` with access tokens, which covers the
  CollabNet VersionOne and VersionOne eras.

Do not publish a version list that implies testing that did not happen. The lineage table exists for
discoverability (people search "VersionOne migration"), and every row is labelled with its evidence.

Target side: **Azure DevOps Services, Scrum process - verified** (53,683 items). Azure DevOps Server
is untested. The Agile process needs `mappings.json` changes (User Story, StoryPoints).

## Deliverables

### 1. `README.md` rewritten to about 125 lines

```
# Digital.ai Agility to Azure DevOps Migrator
[CI badge] [PowerShell 7+] [License MIT]

intro paragraph + read-only guarantee
## Features
## Supported versions
## What gets migrated          type table, link to migration reference
## Getting started             prerequisites, configuration, tokens, usage
## Removing work items         trimmed
## Tests
## Limitations
## Migration consulting
## Contributing
## License
```

The H1 becomes the human-readable product name. The repo slug is unchanged.

### 2. `docs/migration-reference.md` (new)

Receives, verbatim, everything cut from the README: the full field-mapping table and the seven
deep-dive sections (why nested Epics become Features, close dates and the revision history,
archiving long-finished work, acceptance criteria recovery, attachments, owners and identities, area
paths and `AreaPathRemap`). Nothing is deleted, only relocated. `docs/design.md` is not restructured;
it remains the design rationale.

### 3. `.github/workflows/tests.yml` (new)

Pester on `windows-latest`, on push and pull request to `main`. Justified by a measured baseline:
**491 tests, 0 failures, 17s**, and the suites are hermetic - `CredentialManager` is imported inside
`GetSecret`, which the tests mock, so a hosted runner needs no extra module and no credentials. The
build badge therefore reflects something real. This is the only reason a badge is added at all.

### 4. Scrub

| Location | Now | Becomes |
| --- | --- | --- |
| `README.md:26` | "On the CWI instance the UI calls..." | generic "one instance we migrated" |
| `docs/design.md:140` | "On the CWI instance..." | same |
| `docs/design.md:629` | "The original example was `.edu conversion`" | generic node name |
| `mappings.sample.json:275` | `Operations\myCWI` | `Operations\Legacy App` |
| `logs/half-migrated-epic-ids.txt` | tracked in git (161 raw ADO ids) | `git rm --cached`, and `logs/` added to `.gitignore` |

**Tests are deliberately not scrubbed.** `.edu conversion` and `myCWI` appear in
`tests/Migrate-Agility.Tests.ps1` as fixtures pinning two real edge cases - an area path node whose
name begins with a dot, and an `Exact` remap rule that must beat a more general rule. Renaming them
for cosmetics would weaken the assertions. They are node names, not client identifiers.

## Constraints

- No en-dashes or em-dashes anywhere (global writing rule).
- No paid tier, no pricing table, no "PRO" anything.
- The consulting section names Richard Hundhausen and richard@accentient.com.
- Do not commit. The user handles all git operations; changes are left in the working tree. The
  `git rm --cached` is the one exception, and it is staged only because there is no other way to
  untrack a file - it is left uncommitted.

## Verification

1. `Invoke-Pester -Path tests` still reports 491 passed, 0 failed. No source file is edited, so this
   is a regression check on the scrub, not on behaviour.
2. `git ls-files` no longer lists `logs/half-migrated-epic-ids.txt`.
3. `git grep -niE "CWI|myCWI"` over tracked non-test files returns nothing.
4. Every link in the new README resolves to a file that exists in the repo.
5. The workflow YAML parses and its step order matches the local command that produced the 491/0
   baseline.

## Sources

- https://docs.digital.ai/agility/docs/agility/support-matrix
- https://docs.digital.ai/agility/docs/agility-release-notes/release-notes-and-downloads
- https://support.digital.ai/hc/en-us/articles/360021386780-Policy-Digital-ai-Agility-supported-product-versions
- https://digital.ai/press-releases/digitalai-the-companies-formerly-known-as-xebialabs-and-collabnet-plus/
- https://versionone.github.io/api-docs/
- https://community.versionone.com/Release-Notes-and-Downloads/Archive_-_Unsupported_Releases/2018_Releases/Winter_2018_Release_Notes
