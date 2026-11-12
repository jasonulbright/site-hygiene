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
| `SQLServer` | **SQL Server (Optional)** | Empty. |
| `SqlTrustServerCertificate` | **Trust the SQL Server Certificate** | `true`. |
| `ScanScopes` | The areas of **Options > Scan** | All areas. |
| `ProviderPacingMs` | **Pause Between Provider Calls** | `0`. |
| `AutoRefreshMinutes` | **Auto-Refresh Interval** | `15`. |
| `InactiveThresholdDays` | **Inactivity Threshold** | `14`. |
| `AlertsEnabled` | **Enable Threshold Alerts** | `true`. |
| `AlertCompliancePct` | **Deployment Compliance Floor** | `80`. |
| `DarkMode` | **Dark Theme** switch | `true`. |

`SiteHygiene.windowstate.json` keeps the size, the place and the open view of the window.

## Steps

### Reset the settings

1. Close the tool.
2. Delete `SiteHygiene.prefs.json` and `SiteHygiene.windowstate.json`.
3. Move the files of a retired ConfigMgr Health Dashboard install out of `legacy\mecm-health-dashboard` and out of the sibling `mecm-health-dashboard` folder. The tool imports them at the start and fills the empty settings from them. Keep them out until the tool has saved its default settings.
4. Start the tool. The window of the first start shows.

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
