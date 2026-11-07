# Network

This page lists every outbound call of Site Hygiene.

## What it does

The tool talks to the SMS Provider and, when you set one, to the SQL Server. It sends nothing to the internet.

## When to use it

Use it to open the firewall for the tool, or to check the traffic.

## Requirements

| Target | Protocol | Used for |
|---|---|---|
| SMS Provider in **Options > Connection** | Windows Management Instrumentation, as the `ConfigurationManager` module of the console uses it. | Every scan, every refresh and every fix. |
| SQL Server in **Options > Connection** | SQL Server connection with encryption. Port 1433 for a default instance. | Client Health and Inactive Devices. |

## Steps

None.

## Limits

- The tool makes no call to the internet and has no update check.
- The toast of an alert is local.
- **Trust the SQL Server certificate** is on by default. The connection is encrypted but the certificate is not checked.

## Troubleshooting

| Message or symptom | Cause | Fix |
|---|---|---|
| `Failed to connect to site` | The provider is not reachable. | Check the name, the firewall and the role. |
| The SQL views stay empty. | The SQL Server is not reachable or not set. | Check **SQL Server** in Options. |

## Links

- [Permissions](permissions.md)
- [Options dialog](../core/options.md)
