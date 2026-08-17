# Changelog

All notable changes to Site Hygiene are documented in this file.

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
