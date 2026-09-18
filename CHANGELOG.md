# Changelog

All notable changes to Site Hygiene are documented in this file.

## [0.9.1] - 2026-09-18

### Fixed

- Run collection settings, dependency, and collection reference queries without remote WMI rights.
- Show one timestamp on warning lines in the log pane.

## [0.9.0] - 2026-09-18

### Added

- Choose which site areas a scan covers under Options > Scan scope.
- Cancel a running scan from the progress overlay.
- Show each dataset's row count and duration in the log pane, console, and log file.
- Show elapsed time and per-object progress on the progress overlay.

### Changed

- Read collections with one query instead of one read per collection.
- Read application deployments with one query instead of one read per deployment.
- Read collection schedules only for custom collections that have a full-update schedule.
- Skip the application definition read unless the relationships area is selected.
- Count collection dependency references when deciding whether an empty collection is unused.
- Leave the rescan-delta baseline unchanged after a scoped scan.

## [0.8.1] - 2026-09-04

### Changed

- **Vendored `SuiteCommon` 0.4.3.** The module repairs the process
  PSModulePath at import: a Windows PowerShell process launched from
  PowerShell 7 inherits the 7.x module directories, and the background
  runspace opened later autoloaded a Microsoft.PowerShell.Utility without
  Get-FileHash or ConvertFrom-Json, so background operations failed with
  an unrelated "term not recognized". A background runspace whose module
  import fails is disposed and the original error thrown instead of being
  returned as an opened but unusable worker.

## [0.8.0] - 2026-08-27

### Added

- **Collection evaluation deep-dive** (five new checks, per the Learn
  collection best-practices and collection-evaluation docs):
  - `COL-05` incremental collection with a sub-daily full evaluation
    schedule — the full update is only a backup; executable fix drops
    the collection to incremental-only (`-RefreshType Continuous`).
  - `COL-06` direct-rule-only collection with a scheduled evaluation
    and a non-incremental limiting collection — the schedule re-computes
    an identical result; executable fix sets `-RefreshType Manual`.
  - `COL-07` include/exclude reference chain deeper than the threshold
    (default 3), with the measured depth as evidence and the WQL
    subselect rewrite as guidance.
  - `COL-08` circular collection reference across limiting, include,
    and exclude edges (Error) — evaluation loops that hammer the site
    database.
  - `COL-09` full-update start-hour hot spots (default 10 collections
    sharing a start hour).
  The collection dataset now carries rule composition and full-update
  schedule fields; the reference graph builds from data already loaded,
  with zero extra provider round-trips. Built-in SMS collections are
  exempt. New thresholds `ColRefDepthMax` and `ColFullEvalHotSpotCount`.

## [0.7.0] - 2026-08-26

### Added

- **Bulk fixes.** Run Fix now accepts a multi-row selection: one
  confirmation dialog lists every script it will run, execution proceeds
  sequentially on the background runspace, and each row is marked Fixed
  or Failed individually. Display-only and already-fixed rows are
  excluded from the runnable set automatically.
- **Rescan deltas.** Each scan saves its findings to
  `SiteHygiene.lastscan.json` and diffs against the previous file:
  first-seen findings are flagged in a New column, resolved findings are
  logged by check and object, and a missing or malformed previous file
  degrades to "baseline recorded" instead of failing the scan.
  `SiteHygieneCommon` 0.7.0 adds `Save-HygieneScanResult`,
  `Read-HygieneScanResult`, and `Get-HygieneScanDelta`.

## [0.6.0] - 2026-08-26

### Added

- **Per-finding fix execution.** A Run Fix button executes the selected
  finding's fix script against the connected site after a confirmation
  dialog that shows the exact script. Execution runs on the background
  runspace from the CM site drive; the script is logged before execution
  and the outcome after, and the grid marks the finding Fixed or Failed.
  Display-only fix guidance (comment-only scripts) never enables the
  button. `SiteHygieneCommon` 0.6.0 adds `Test-HygieneFixExecutable`
  and `Invoke-HygieneFix`.

## [0.5.1] - 2026-08-17

### Fixed

- Completed dataset-failure gating for task-sequence references,
  dependency targets, package programs, collection settings, and device
  cleanup-task state; incomplete input can no longer produce cleanup
  findings from those checks.
- `TSQ-01` now validates the task sequence's separately stored
  `BootImageID`, not only its `References` collection.
- `DEP-05` is now an informational inventory signal that explicitly
  recognizes valid contentless script deployment types and offers no
  automatic remediation.
- Failed background-runspace bootstrap now disposes the unusable runspace
  and throws the original initialization error instead of returning an
  opened but broken worker.
- Timed-out `APP-04` probe pipelines are retained and reaped after their
  asynchronous stop completes.

## [0.5.0] - 2026-08-16

### Changed

- **Provider contracts corrected against the documented WMI classes.**
  `DPL-01` now keys on `ExpirationTime` alone (`SMS_ApplicationAssignment`
  has no enable flag, so the old gate silently disabled the check).
  `UPD-01` computes its ratio from the documented expired count only;
  superseded presence is a boolean on the provider and now colors the
  evidence instead of inflating the percentage. `TSQ-01` learns OS images
  and OS upgrade packages, so `ImagePackageID`/`InstallPackageID`
  references stop reading as deleted content. `DEP-05` claims what
  `HasContent` actually means — the dependency target carries no
  content — at Warning, instead of asserting distribution state it never
  queried.
- **`UPD-02` is removed** (23 core-register checks; 33 total including
  the ten relationship checks). It joined update packages
  against `SMS_DeploymentSummary.PackageID`, which the provider documents
  as the 2007-era program identifier; the check would have reported
  modern update packages as unused and offered a deletion script.
- **A failed dataset now skips its checks instead of feeding them.**
  Every collection failure lands in `FailedDatasets`, and the scan
  replaces each dependent check with a visible skip finding — a lost
  deployment query can no longer make applications, packages, and
  collections read as unreferenced with deletion scripts attached.
- **`APP-04` probes with a real timeout and an Unknown verdict.** A
  content source that does not answer is reported as unknown-from-this-
  workstation at Info rather than missing, and a stalled SMB path can no
  longer hang the scan; verdict wording is scoped to the workstation
  since the site server may have rights this session lacks.
- **Fix scripts use real cmdlets** (`Invoke-CMSoftwareUpdateAutoDeploymentRule`,
  `Resume-CMApplication`).
- **Version metadata is single-sourced** from the module manifest: the
  title-bar version and About pane render from it, and a test fails the
  build when the manifest, changelog headline, and script header
  disagree.
- Pester suite is now tracked in the repository (fixtures are synthetic;
  packaging continues to exclude tests from release zips).

## [0.4.0] - 2026-08-16

### Changed

- **Window chrome, theming, dialog theming, window-state persistence,
  and the background-runspace lifecycle now come from the vendored
  `SuiteCommon` module** (0.3.0); this tool's non-blocking teardown
  pattern (BeginStop into a reaped graveyard, CloseAsync at exit) is now
  the shared implementation every suite tool uses. Behavior gains from
  the shared chrome: hook state no longer leaks on window close, and a
  maximized close persists the pre-maximize geometry.

## [0.3.0] - 2026-08-14

### Added

- **The remaining five check families, completing the 24-check register.**
  Devices: `DEV-01` inactive clients beyond threshold (severity depends
  on whether discovery cleanup tasks would purge them), `DEV-02`
  duplicate records by name and by cross-name SMBIOS GUID collision,
  `DEV-03` clients behind the newest client version. Boundaries:
  `BND-01` boundaries in no group, `BND-02` groups with no site systems,
  `BND-03` overlapping IP-range boundaries. Task sequences: `TSQ-01`
  references to deleted content, `TSQ-02` custom boot images and driver
  packages nothing references (default boot images excluded). Updates:
  `UPD-01` update groups over the expired/superseded ratio threshold,
  `UPD-02` update deployment packages no deployment references, `UPD-03`
  ADRs erroring (Error), disabled (Info), or enabled-but-stale
  (Warning). Site: `MNT-01` recommended cleanup tasks disabled, `MNT-02`
  the Backup Site Server task disabled. New thresholds:
  `InactiveDeviceDays` (90), `SugExpiredPctThreshold` (30),
  `AdrStaleDays` (45).
- **Category filter** gains Devices, Boundaries, Task Sequences,
  Updates, and Site.

## [0.2.0] - 2026-08-14

### Added

- **Relationship checks, absorbed from the supersedence-auditor tool.**
  A second bulk application pass parses each app's `SDMPackageXML`
  in-memory — one provider call for the whole site, no per-app
  round-trips — and eleven new checks run over the result: `SUP-01..04`
  (orphaned, circular, disabled-source, retired-target supersedence),
  `DEP-01..05` (orphaned, circular, disabled, retired, and
  content-less dependency targets), `REL-01` (relationship participants
  without manufacturer metadata), and `APP-04` (deployment-type content
  source folders missing or unreachable). This reaches full parity with
  the standalone auditor's Broken Rules coverage. Supersedence and
  dependency rules have no removal cmdlet, so those fix scripts are
  console guidance.
- **Suppression list.** Suppress and Unsuppress buttons on the Findings
  view hide accepted findings from future scans (multi-select
  supported); a "Show suppressed" toggle brings them back. Keys persist
  in `SiteHygiene.suppressions.json` beside the tool.
- **Relationships view.** Supersedence chains and dependency trees
  rendered as a tree with per-node health glyphs (missing or retired
  targets, disabled or content-less applications, circular references
  annotated in place). Selecting a node shows the application's
  relationship standing. This completes the absorption of the standalone
  supersedence-auditor tool's surface.

### Changed

- Scan flow gains the relationship collection step; if it fails, the
  relationship checks are skipped with a Summary-view note instead of
  failing the scan.
- Findings grid allows multi-select for bulk suppression.

## [0.1.0] - 2026-08-14

First release: a read-only MECM hygiene scanner.

### Features

- **Ten checks with stable IDs** across four families: applications
  (APP-01 unused, APP-02 retired-but-deployed, APP-03
  superseded-but-deployed), packages (PKG-01 unused), collections
  (COL-01 dead, COL-02 deployment-to-empty, COL-03 incremental ceiling),
  deployments (DPL-01 expired, DPL-02 past-deadline failures, DPL-03
  available with no takers). Thresholds (age windows, ceiling, failure
  percentage) are tunable with sensible defaults.
- **One-pass prefetch, pure checks.** A single collection pass pulls the
  bulk `Get-CM*` datasets plus two read-only CIM queries; every check
  runs as a pure function over that data. A dataset that fails to load
  degrades to an empty set with a Summary-view note naming the check it
  affects instead of killing the scan.
- **Evidence-first findings.** Every finding carries severity, the
  object, the evidence sentence that produced it, a recommendation, and
  the exact PowerShell a fix would take — displayed, never executed.
- **Findings and Summary views** with text / category / severity
  filtering, severity glyphs, and a detail pane.
- **CSV and HTML export** of the filtered findings; the HTML report
  color-codes severity and HTML-encodes all site-derived text.
- **Shared core.** Logging, CM connection management, and settings
  persistence come from the vendored `SuiteCommon` module
  (`Lib\SuiteCommon`), shared across the tool suite.
