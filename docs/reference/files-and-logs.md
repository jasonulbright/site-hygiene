# Files and logs

This page lists every folder and file that Site Hygiene writes.

## What it does

The tool writes in the folder of the script. It writes nothing in the registry. A fix that you confirm changes the site.

## When to use it

Use it to find a log, a report or the history, or to clean up.

## Requirements

None.

## Files

| Path | Content | Written when |
|---|---|---|
| `SiteHygiene.prefs.json` | The settings. | You select **OK** in Options. |
| `SiteHygiene.windowstate.json` | The size, the place and the open view of the window. | You close the window. |
| `SiteHygiene.lastscan.json` | The findings of the last scan, for the rescan delta. | A scan of every area completes. |
| `SiteHygiene.suppressions.json` | The suppressed finding keys. | You select **Suppress** or **Unsuppress**. |
| `History\metrics-history.csv` | One row of counts for each completed refresh. 180 days are kept. | A refresh completes. |
| `Logs\SiteHygiene-<yyyyMMdd-HHmmss>.log` | The log of one session: each dataset with its row count and duration, each scan, refresh and fix. | During the session. |
| `Logs\SiteHygiene-startup-<yyyyMMdd-HHmmss>.txt` | The PowerShell transcript of the start. | At the start. |
| `Logs\SiteHygiene-alerts.log` | One line for each alert. | An alert fires. |
| `Reports\SiteHygiene-Findings-<date>-<time>.csv` or `.html` | An export of the Findings view. The exports of the other views use the name of the view. | You select **Export CSV** or **Export HTML**. |

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
