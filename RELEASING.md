# Releasing Site Hygiene

## 1. Test

Run the full suite. The release stops if a test fails.

```powershell
powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; $r = Invoke-Pester -Path Tests -PassThru -Output None; 'passed {0} failed {1}' -f $r.PassedCount, $r.FailedCount"
```

## 2. Version

The version is `YYYY.MM.DD.BBBB`: the release date, then a four-digit, zero-padded build number. The build number increases by 1 for each release and never resets. Build 0013 is the first release with this scheme; the 12 releases before it used `0.x.y` numbers. Keep the zero-padded text everywhere; `[version]` drops the leading zeros.

Set the same version in three places:

- `Module/SiteHygieneCommon.psd1`, `ModuleVersion`. The title bar and the About pane read this value.
- `start-sitehygiene.ps1`, header line `Version    : <ver>`
- `CHANGELOG.md`, the top heading `## [<ver>] - <date>`

A test fails if the three values differ.

## 3. Shared module

Check the vendored SuiteCommon copy for drift. Sync it if the check reports drift.

```powershell
C:\projects\app-packager-suite\sync-suitecommon.ps1 -Consumer C:\projects\site-hygiene -Check
```

## 4. Commit, tag, and package

Commit to `main`. Tag the commit `v<ver>`. Build the zip from the tag. The zip excludes `Tests/`.

```bash
git archive --format=zip -o SiteHygiene-<ver>.zip HEAD -- . ':(exclude)Tests'
sha256sum SiteHygiene-<ver>.zip | sed 's/ \*/  /' > checksums.txt
```

Extract the zip to a temporary folder. Import `Module/SiteHygieneCommon.psd1` under Windows PowerShell 5.1. The import must succeed.

## 5. Publish

Push `main` and the tag. Create the GitHub release with the title `v<ver>` and two assets: the zip and `checksums.txt`. The release must not be a draft.
