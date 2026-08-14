# Site Hygiene

[![Latest release](https://img.shields.io/github/v/release/jasonulbright/site-hygiene?label=release)](https://github.com/jasonulbright/site-hygiene/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/jasonulbright/site-hygiene/total?label=downloads)](https://github.com/jasonulbright/site-hygiene/releases)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D4)](#requirements)
[![License](https://img.shields.io/github/license/jasonulbright/site-hygiene)](LICENSE)

A MahApps.Metro WPF scanner for MECM site clutter and drift: unused
applications and packages, dead collections, stale and failing
deployments. A scan is read-only, every finding carries the evidence that
produced it, and every finding shows the exact PowerShell a fix would
take — displayed, never executed, by this tool.

## Requirements

- Windows 10 / 11 or Server 2016+
- PowerShell 5.1
- .NET Framework 4.7.2+
- Configuration Manager console installed (provides the
  `ConfigurationManager` PowerShell module)
- Read access to the SMS Provider (a scan never mutates the site)

## Quick Start

1. Download the release zip and extract it to a working folder.
2. Right-click `start-sitehygiene.ps1` -> **Run with PowerShell**, or from
   a PowerShell prompt:

   ```powershell
   powershell -ExecutionPolicy Bypass -File start-sitehygiene.ps1
   ```
3. Click **Options** on the sidebar and set Site Code and SMS Provider.
4. Click **Scan**.

## Checks

Stable check IDs so findings and reports stay comparable across scans:

| Id | Severity | Finds |
|---|---|---|
| APP-01 | Warning | Applications with no deployments, no task sequence references, no supersedence role, and no dependency targeting (with an age grace window for new apps) |
| APP-02 | Error | Retired (expired) applications that still have active deployments |
| APP-03 | Warning | Superseded applications whose own deployments are still active |
| PKG-01 | Warning | Legacy packages with no programs, no deployments, and no task sequence references |
| COL-01 | Info | Empty collections nothing references: no deployments, no include/exclude rules from other collections, not a limiting parent, no collection variables |
| COL-02 | Warning | Deployments targeting a collection with zero members |
| COL-03 | Warning | Incremental-evaluation collection count over the recommended ceiling |
| DPL-01 | Info | Application deployments past their expiration time |
| DPL-02 | Error | Required deployments past deadline with a failure rate over threshold |
| DPL-03 | Info | Available deployments old enough to judge with zero installs and nothing in progress |
| APP-04 | Warning | Deployment-type content source folders missing or unreachable |
| SUP-01 | Error | Supersedence referencing a deleted application |
| SUP-02 | Error | Circular supersedence chain |
| SUP-03 | Warning | Superseding application disabled |
| SUP-04 | Warning | Supersedence target retired or expired |
| DEP-01 | Error | Dependency referencing a deleted application |
| DEP-02 | Error | Circular dependency |
| DEP-03 | Warning | Dependency target disabled |
| DEP-04 | Warning | Dependency target retired or expired |
| DEP-05 | Error | Dependency target with no distributed content |
| REL-01 | Info | Relationship participants without manufacturer metadata |
| DEV-01 | Warning/Info | Inactive clients beyond threshold (Info when cleanup tasks will purge them) |
| DEV-02 | Warning | Duplicate device records by name or SMBIOS GUID |
| DEV-03 | Info | Clients behind the newest client version |
| BND-01 | Warning | Boundary in no boundary group |
| BND-02 | Warning | Boundary group with no site systems |
| BND-03 | Info | Overlapping IP-range boundaries |
| TSQ-01 | Error | Task sequence referencing deleted content |
| TSQ-02 | Warning | Custom boot images / driver packages nothing references |
| UPD-01 | Warning | Update group over the expired/superseded ratio threshold |
| UPD-02 | Info | Update deployment package referenced by no deployment |
| UPD-03 | Error/Warning/Info | ADR erroring / stale / disabled |
| MNT-01 | Info | Recommended cleanup maintenance tasks disabled |
| MNT-02 | Warning | Backup Site Server task disabled |

The relationship families come from one additional bulk application pass
that parses each app's `SDMPackageXML` in-memory — the technique absorbed
from the standalone supersedence-auditor tool, with full parity to its
Broken Rules coverage.

Thresholds (age windows, incremental ceiling, failure percentage) have
sensible defaults in `Get-HygieneDefaultThresholds`.

## How a scan works

One prefetch pass pulls every dataset the checks need — bulk `Get-CM*`
reads plus two read-only CIM queries (collection settings, application
dependency relations) — and the checks run as pure functions over that
data. A dataset that fails to load degrades to an empty set with a note
in the Summary view instead of killing the scan; the note also says which
check may over- or under-report because of it.

## Views

- **Findings** — every finding from the last scan with severity glyphs,
  filterable by text, category, and severity. Selecting a row shows the
  full evidence, the recommendation, and the fix script. Suppress and
  Unsuppress (multi-select) hide accepted findings from future scans;
  keys persist in `SiteHygiene.suppressions.json` and a toggle shows the
  suppressed set.
- **Summary** — per-check counts plus dataset notes.

## Export

CSV and HTML export of the filtered findings. Files land under
`Reports/` by default. The HTML report color-codes severity and carries
evidence, recommendation, and fix script per finding.

## Project Structure

```
site-hygiene/
+- start-sitehygiene.ps1                     # WPF shell
+- MainWindow.xaml                           # Main window layout
+- Lib/                                      # Vendored MahApps.Metro 2.4.10
|  \- SuiteCommon/                           # Vendored shared core: logging + CM connection
+- Module/
|  +- SiteHygieneCommon.psd1                 # Module manifest
|  \- SiteHygieneCommon.psm1                 # Check engine (data prefetch + pure checks + exports)
+- Logs/                                     # Session logs (per-run)
+- Reports/                                  # CSV / HTML exports
+- CHANGELOG.md
+- LICENSE
\- README.md
```

## Safety

- A scan is read-only end to end: `Get-CM*` cmdlets plus two read-only
  CIM queries.
- Fix scripts are display-only. Nothing in this tool executes them.
- The scan runs in a background runspace so the UI stays responsive on
  large sites.

## License

This project is licensed under the [MIT License](LICENSE).
