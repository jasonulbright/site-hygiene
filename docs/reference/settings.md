# Settings

This page lists what Site Hygiene saves and where.

## What it does

The tool saves its settings in `SiteHygiene.prefs.json` in the folder of the script. The Options dialog writes the file when you select **OK**.

## When to use it

Use it to copy the settings to another computer or to reset them.

## Requirements

None.

## Settings

| Key | Option | Default |
|---|---|---|
| `SiteCode` | **Site Code** | Empty. |
| `SMSProvider` | **SMS Provider FQDN** | Empty. |
| `SQLServer` | **SQL Server (optional)** | Empty. |
| `SqlTrustServerCertificate` | **Trust the SQL Server certificate** | `true`. |
| `ScanScopes` | The areas of **Options > Scan** | All areas. |
| `ProviderPacingMs` | Pause between provider calls | `0`. |
| `AutoRefreshMinutes` | Auto-refresh interval | `15`. |
| `InactiveThresholdDays` | Inactivity threshold | `14`. |
| `AlertsEnabled` | **Enable threshold alerts** | `true`. |
| `AlertCompliancePct` | Deployment compliance floor | `80`. |
| `DarkMode` | **Dark Theme** switch | `true`. |

`SiteHygiene.windowstate.json` keeps the size, the place and the open view of the window.

## Steps

### Reset the settings

1. Close the tool.
2. Delete `SiteHygiene.prefs.json` and `SiteHygiene.windowstate.json`.
3. Start the tool. The window of the first start shows.

## Limits

- The files are in the folder of the script. Extract the tool to a folder that you can write to.
- A retired ConfigMgr Health Dashboard install in `legacy\mecm-health-dashboard` or in a sibling `mecm-health-dashboard` folder is imported at the start. It fills only values that are empty.

## Troubleshooting

| Message or symptom | Cause | Fix |
|---|---|---|
| The settings do not stick. | The folder is not writable. | Move the tool to a writable folder. |

## Links

- [Options dialog](../core/options.md)
- [Files and logs](files-and-logs.md)
