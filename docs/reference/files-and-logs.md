# Files and logs

This page lists every folder and file that Site Hygiene writes.

## What it does

The tool writes the logs, the window state and the settings that do not belong to a site in the folder of the script. It writes the data of a site in the site folder `%LOCALAPPDATA%\AppPackagerData\sites\<SITE>\tools\site-hygiene`. It writes nothing in the registry. A fix that you confirm changes the site.

## When to use it

Use it to find a log, a report or the history, or to clean up.

## Requirements

None.

## Files

| Path | Content | Written when |
|---|---|---|
| `SiteHygiene.prefs.json` | The settings that do not belong to a site. | You select **OK** in Options. |
| `<site folder>\prefs.json` | The site code, the SMS Provider and the SQL Server of the site. | You select **OK** in Options. |
| `SiteHygiene.windowstate.json` | The size, the place and the open view of the window. | You close the window. |
| `<site folder>\lastscan.json` | The findings of the last scan of the site, for the rescan delta. | A scan of every area completes. |
| `<site folder>\suppressions.json` | The suppressed finding keys of the site. | You select **Suppress** or **Unsuppress**. |
| `<site folder>\history\metrics-history.csv` | One row of counts for each completed refresh. 180 days are kept. | A refresh completes. |
| `Logs\SiteHygiene-<yyyyMMdd-HHmmss>.log` | The log of one session: each dataset with its row count and duration, each scan, refresh and fix. | During the session. |
| `Logs\SiteHygiene-startup-<yyyyMMdd-HHmmss>.txt` | The PowerShell transcript of the start. | At the start. |
| `Logs\SiteHygiene-alerts.log` | One line for each alert. | An alert fires. |
| `<site folder>\reports\SiteHygiene-Findings-<date>-<time>.csv` or `.html` | An export of the Findings view. The exports of the other views use the name of the view. | You select **Export CSV** or **Export HTML**. |

`<site folder>` is `%LOCALAPPDATA%\AppPackagerData\sites\<SITE>\tools\site-hygiene`. With no site chosen, the tool uses the old files beside the script: `SiteHygiene.lastscan.json`, `SiteHygiene.suppressions.json`, `History\metrics-history.csv` and the `Reports` folder. See [Sites](../core/options.md#sites).

## Steps

### Clean up

1. Close the tool.
2. Delete the logs and the reports that you do not need.

## Limits

- The tool never deletes a log or a report.
- The Run Fix script is written to the log before it runs.

## Troubleshooting

| Message or symptom | Cause | Fix |
|---|---|---|
| A start leaves no log. | The folder is not writable. | Move the tool to a writable folder. |

## Links

- [Settings](settings.md)
- [Trends and alerts](../core/trends-and-alerts.md)
