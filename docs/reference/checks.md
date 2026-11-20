# Checks

This page lists every check of a scan.

## What it does

A check is a function over the data that the scan read. A check that finds a problem adds a finding with the check ID, the category, the severity, the object, the evidence and the recommendation. The summary lists the same checks with their counts.

## When to use it

Use it to learn what a check ID means and which severity it has.

## Requirements

None.

## Fixes

Check SUP-01 has a repair window, **Fix Supersedence**. See [Findings](../core/findings.md). The checks SUP-02 and SUP-03 have guidance only: a loop and a disabled superseding application need a decision that the tool cannot make for you.

The rule behind the next checks: no active application depends on or supersedes a retired application, and no task sequence installs a retired or superseded application. SUP-04 and DEP-04 (the target is retired) and APP-07 (the retired application holds rules itself) have fixes that use the supported cmdlets `Set-CMApplicationSupersedence -RemoveSupersedence` and `Remove-CMDeploymentTypeDependency`; each fix then deletes the old revisions that its change makes. APP-08 qualifies a superseded application for deletion only when no deployment, dependency, task sequence or stale reference row refers to it; a retired superseded application is left to SUP-04, and once its rule is gone APP-01 reports it. TSQ-05 and TSQ-06 report only: a task sequence is never edited from here.

## Checks

| ID | Category | Severity | Title |
|---|---|---|---|
| APP-01 | Applications | Warning | Application with no deployments or references. |
| APP-02 | Applications | Error | Retired application still deployed. |
| APP-03 | Applications | Warning | Superseded application still deployed. |
| APP-04 | Applications | Warning | Deployment type content source missing or unreachable. |
| APP-05 | Applications | Info | Application with old revisions. |
| APP-07 | Applications | Warning | Retired application that still supersedes or depends on an application. |
| APP-08 | Applications | Info | Superseded application that qualifies for deletion. |
| PKG-01 | Packages | Warning | Package with no programs and no references. |
| CNT-01 | Content | Warning | Content failed on one or more distribution points. |
| CNT-02 | Content | Info | Content distribution in progress beyond threshold. |
| CNT-03 | Content | Error | Deployed content on no distribution point. |
| SUP-01 | Relationships | Error | Supersedence referencing a deleted application. |
| SUP-02 | Relationships | Error | Circular supersedence chain. |
| SUP-03 | Relationships | Warning | Superseding application disabled. |
| SUP-04 | Relationships | Warning | Supersedence target retired or expired. |
| DEP-01 | Relationships | Error | Dependency referencing a deleted application. |
| DEP-02 | Relationships | Error | Circular dependency. |
| DEP-03 | Relationships | Warning | Dependency target disabled. |
| DEP-04 | Relationships | Warning | Dependency target retired or expired. |
| DEP-05 | Relationships | Info | Dependency target reports no packaged content. |
| REL-01 | Relationships | Info | Application relationships without manufacturer metadata. |
| DEV-01 | Devices | Warning | Inactive devices beyond threshold. |
| DEV-02 | Devices | Warning | Duplicate device records. |
| DEV-03 | Devices | Info | Clients below the newest client version. |
| BND-01 | Boundaries | Warning | Boundary in no boundary group. |
| BND-02 | Boundaries | Warning | Boundary group with no site systems. |
| BND-03 | Boundaries | Info | Overlapping IP-range boundaries. |
| TSQ-01 | Task Sequences | Error | Task sequence referencing deleted content. |
| TSQ-02 | Task Sequences | Warning | Boot image or driver package referenced by nothing. |
| TSQ-03 | Task Sequences | Warning | Application in a task sequence without the task sequence install setting. |
| TSQ-04 | Task Sequences | Error | Application in a task sequence with content on no distribution point. |
| TSQ-05 | Task Sequences | Warning | Task sequence installs a retired or superseded application. |
| TSQ-06 | Task Sequences | Warning | Stale reference rows of a task sequence that the site does not return. |
| UPD-01 | Updates | Warning | Software update group with a high expired-update ratio. |
| UPD-03 | Updates | Warning | Automatic deployment rule disabled, stale, or erroring. |
| MNT-01 | Site | Info | Recommended maintenance tasks disabled. |
| MNT-02 | Site | Warning | Site backup task disabled. |
| COL-01 | Collections | Info | Empty collection nothing references. |
| COL-02 | Collections | Warning | Deployment targeting an empty collection. |
| COL-03 | Collections | Warning | Incremental-evaluation collection count over ceiling. |
| COL-04 | Collections | Warning | Collection evaluation run time over threshold. |
| COL-05 | Collections | Warning | Sub-daily full evaluation on an incremental collection. |
| COL-06 | Collections | Info | Scheduled evaluation on a direct-rule-only collection. |
| COL-07 | Collections | Warning | Include/exclude reference chain over depth threshold. |
| COL-08 | Collections | Error | Circular collection reference. |
| COL-09 | Collections | Info | Full-update start-time hot spot. |
| DPL-01 | Deployments | Info | Deployment past its expiration time. |
| DPL-02 | Deployments | Error | Required deployment past deadline with high failures. |
| COL-10 | Collections | Info | Expired one-time maintenance window. |
| DPL-03 | Deployments | Info | Available deployment with no takers. |
| DPL-04 | Deployments | Warning | Required deployment to a built-in all-resources collection. |
| DPL-05 | Deployments | Warning | Deployment of a disabled task sequence or program. |
| DPL-06 | Deployments | Info | Deployment created more than the age threshold ago. |
| UPD-04 | Updates | Warning | Software update group over the per-deployment update limit. |
| UPD-05 | Updates | Info | Deployment package holding expired update content. |
| DPT-01 | Distribution Points | Warning | Distribution point in no boundary group. |
| DPT-02 | Distribution Points | Info | Distribution point group with no members. |
| CFG-01 | Compliance | Info | Configuration baseline deployed nowhere. |
| CFG-02 | Compliance | Info | Configuration item in no baseline. |
| CFG-03 | Compliance | Info | Custom client settings deployed to no collection. |
| DRV-01 | Drivers | Info | Driver in no driver package or boot image. |
| SEC-01 | Security | Warning | Administrative user with a deleted directory account. |

Severity is **Error**, **Warning** or **Info**.

## Steps

1. Open [Summary](../core/summary.md) to see the count of each check.
2. Open [Findings](../core/findings.md) to see the findings of a check.

## Limits

- A scan reads only the areas of **Options > Scan**. A check whose data is not read finds nothing.
- Some checks have guidance only. They have no fix script.

## Troubleshooting

None.

## Links

- [Findings](../core/findings.md)
- [Summary](../core/summary.md)
