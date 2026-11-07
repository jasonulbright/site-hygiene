# Permissions

This page lists the rights that Site Hygiene needs.

## What it does

A scan and a refresh read the site. A confirmed fix changes the site with the rights of the account that started the tool.

## When to use it

Use it to set up an account, or to find out why a read or a fix is refused.

## Requirements

| Action | Right |
|---|---|
| Start the tool | Read and write in the folder of the script. |
| Scan, and Deployments, Content, Distribution Points and Site Health | The Configuration Manager console on the computer, and read access to the SMS Provider under your Configuration Manager role. |
| Client Health and Inactive Devices | The `SqlServer` PowerShell module and read access to the `CM_<site>` database. |
| Run Fix | The Configuration Manager rights that the fix script needs. The script is shown in the dialog. |
| Alerts | Windows notifications for the toast. The alerts log needs no right. |

## Steps

1. Start the tool as the account that has the Configuration Manager role.
2. Select **Scan** to test the read access.

## Limits

- A scan never changes the site.
- The tool does not check the rights of the fix before it runs the script. A refused fix shows in the log as `Fix failed`.

## Troubleshooting

| Message or symptom | Cause | Fix |
|---|---|---|
| `Scan failed: Failed to connect to site` | The account has no access to the provider, or the console is missing. | Check the role, the provider name and the console. |
| `Fix failed [<check>]` | The role lacks a right of the script. | Use an account with the right. |

## Links

- [Network](network.md)
- [Findings](../core/findings.md)
