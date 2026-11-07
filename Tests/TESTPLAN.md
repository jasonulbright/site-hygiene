# Site Hygiene: test plan

Measured 2026-11-07 with `Invoke-Checks.ps1` (Pester 5.7.1, PSScriptAnalyzer 1.25.0). Counts are tests as run; each data row counts as one test. Coverage is the share of module commands that the tests run.

| | Before | After |
|---|---|---|
| Tests | 181 | 850 on Windows PowerShell 5.1; 847 on PowerShell 7 (96 skip on 7: the contract tests need the ConfigMgr console) |
| Module coverage | 81.4% (3016 of 3705 commands) | 98.3% of 3734 commands |
| Lab steps | none | 22 (`Tests/Lab`) |

Run: `.\Invoke-Checks.ps1` (lint, tests, coverage floor 80%). It runs in CI on both hosts (`.github/workflows/checks.yml`).

## What is covered

| Area | File | Contents |
|---|---|---|
| Checks and scan | `SiteHygieneCommon.Tests.ps1` | Tests that were in the repository before this work |
| Site data prefetch | `Module.Prefetch.Tests.ps1` | Every dataset, defaults for missing properties, one failing dataset does not stop the others, scoped reads, pacing, progress, relationship pass |
| Fix execution and fix text | `Module.Fix.Tests.ps1` | Run Fix success, failure, `-WhatIf`, display-only and wrong location; names with quotes, wildcards and line breaks; placeholders |
| Live views | `Module.Live.Tests.ps1` | Deployment, content, distribution point, client, inactive device and site reads with mocked provider and SQL, metrics history, CSV and HTML export, legacy import |
| Script logic | `Shell.Logic.Tests.ps1` | Glyphs, grid rows, filters, suppression keys, preferences, status text, log, alerts, export |
| Script calls | `Script.Contract.Tests.ps1` | Every call from the script and the module into an app function or SuiteCommon names only parameters that exist |
| Real cmdlet signatures | `CmCmdlet.Contract.Tests.ps1` | Every ConfigMgr call in the modules, and every cmdlet named in a fix script or fix guidance, uses only parameters that the real cmdlet has. Runs where the console is installed |
| Start without the console | `Startup.Tests.ps1` | Plain message, `$false`, no raw exception |
| Windows | `Window.Tests.ps1` | Main window with its ten views and the Options dialog with its five panes: names, titles, no clipped text and nothing off screen at 1024x720 and 1440x900 in both themes, text and control contrast |
| Lab | `Lab/Invoke-HygLab.ps1` | ZZTEST- collection, package and three applications on CM01: scan, then Run Fix with success, `-WhatIf`, a missing object, a first line that fails, a name with `[1]` and a name with a curly apostrophe. Also MNT-01 on one real maintenance task (records all 47 tasks, disables one recommended task, runs the fix, restores the flag, compares all tasks). Checks that nothing else changed |

## Defects found

Each defect has a test that failed on the old code (the old module, script and XAML text swapped in) and passes now.

1. The window minimum width was 1100, above 1024. Fixed: 1024.
2. The Options dialog hint text missed 4.5:1 in the light theme. Fixed: a darker brush.
3. COL-03 guidance named `Set-CMCollection -Id`; the cmdlet has no `-Id`. Fixed: `-CollectionId`.
4. REL-01, MNT-01 and MNT-02 had runnable fix scripts with placeholders (`<manufacturer>`, `<site>`). Run Fix would have sent the placeholder to the site. Fixed: MNT-01 runs `Set-CMSiteMaintenanceTask -Name ... -Enabled $true -DisableWildcardHandling` (proven in the lab). MNT-02 (needs a backup destination) and REL-01 (the manufacturer name is not in the site data) are guidance only; their finding text says why.
5. A curly apostrophe in a name ended the quoted name in a fix script. Fixed: every quote character is doubled.
6. A line break in a name could add a runnable line to display-only guidance. Fixed: guidance is kept on one line.
7. A `[ ] * ?` in a name acted as a pattern in the fix scripts that select by name. Fixed: `-DisableWildcardHandling`.
8. The HTML export of the Live tables did not encode markup. Fixed.
9. An unknown collection reference type showed as `type0` (`$_` inside a `switch`). Fixed.
10. Suppressed findings were never read back after a restart: `Read-SuiteSettings` cannot return a setting named `Keys`. Fixed: the app reads its file itself.
11. CSV and HTML export of every Live view and of Relationships failed: the data table was unrolled into rows. Fixed.

Hardening without a failing old-code test: `Invoke-HygieneFix` supports `-WhatIf` (the test for it did fail on the old code), runs with `ErrorActionPreference` Stop and also treats an error written without stopping as a failure; `New-HygieneFinding` accepts an empty object name.

## Not covered, and why

- Contrast of disabled controls, the sidebar button border, the light combo boxes and text boxes, and the unselected tab headers misses the standard (text 4.5:1, borders 3:1). The cause is the shared SuiteCommon palette and the MahApps styles. `Tests/KnownContrastDefects.ps1` lists each violation. The window test fails on a new one and on a listed one that is fixed. The fix belongs in `app-packager-suite`.
- `Read-SuiteSettings` in SuiteCommon returns nothing for a setting named `Keys` (and for `Values` or `Count`). The fix belongs in `app-packager-suite`; the app works around it.
- The dialogs and grids are not shown with a full data set, so their layout with long values is not measured.
- The scan, refresh and Run Fix click handlers, the background runspace, the timer and the Trends chart run inside the window with a site. The lab run covers the module calls that they make, not the clicks.
- Client Health and Inactive Devices need SQL. They run only against mocks.
