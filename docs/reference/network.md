# Network

This page lists every outbound call of Site Hygiene.

## What it does

The tool talks to the SMS Provider and, when you set one, to the SQL Server. When it is installed by the suite installer, it also checks GitHub once a day for a newer suite version. It sends no user data and no telemetry.

## When to use it

Use it to open the firewall for the tool, or to check the traffic.

## Requirements

| Target | Protocol | Used for |
|---|---|---|
| SMS Provider in **Options > Connection** | Windows Management Instrumentation, as the `ConfigurationManager` module of the console uses it. | Every scan, every refresh and every fix. |
| Content servers, as UNC paths | SMB from the computer that runs the tool. | The check APP-04 probes the content path of each deployment type when the scan includes application relationships. A blocked probe can show a source as unreachable or unknown. |
| `https://api.github.com/repos/<repository>/releases/latest` | HTTPS to GitHub, at the start of the window, once a day, only when the tool is installed by the suite installer. | The check for a newer suite version. The result goes to the log. |
| SQL Server in **Options > Connection** | SQL Server connection with encryption. Port 1433 for a default instance. | Client Health and Inactive Devices. |

## Steps

None.

## Limits

- A plain extract of the zip (no `suite-manifest.json`) makes no call to GitHub. A failed update check is ignored. The tool does not change a proxy setting.
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
