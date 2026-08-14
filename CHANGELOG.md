# Changelog

All notable changes to Site Hygiene are documented in this file.

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
