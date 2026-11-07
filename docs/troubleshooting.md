# Troubleshooting

This page lists the most common problems of Site Hygiene with cause and fix. See [Error messages](reference/error-messages.md) for every message.

## What it does

It gives a short fix for each common problem.

## When to use it

Use it when a scan, a refresh, a fix or an export does not work.

## Requirements

None.

## Problems

| Message or symptom | Cause | Fix |
|---|---|---|
| Scan does nothing and the log asks you to open Options. | The site code or the provider is empty. | Set the connection. |
| `ConfigurationManager module not found`. | The console is not installed on this computer, or `SMS_ADMIN_UI_PATH` does not point to the bin\i386 folder of the console. | Install the console. If it is installed, set `SMS_ADMIN_UI_PATH` to its bin\i386 folder and start the tool again. |
| `Failed to connect to site`. | The provider name is wrong or not reachable, or the role is missing. | Check the provider, the network and the role. |
| Client Health and Inactive Devices are empty. | No SQL Server is set. | Set **SQL Server** in **Options > Connection**. |
| Content is empty. | All content is healthy. The view shows only failed and in-progress content. | None. |
| **Run Fix** is disabled. | No row is selected, or the finding has guidance only. | Select a row with a fix script. |
| A finding is gone after a scan. | It is suppressed. | Select **Show suppressed**. |
| The Relationships view is empty. | The relationships area is not in the scan scope. | Select the area in **Options > Scan**. |
| No toast shows for an alert. | Windows notifications are off. | Read `Logs\SiteHygiene-alerts.log`. |
| The settings are lost. | The folder is not writable. | Move the tool to a writable folder. |

## Steps

1. Read the log pane. It names the cause of most problems.
2. Read the session log in `Logs`.
3. Do the fix of the table.

## Limits

None.

## Links

- [Error messages](reference/error-messages.md)
- [Files and logs](reference/files-and-logs.md)
